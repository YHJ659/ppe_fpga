"""Direct YOLOv8 0-5 / FPGA model.6 / 7-end inference pipeline."""
from __future__ import annotations

import json
import time
from pathlib import Path

import cv2
import numpy as np
import torch

from hw.hw_driver import Model6Fpga


H = W = 40
IN_CH, OUT_CH = 128, 256
HW_LAYER = 6


def letterbox(img: np.ndarray, new_shape: int = 640,
              color: tuple[int, int, int] = (114, 114, 114)):
    h, w = img.shape[:2]
    ratio = min(new_shape / h, new_shape / w)
    nh, nw = int(round(h * ratio)), int(round(w * ratio))
    resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    top, left = (new_shape - nh) // 2, (new_shape - nw) // 2
    boxed = cv2.copyMakeBorder(
        resized, top, new_shape - nh - top, left, new_shape - nw - left,
        cv2.BORDER_CONSTANT, value=color)
    return boxed, ratio, left, top


class HybridPipeline:
    def __init__(self, weights: str | Path, calib_path: str | Path,
                 imgsz: int = 640, conf: float = 0.5, iou: float = 0.45,
                 threads: int | None = None, channels_last: bool = False):
        from ultralytics import YOLO

        with open(calib_path, encoding="utf-8") as stream:
            calib = json.load(stream)
        self.hw_in_scale = float(calib["boundary"]["hw_in_scale"])
        self.s_cat = float(calib["activation_scale"]["S_cat"])
        if self.hw_in_scale <= 0 or self.s_cat <= 0:
            raise ValueError("calibration scales must be positive")

        if threads:
            torch.set_num_threads(threads)
            torch.set_num_interop_threads(1)
        loaded = YOLO(str(weights))
        loaded.model.eval()
        if channels_last:
            loaded.model.to(memory_format=torch.channels_last)
        self.net = loaded.model
        self.names = self.net.names
        self.imgsz = imgsz
        self.conf = conf
        self.iou = iou
        self.channels_last = channels_last
        self.fpga = Model6Fpga()
        self._debug_frames = 3

        print(f"MODEL NAMES: {self.names}")

    def close(self) -> None:
        self.fpga.close()

    def _to_hw(self, feat: torch.Tensor) -> np.ndarray:
        q = torch.clamp(torch.round(feat[0].float() / self.hw_in_scale), -128, 127)
        chw = q.to(torch.int8).detach().cpu().numpy()
        return np.ascontiguousarray(chw.transpose(1, 2, 0)).ravel()

    def _from_hw(self, raw: np.ndarray, device: torch.device,
                 dtype: torch.dtype) -> torch.Tensor:
        hwc = raw.reshape(H, W, OUT_CH).astype(np.float32)
        chw = np.ascontiguousarray(hwc.transpose(2, 0, 1))
        return (torch.from_numpy(chw).unsqueeze(0).to(device=device, dtype=dtype)
                * self.s_cat)

    def _forward(self, x: torch.Tensor, timing: dict[str, float]) -> torch.Tensor:
        saved = []
        for module in self.net.model:
            if module.f != -1:
                x = (saved[module.f] if isinstance(module.f, int) else
                     [x if source == -1 else saved[source] for source in module.f])

            if module.i == HW_LAYER:
                timing["sw0_5"] = (time.monotonic() - timing["start"] -
                                    timing.get("pre", 0.0))
                payload = self._to_hw(x)
                started = time.monotonic()
                raw = self.fpga.run(payload)
                timing["fpga6"] = time.monotonic() - started
                # model.6's cv2 is the first half of the C2f block; the
                # remaining cv1/cv2/shortcut graph is handled by later layers
                # exactly as in the reference loop.
                x = module.cv2(self._from_hw(raw, x.device, x.dtype))
                timing["after6"] = time.monotonic()
            else:
                x = module(x)
            saved.append(x if module.i in self.net.save else None)
        return x

    def infer(self, bgr: np.ndarray):
        try:
            from ultralytics.utils.nms import non_max_suppression
        except ImportError:
            try:
                from ultralytics.utils.ops import non_max_suppression
            except ImportError:
                from ultralytics.yolo.utils.ops import non_max_suppression

        timing: dict[str, float] = {"start": time.monotonic()}
        image, ratio, dx, dy = letterbox(bgr, self.imgsz)
        rgb = np.ascontiguousarray(image[:, :, ::-1])
        tensor = torch.from_numpy(rgb).permute(2, 0, 1).float()
        tensor = (tensor / 255.0).unsqueeze(0)
        if self.channels_last:
            tensor = tensor.contiguous(memory_format=torch.channels_last)
        timing["pre"] = time.monotonic() - timing["start"]

        with torch.inference_mode():
            output = self._forward(tensor, timing)
        prediction = output[0] if isinstance(output, (list, tuple)) else output
        timing["sw7_22"] = time.monotonic() - timing.get("after6", timing["start"])
        post_start = time.monotonic()
        detections = non_max_suppression(
            prediction.clone(), self.conf, self.iou, nc=len(self.names))[0]
        timing["post"] = time.monotonic() - post_start
        if len(detections):
            detections[:, [0, 2]] = (detections[:, [0, 2]] - dx) / ratio
            detections[:, [1, 3]] = (detections[:, [1, 3]] - dy) / ratio
            detections[:, [0, 2]] = detections[:, [0, 2]].clamp(0, bgr.shape[1])
            detections[:, [1, 3]] = detections[:, [1, 3]].clamp(0, bgr.shape[0])
        timing["total"] = time.monotonic() - timing["start"]

        if self._debug_frames:
            print(f"MODEL6 DEBUG frame={4 - self._debug_frames}: "
                  f"prediction={tuple(prediction.shape)} detections={len(detections)}")
            for row in detections.tolist():
                print(f"  {self.names[int(row[5])]} conf={row[4]:.3f} "
                      f"class={int(row[5])}")
            self._debug_frames -= 1
        return detections, timing


PALETTE = [(56, 56, 255), (49, 210, 207), (10, 249, 72), (23, 204, 146),
           (134, 219, 61), (52, 147, 26), (187, 212, 0), (168, 153, 44),
           (255, 194, 0), (147, 69, 52)]


def draw_detections(frame: np.ndarray, detections: torch.Tensor, names,
                    fps: float, timing: dict[str, float]) -> np.ndarray:
    for *xyxy, confidence, class_id in detections.tolist():
        color = PALETTE[int(class_id) % len(PALETTE)]
        p1 = (int(xyxy[0]), int(xyxy[1]))
        p2 = (int(xyxy[2]), int(xyxy[3]))
        label = f"{names[int(class_id)]} {confidence:.2f}"
        cv2.rectangle(frame, p1, p2, color, 2)
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        cv2.rectangle(frame, (p1[0], max(0, p1[1] - th - 6)),
                      (p1[0] + tw + 4, p1[1]), color, -1)
        cv2.putText(frame, label, (p1[0] + 2, max(th + 2, p1[1] - 4)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
    cv2.putText(frame, f"FPS {fps:.2f}", (8, 24),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
    return frame
