#!/usr/bin/env python3
"""Latest-frame camera PPE inference with FPGA model.6."""
from __future__ import annotations

import argparse
import threading
import time
from pathlib import Path

import cv2

from sw.final_hybrid_pipeline import FinalHybridPipeline
from sw.hybrid_pipeline import draw_detections

ROOT = Path(__file__).resolve().parent


class LatestCamera:
    def __init__(self, index: int, width: int, height: int):
        self.cap = cv2.VideoCapture(index, cv2.CAP_V4L2)
        if not self.cap.isOpened():
            self.cap = cv2.VideoCapture(index)
        if not self.cap.isOpened():
            raise RuntimeError(f"cannot open camera {index}")
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.lock = threading.Lock()
        self.frame = None
        self.sequence = 0
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while not self.stop.is_set():
            ok, frame = self.cap.read()
            if not ok:
                continue
            with self.lock:
                self.frame = frame
                self.sequence += 1
            self.ready.set()

    def latest(self, seen: int):
        self.ready.wait(1.0)
        with self.lock:
            if self.frame is None or self.sequence == seen:
                return None, seen
            return self.frame.copy(), self.sequence

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2.0)
        self.cap.release()


class InferenceWorker:
    def __init__(self, camera: LatestCamera, pipeline: HybridPipeline):
        self.camera = camera
        self.pipeline = pipeline
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.rendered = None
        self.timing = None
        self.inference_frames = 0
        self.started = time.monotonic()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        seen = 0
        while not self.stop.is_set():
            frame, seen = self.camera.latest(seen)
            if frame is None:
                continue
            detections, timing = self.pipeline.infer(frame)
            self.inference_frames += 1
            fps = self.inference_frames / (time.monotonic() - self.started)
            rendered = draw_detections(
                frame, detections, self.pipeline.names, fps, timing)
            with self.lock:
                self.rendered = rendered
                self.timing = timing

    def latest(self):
        with self.lock:
            if self.rendered is None:
                return None, None
            return self.rendered.copy(), self.timing

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2.0)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--conf", type=float, default=0.5)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--threads", type=int, default=4,
                        help="CPU runtime intra-op threads")
    parser.add_argument("--backend", choices=("auto", "ort", "pytorch"),
                        default="auto")
    parser.add_argument("--channels-last", action="store_true",
                        help="benchmark/use channels-last CPU convolutions")
    args = parser.parse_args()

    pipeline = FinalHybridPipeline(
        ROOT / "models" / "best.pt", ROOT / "calib_out" / "calib_params.json",
        conf=args.conf, backend=args.backend, threads=args.threads,
        channels_last=args.channels_last)
    camera = LatestCamera(args.camera, args.width, args.height)
    worker = InferenceWorker(camera, pipeline)
    display_frames = 0
    display_started = time.monotonic()
    last_reported = 0
    try:
        while True:
            frame, timing = worker.latest()
            if frame is not None:
                display_frames += 1
                display_fps = display_frames / (time.monotonic() - display_started)
                cv2.putText(frame, f"Display FPS {display_fps:.2f}", (8, 48),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 0), 1)
                cv2.imshow("PPE Detection (model.6 FPGA)", frame)
                if (worker.inference_frames >= last_reported + 10 and
                        worker.inference_frames % 10 == 0):
                    last_reported = worker.inference_frames
                    print("Inference FPS %.2f | Display FPS %.2f | pre %.0f ms | "
                          "sw0-5 %.0f ms | fpga6 %.0f ms | sw7-end %.0f ms | "
                          "post %.0f ms | total %.0f ms" %
                          (worker.inference_frames /
                           (time.monotonic() - worker.started), display_fps,
                           timing.get("pre", 0) * 1000,
                           timing.get("sw0_5", 0) * 1000,
                           timing.get("fpga6", 0) * 1000,
                           timing.get("sw7_22", 0) * 1000,
                           timing.get("post", 0) * 1000,
                           timing.get("total", 0) * 1000))
            if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
                break
    finally:
        worker.close()
        camera.close()
        cv2.destroyAllWindows()
        pipeline.close()


if __name__ == "__main__":
    main()
