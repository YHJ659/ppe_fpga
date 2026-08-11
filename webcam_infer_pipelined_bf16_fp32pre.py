#!/usr/bin/env python3
"""Latest-frame PPE inference with PRE/FPGA software pipelining."""
from __future__ import annotations
import os

import argparse
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2

from sw.hybrid_pipeline import draw_detections
from sw.mixed_pipelined_pipeline_bf16_fp32pre import MixedPipelinedPipeline

ROOT = Path(__file__).resolve().parent


class LatestCamera:
    def __init__(
        self,
        index: int,
        width: int,
        height: int,
    ):
        self.cap = cv2.VideoCapture(
            index,
            cv2.CAP_V4L2,
        )

        if not self.cap.isOpened():
            self.cap = cv2.VideoCapture(index)

        if not self.cap.isOpened():
            raise RuntimeError(
                f"cannot open camera {index}"
            )

        self.cap.set(
            cv2.CAP_PROP_FRAME_WIDTH,
            width,
        )
        self.cap.set(
            cv2.CAP_PROP_FRAME_HEIGHT,
            height,
        )
        self.cap.set(
            cv2.CAP_PROP_BUFFERSIZE,
            1,
        )

        self.lock = threading.Lock()
        self.frame = None
        self.sequence = 0

        self.stop = threading.Event()
        self.ready = threading.Event()

        self.thread = threading.Thread(
            target=self._run,
            daemon=True,
        )
        self.thread.start()

    def _run(self):
        target_fps = float(
            os.environ.get("CAMERA_READ_FPS", "0")
        )

        period = (
            1.0 / target_fps
            if target_fps > 0
            else 0.0
        )

        while not self.stop.is_set():
            loop_started = time.monotonic()

            ok, frame = self.cap.read()

            if not ok:
                continue

            with self.lock:
                self.frame = frame
                self.sequence += 1

            self.ready.set()

            if period > 0:
                elapsed = (
                    time.monotonic()
                    - loop_started
                )

                remain = period - elapsed

                if remain > 0:
                    time.sleep(remain)

    def latest(self, seen: int):
        self.ready.wait(1.0)

        with self.lock:
            if (
                self.frame is None
                or self.sequence == seen
            ):
                return None, seen

            return (
                self.frame.copy(),
                self.sequence,
            )

    def wait_latest(self, seen: int):
        while not self.stop.is_set():
            frame, seq = self.latest(seen)

            if frame is not None:
                return frame, seq

            time.sleep(0.001)

        return None, seen

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2.0)
        self.cap.release()


class PipelinedInferenceWorker:
    def __init__(
        self,
        camera: LatestCamera,
        pipeline: MixedPipelinedPipeline,
    ):
        self.camera = camera
        self.pipeline = pipeline

        self.stop = threading.Event()
        self.lock = threading.Lock()

        self.result_frame = None
        self.result_detections = None
        self.result_sequence = 0
        self.timing = None

        self.inference_frames = 0
        self.started = time.monotonic()

        # 최근 10개 inference interval 기준 FPS
        # timestamp 11개 = interval 10개
        self.recent_done_times = deque(maxlen=11)
        self.recent_fps = 0.0

        self.thread = threading.Thread(
            target=self._run,
            daemon=True,
        )
        self.thread.start()

    def _run(self):
        seen = 0

        pool = ThreadPoolExecutor(
            max_workers=1
        )

        try:
            # ----------------------------------
            # Pipeline fill:
            # first frame PRE is done normally.
            # ----------------------------------
            current_frame, seen = (
                self.camera.wait_latest(seen)
            )

            if current_frame is None:
                return

            (
                current_feature,
                current_skip,
                current_meta,
                current_prep,
                current_pre,
            ) = self.pipeline.pre_stage(
                current_frame
            )

            while not self.stop.is_set():

                cycle_started = time.monotonic()

                # ==================================
                # FPGA(frame N)
                # ==================================
                fpga_future = pool.submit(
                    self.pipeline.fpga_stage,
                    current_feature,
                )

                # ==================================
                # PRE(frame N+1)
                #
                # Runs concurrently with FPGA(N).
                # ==================================
                next_frame, next_seen = (
                    self.camera.wait_latest(seen)
                )

                if next_frame is None:
                    break

                (
                    next_feature,
                    next_skip,
                    next_meta,
                    next_prep,
                    next_pre,
                ) = self.pipeline.pre_stage(
                    next_frame
                )

                seen = next_seen

                # FPGA(N) must finish before POST(N)
                fpga_output, fpga_time = (
                    fpga_future.result()
                )

                # ==================================
                # POST(frame N)
                #
                # Deliberately NOT overlapped with
                # FPGA because benchmark showed
                # POST+FPGA overlap is slower.
                # ==================================
                (
                    detections,
                    post_time,
                    nms_time,
                ) = self.pipeline.post_stage(
                    fpga_output,
                    current_skip,
                    current_meta,
                )

                cycle_time = (
                    time.monotonic()
                    - cycle_started
                )

                self.inference_frames += 1

                now = time.monotonic()

                # 실행 시작부터 전체 평균
                avg_fps = (
                    self.inference_frames
                    / (now - self.started)
                )

                # 최근 10개 완료 frame 기준 실제 throughput
                self.recent_done_times.append(now)

                if len(self.recent_done_times) >= 2:
                    recent_fps = (
                        (len(self.recent_done_times) - 1)
                        / (
                            self.recent_done_times[-1]
                            - self.recent_done_times[0]
                        )
                    )
                else:
                    recent_fps = avg_fps

                self.recent_fps = recent_fps

                timing = {
                    "avg_fps": avg_fps,
                    "recent_fps": recent_fps,
                    "pre": current_prep,
                    "sw0_5": current_pre,
                    "fpga6": fpga_time,
                    "sw7_22": post_time,
                    "post": nms_time,

                    # In pipelined mode this is
                    # throughput cycle time.
                    # It is NOT the sum of stages.
                    "total": cycle_time,
                }

                # 추론 thread에서는 그림을 그리지 않는다.
                # raw result만 main/display thread로 전달한다.
                with self.lock:
                    self.result_frame = current_frame.copy()
                    self.result_detections = detections.clone()
                    self.timing = dict(timing)
                    self.result_sequence += 1

                # Frame N+1 becomes current.
                current_frame = next_frame
                current_feature = next_feature
                current_skip = next_skip
                current_meta = next_meta
                current_prep = next_prep
                current_pre = next_pre

        finally:
            pool.shutdown(wait=True)

    def latest(self, seen_result):
        with self.lock:
            if (
                self.result_frame is None
                or self.result_sequence == seen_result
            ):
                return None, None, None, seen_result

            return (
                self.result_frame.copy(),
                self.result_detections.clone(),
                dict(self.timing),
                self.result_sequence,
            )

    def close(self):
        self.stop.set()
        self.thread.join(timeout=3.0)


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--camera",
        type=int,
        default=0,
    )

    parser.add_argument(
        "--conf",
        type=float,
        default=0.5,
    )

    parser.add_argument(
        "--width",
        type=int,
        default=640,
    )

    parser.add_argument(
        "--height",
        type=int,
        default=480,
    )

    parser.add_argument(
        "--threads",
        type=int,
        default=4,
    )

    args = parser.parse_args()

    # Prevent OpenCV itself from competing
    # heavily with ORT/ncnn CPU workers.
    cv2.setNumThreads(1)

    pipeline = MixedPipelinedPipeline(
        ROOT / "models" / "best.pt",
        graph_dir=ROOT / "models" / "onnx",
        conf=args.conf,
        threads=args.threads,
    )

    camera = LatestCamera(
        args.camera,
        args.width,
        args.height,
    )

    worker = PipelinedInferenceWorker(
        camera,
        pipeline,
    )

    display_frames = 0
    display_started = time.monotonic()
    last_reported = 0
    seen_result = 0

    try:
        while True:
            frame, detections, timing, new_sequence = worker.latest(
                seen_result
            )

            if frame is not None:
                seen_result = new_sequence

                # 박스 렌더링은 inference worker 밖에서 수행
                frame = draw_detections(
                    frame,
                    detections,
                    pipeline.names,
                    timing.get("recent_fps", 0.0),
                    timing,
                )

                display_frames += 1

                display_fps = (
                    display_frames
                    / (
                        time.monotonic()
                        - display_started
                    )
                )

                cv2.putText(
                    frame,
                    f"Display FPS {display_fps:.2f}",
                    (8, 48),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.55,
                    (255, 255, 0),
                    1,
                )

                cv2.putText(
                    frame,
                    "Current FPS %.2f | Avg %.2f"
                    % (
                        timing.get("recent_fps", 0.0),
                        timing.get("avg_fps", 0.0),
                    ),
                    (8, 68),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.55,
                    (255, 255, 0),
                    1,
                )

                cv2.imshow(
                    "PPE Detection PIPELINED",
                    frame,
                )

                if (
                    worker.inference_frames
                    >= last_reported + 10
                    and worker.inference_frames % 10 == 0
                ):
                    last_reported = (
                        worker.inference_frames
                    )

                    inference_fps = (
                        worker.inference_frames
                        / (
                            time.monotonic()
                            - worker.started
                        )
                    )

                    recent_fps = timing.get(
                        "recent_fps",
                        inference_fps,
                    )

                    print(
                        "Inference AVG %.2f | "
                        "Current FPS %.2f | "
                        "Display FPS %.2f | "
                        "pre %.0f ms | "
                        "sw0-5 %.0f ms | "
                        "fpga6 %.0f ms | "
                        "sw7-end %.0f ms | "
                        "post %.0f ms | "
                        "pipe-cycle %.0f ms"
                        % (
                            inference_fps,
                            recent_fps,
                            display_fps,
                            timing.get(
                                "pre", 0
                            ) * 1000,
                            timing.get(
                                "sw0_5", 0
                            ) * 1000,
                            timing.get(
                                "fpga6", 0
                            ) * 1000,
                            timing.get(
                                "sw7_22", 0
                            ) * 1000,
                            timing.get(
                                "post", 0
                            ) * 1000,
                            timing.get(
                                "total", 0
                            ) * 1000,
                        )
                    )

            if (
                cv2.waitKey(1) & 0xFF
                in (ord("q"), 27)
            ):
                break

            # Keep X11/display from stealing
            # CPU time from ORT/ncnn.
            time.sleep(0.15)

    finally:
        worker.close()
        camera.close()
        cv2.destroyAllWindows()
        pipeline.close()


if __name__ == "__main__":
    main()
