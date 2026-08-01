FROM xilinx/smartcam:2022.1@sha256:da2e52629011aeec332152a0f468d3ff156917dba9b596cf6d0de958d5dc29d7 AS build

# The runtime image also contains the Vitis AI/OpenCV shared libraries and
# headers, but not a C++ compiler or the OpenCV development metadata.  Install
# those so the finite, headless webcam verification program can be rebuilt on
# the ARM64 board instead of relying on an opaque prebuilt binary.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        libopencv-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Xilinx's public Vitis AI headers include glog/logging.h, while the official
# SmartCam runtime image only ships the corresponding shared library.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libgoogle-glog-dev \
        libjson-c-dev \
        libprotobuf-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY webcam_yolov3.cpp .
RUN mkdir -p /out \
    && g++ -std=c++17 -O2 webcam_yolov3.cpp -o /out/webcam_yolov3 \
        -lvitis_ai_library-yolov3 \
        -lvitis_ai_library-dpu_task \
        -lvitis_ai_library-xnnpp \
        -lvitis_ai_library-model_config \
        -lvitis_ai_library-math \
        -lvart-util \
        -lxir \
        -pthread \
        -ljson-c \
        -lglog \
        $(pkg-config --cflags --libs-only-L opencv4) \
        -lopencv_core \
        -lopencv_videoio \
        -lopencv_imgproc \
        -lopencv_imgcodecs \
        -lopencv_highgui

FROM xilinx/smartcam:2022.1@sha256:da2e52629011aeec332152a0f468d3ff156917dba9b596cf6d0de958d5dc29d7

# xdputil is present in the official image, but its Python entry point imports
# NumPy and the 2022.1 image does not install that runtime dependency.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-numpy \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/webcam_yolov3 /usr/local/bin/webcam_yolov3
