// Finite, headless KV260 webcam verification using the Vitis AI 2.5 YOLOv3 API.
//
// This intentionally writes evidence files instead of opening a GUI window so
// it can be run reproducibly over SSH.  The model path must point to an xmodel
// with a same-stem .prototxt file beside it.

#include <algorithm>
#include <array>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/videoio.hpp>
#include <vitis/ai/yolov3.hpp>

namespace {

using Clock = std::chrono::steady_clock;

constexpr std::array<const char*, 80> kCocoLabels = {
    "person",        "bicycle",      "car",           "motorcycle",
    "airplane",      "bus",          "train",         "truck",
    "boat",          "traffic light", "fire hydrant", "stop sign",
    "parking meter", "bench",        "bird",          "cat",
    "dog",           "horse",        "sheep",         "cow",
    "elephant",      "bear",         "zebra",         "giraffe",
    "backpack",      "umbrella",     "handbag",       "tie",
    "suitcase",      "frisbee",      "skis",          "snowboard",
    "sports ball",   "kite",         "baseball bat",  "baseball glove",
    "skateboard",    "surfboard",    "tennis racket", "bottle",
    "wine glass",    "cup",          "fork",          "knife",
    "spoon",         "bowl",         "banana",        "apple",
    "sandwich",      "orange",       "broccoli",      "carrot",
    "hot dog",       "pizza",        "donut",         "cake",
    "chair",         "couch",        "potted plant",  "bed",
    "dining table",  "toilet",       "tv",            "laptop",
    "mouse",         "remote",       "keyboard",      "cell phone",
    "microwave",     "oven",         "toaster",       "sink",
    "refrigerator",  "book",         "clock",         "vase",
    "scissors",      "teddy bear",   "hair drier",    "toothbrush"};

std::string join_path(const std::string& directory, const std::string& name) {
  if (!directory.empty() && directory.back() == '/') {
    return directory + name;
  }
  return directory + "/" + name;
}

std::string label_name(int label) {
  if (label >= 0 && label < static_cast<int>(kCocoLabels.size())) {
    return kCocoLabels[static_cast<std::size_t>(label)];
  }
  return "class_" + std::to_string(label);
}

cv::Scalar label_color(int label) {
  // Stable, high-contrast BGR color derived from the class index.
  return cv::Scalar((37 * label + 80) % 256, (17 * label + 170) % 256,
                    (29 * label + 240) % 256);
}

void write_checked(const std::string& path, const cv::Mat& image) {
  if (!cv::imwrite(path, image)) {
    throw std::runtime_error("failed to write image: " + path);
  }
}

void usage(const char* program) {
  std::cerr << "Usage: " << program
            << " MODEL.xmodel CAMERA_DEVICE FRAME_COUNT OUTPUT_DIRECTORY\n"
            << "Example: " << program
            << " /work/models/yolov3.xmodel /dev/video0 60 /work/results\n";
}

}  // namespace

int main(int argc, char* argv[]) {
  if (argc != 5) {
    usage(argv[0]);
    return 2;
  }

  const std::string model_path = argv[1];
  const std::string camera_device = argv[2];
  const int requested_frames = std::stoi(argv[3]);
  const std::string output_directory = argv[4];
  if (requested_frames <= 0) {
    std::cerr << "FRAME_COUNT must be positive\n";
    return 2;
  }

  try {
    std::cout << "Loading Vitis AI YOLOv3 model: " << model_path << "\n";
    auto detector = vitis::ai::YOLOv3::create(model_path, true);
    if (!detector) {
      throw std::runtime_error("YOLOv3::create returned null");
    }

    cv::VideoCapture camera;
    if (!camera.open(camera_device, cv::CAP_V4L2) &&
        !camera.open(camera_device, cv::CAP_ANY)) {
      throw std::runtime_error("cannot open camera: " + camera_device);
    }

    camera.set(cv::CAP_PROP_FRAME_WIDTH, 640);
    camera.set(cv::CAP_PROP_FRAME_HEIGHT, 480);
    camera.set(cv::CAP_PROP_FPS, 30);
    camera.set(cv::CAP_PROP_BUFFERSIZE, 1);

    const int actual_width =
        static_cast<int>(camera.get(cv::CAP_PROP_FRAME_WIDTH));
    const int actual_height =
        static_cast<int>(camera.get(cv::CAP_PROP_FRAME_HEIGHT));
    const double actual_fps = camera.get(cv::CAP_PROP_FPS);
    std::cout << "Camera opened: " << camera_device << " " << actual_width
              << "x" << actual_height << " reported_fps=" << actual_fps
              << "\n";

    std::ofstream csv(join_path(output_directory, "detections.csv"));
    if (!csv) {
      throw std::runtime_error("cannot create detections.csv");
    }
    csv << "frame,label,class,score,xmin,ymin,xmax,ymax,inference_ms\n";
    csv << std::fixed << std::setprecision(4);

    int processed_frames = 0;
    int total_detections = 0;
    int best_detection_count = -1;
    double total_inference_ms = 0.0;
    cv::Mat best_annotated;
    cv::Mat last_annotated;
    const auto wall_start = Clock::now();

    for (int frame_index = 0; frame_index < requested_frames; ++frame_index) {
      cv::Mat frame;
      if (!camera.read(frame) || frame.empty()) {
        std::cerr << "Camera read failed at frame " << frame_index << "\n";
        break;
      }
      if (frame_index == 0) {
        write_checked(join_path(output_directory, "raw_first.jpg"), frame);
      }

      const auto inference_start = Clock::now();
      const auto result = detector->run(frame);
      const auto inference_end = Clock::now();
      const double inference_ms =
          std::chrono::duration<double, std::milli>(inference_end -
                                                   inference_start)
              .count();
      total_inference_ms += inference_ms;

      cv::Mat annotated = frame.clone();
      for (const auto& box : result.bboxes) {
        const int xmin = std::clamp(
            static_cast<int>(box.x * frame.cols), 0, frame.cols - 1);
        const int ymin = std::clamp(
            static_cast<int>(box.y * frame.rows), 0, frame.rows - 1);
        const int xmax =
            std::clamp(static_cast<int>((box.x + box.width) * frame.cols), 0,
                       frame.cols - 1);
        const int ymax =
            std::clamp(static_cast<int>((box.y + box.height) * frame.rows), 0,
                       frame.rows - 1);
        if (xmax <= xmin || ymax <= ymin) {
          continue;
        }

        const auto color = label_color(box.label);
        cv::rectangle(annotated, cv::Point(xmin, ymin),
                      cv::Point(xmax, ymax), color, 2);
        std::ostringstream text;
        text << label_name(box.label) << " " << std::fixed
             << std::setprecision(2) << box.score;
        int baseline = 0;
        const auto text_size = cv::getTextSize(
            text.str(), cv::FONT_HERSHEY_SIMPLEX, 0.5, 1, &baseline);
        const int text_y = std::max(ymin, text_size.height + 4);
        cv::rectangle(
            annotated,
            cv::Point(xmin, text_y - text_size.height - 4),
            cv::Point(std::min(xmin + text_size.width + 4, frame.cols - 1),
                      std::min(text_y + baseline, frame.rows - 1)),
            color, cv::FILLED);
        cv::putText(annotated, text.str(), cv::Point(xmin + 2, text_y - 2),
                    cv::FONT_HERSHEY_SIMPLEX, 0.5, cv::Scalar(0, 0, 0), 1,
                    cv::LINE_AA);

        csv << frame_index << "," << box.label << ","
            << label_name(box.label) << "," << box.score << "," << xmin
            << "," << ymin << "," << xmax << "," << ymax << ","
            << inference_ms << "\n";
      }

      const int detection_count = static_cast<int>(result.bboxes.size());
      ++processed_frames;
      total_detections += detection_count;
      const double average_inference_ms =
          total_inference_ms / static_cast<double>(processed_frames);

      std::ostringstream status;
      status << "KV260 DPU YOLOv3 | frame " << processed_frames << "/"
             << requested_frames << " | " << std::fixed
             << std::setprecision(1) << average_inference_ms
             << " ms | detections " << detection_count;
      cv::putText(annotated, status.str(), cv::Point(10, 25),
                  cv::FONT_HERSHEY_SIMPLEX, 0.53, cv::Scalar(0, 255, 255), 2,
                  cv::LINE_AA);

      if (detection_count >= best_detection_count) {
        best_detection_count = detection_count;
        best_annotated = annotated.clone();
      }
      last_annotated = annotated;

      if (processed_frames == 1 || processed_frames % 10 == 0 ||
          processed_frames == requested_frames) {
        std::cout << "frame=" << processed_frames
                  << " inference_ms=" << std::fixed << std::setprecision(2)
                  << inference_ms << " detections=" << detection_count << "\n";
      }
    }

    camera.release();
    if (processed_frames == 0) {
      throw std::runtime_error("camera produced no frames");
    }

    const double wall_seconds =
        std::chrono::duration<double>(Clock::now() - wall_start).count();
    write_checked(join_path(output_directory, "best_annotated.jpg"),
                  best_annotated);
    write_checked(join_path(output_directory, "last_annotated.jpg"),
                  last_annotated);

    const double average_inference_ms =
        total_inference_ms / static_cast<double>(processed_frames);
    const double pipeline_fps =
        static_cast<double>(processed_frames) / wall_seconds;
    std::ofstream summary(join_path(output_directory, "summary.txt"));
    summary << std::fixed << std::setprecision(3)
            << "model=" << model_path << "\n"
            << "camera=" << camera_device << "\n"
            << "resolution=" << actual_width << "x" << actual_height << "\n"
            << "frames=" << processed_frames << "\n"
            << "total_detections=" << total_detections << "\n"
            << "best_frame_detections=" << best_detection_count << "\n"
            << "average_inference_ms=" << average_inference_ms << "\n"
            << "pipeline_fps=" << pipeline_fps << "\n";

    std::cout << std::fixed << std::setprecision(3)
              << "RESULT camera=" << camera_device
              << " resolution=" << actual_width << "x" << actual_height
              << " frames=" << processed_frames
              << " total_detections=" << total_detections
              << " best_frame_detections=" << best_detection_count
              << " average_inference_ms=" << average_inference_ms
              << " pipeline_fps=" << pipeline_fps << "\n";
    return processed_frames == requested_frames ? 0 : 3;
  } catch (const std::exception& error) {
    std::cerr << "ERROR: " << error.what() << "\n";
    return 1;
  }
}
