"""ONNX Runtime CPU partitions around the unchanged FPGA model.6."""
from __future__ import annotations

import json
import time
from pathlib import Path

import cv2
import numpy as np
import torch

from hw.hw_driver import Model6Fpga
from sw.hybrid_pipeline import letterbox, draw_detections


class OrtHybridPipeline:
    def __init__(self, weights: str | Path, calib_path: str | Path,
                 graph_dir: str | Path = "models/onnx", imgsz: int = 640,
                 conf: float = 0.5, iou: float = 0.45, threads: int = 1,
                 execution_mode: str = "sequential", graph_suffix: str = ""):
        import onnxruntime as ort

        graph_dir = Path(graph_dir)
        self.pre_path = graph_dir / f"pre_model6{graph_suffix}.onnx"
        self.post_path = graph_dir / f"post_model6{graph_suffix}.onnx"
        if not self.pre_path.exists() or not self.post_path.exists():
            raise FileNotFoundError("export models/onnx/*.onnx first")
        with open(calib_path, encoding="utf-8") as stream:
            calib = json.load(stream)
        self.hw_in_scale = float(calib["boundary"]["hw_in_scale"])
        self.s_cat = float(calib["activation_scale"]["S_cat"])
        from ultralytics import YOLO
        self.names = YOLO(str(weights)).model.names
        self.imgsz, self.conf, self.iou = imgsz, conf, iou

        def session(path):
            options = ort.SessionOptions()
            options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            options.intra_op_num_threads = threads
            options.inter_op_num_threads = 1
            options.execution_mode = (ort.ExecutionMode.ORT_PARALLEL if execution_mode == "parallel"
                                      else ort.ExecutionMode.ORT_SEQUENTIAL)
            try:
                options.add_session_config_entry("session.intra_op.allow_spinning", "0")
            except Exception:
                pass
            return ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])

        self.pre = session(self.pre_path)
        self.post = session(self.post_path)
        self.fpga = Model6Fpga()
        print(f"MODEL NAMES: {self.names}")

    def close(self):
        self.fpga.close()

    def _to_hw(self, feature: np.ndarray) -> np.ndarray:
        q = np.clip(np.rint(feature[0].astype(np.float32) / self.hw_in_scale), -128, 127)
        chw = q.astype(np.int8)
        return np.ascontiguousarray(chw.transpose(1, 2, 0)).ravel()

    def _from_hw(self, raw: np.ndarray) -> np.ndarray:
        hwc = raw.reshape(40, 40, 256).astype(np.float32)
        return np.ascontiguousarray(hwc.transpose(2, 0, 1))[None] * self.s_cat

    def infer(self, bgr: np.ndarray):
        try:
            from ultralytics.utils.nms import non_max_suppression
        except ImportError:
            from ultralytics.yolo.utils.ops import non_max_suppression

        started = time.monotonic()
        image, ratio, dx, dy = letterbox(bgr, self.imgsz)
        input_image = np.ascontiguousarray(image[:, :, ::-1]).transpose(2, 0, 1)
        input_image = np.ascontiguousarray(input_image[None].astype(np.float32) / 255.0)
        pre_start = time.monotonic()
        pre_outputs = self.pre.run(None, {self.pre.get_inputs()[0].name: input_image})
        feature, skip4 = pre_outputs
        pre_time = time.monotonic() - pre_start

        hw_start = time.monotonic()
        raw = self.fpga.run(self._to_hw(feature))
        dequant = self._from_hw(raw)
        fpga_time = time.monotonic() - hw_start

        post_start = time.monotonic()
        post_outputs = self.post.run(None, {
            self.post.get_inputs()[0].name: dequant,
            self.post.get_inputs()[1].name: skip4,
        })
        prediction = post_outputs[0]
        post_time = time.monotonic() - post_start
        detections = non_max_suppression(
            torch.from_numpy(prediction.copy()), self.conf, self.iou,
            nc=len(self.names))[0]
        nms_time = time.monotonic() - post_start - post_time
        if len(detections):
            detections[:, [0, 2]] = (detections[:, [0, 2]] - dx) / ratio
            detections[:, [1, 3]] = (detections[:, [1, 3]] - dy) / ratio
            detections[:, [0, 2]] = detections[:, [0, 2]].clamp(0, bgr.shape[1])
            detections[:, [1, 3]] = detections[:, [1, 3]].clamp(0, bgr.shape[0])
        return detections, {
            "pre": time.monotonic() - started - pre_time - fpga_time - post_time - nms_time,
            "ort_a": pre_time, "fpga6": fpga_time,
            "ort_b": post_time, "post": nms_time,
            "total": time.monotonic() - started,
        }
