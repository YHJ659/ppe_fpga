#!/usr/bin/env python3
"""Collect real camera PRE/FPGA/POST calibration tensors on the KV260."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

from hw.hw_driver import Model6Fpga
from sw.hybrid_pipeline import letterbox


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--output", default="calib_int8")
    args = parser.parse_args()
    out = Path(args.output)
    (out / "images").mkdir(parents=True, exist_ok=True)
    with open("calib_out/calib_params.json", encoding="utf-8") as stream:
        calib = json.load(stream)
    scale = float(calib["boundary"]["hw_in_scale"])
    s_cat = float(calib["activation_scale"]["S_cat"])
    pre = ort.InferenceSession("models/onnx/pre_model6.onnx",
                               providers=["CPUExecutionProvider"])
    fpga = Model6Fpga()
    camera = cv2.VideoCapture(args.camera, cv2.CAP_V4L2)
    if not camera.isOpened():
        camera = cv2.VideoCapture(args.camera)
    if not camera.isOpened():
        fpga.close()
        raise RuntimeError(f"cannot open camera {args.camera}")
    try:
        saved = 0
        while saved < args.count:
            ok, bgr = camera.read()
            if not ok:
                continue
            image, _, _, _ = letterbox(bgr, 640)
            rgb = np.ascontiguousarray(image[:, :, ::-1]).transpose(2, 0, 1)
            image_f32 = np.ascontiguousarray(rgb[None].astype(np.float32) / 255.0)
            feature, skip4 = pre.run(None, {"image": image_f32})
            q = np.clip(np.rint(feature[0] / scale), -128, 127).astype(np.int8)
            payload = np.ascontiguousarray(q.transpose(1, 2, 0)).ravel()
            raw = fpga.run(payload)
            hwc = raw.reshape(40, 40, 256).astype(np.float32)
            fpga_output = np.ascontiguousarray(hwc.transpose(2, 0, 1))[None] * s_cat
            np.savez(out / f"sample_{saved:04d}.npz", image=image_f32,
                     fpga_output=fpga_output, skip4=skip4)
            cv2.imwrite(str(out / "images" / f"sample_{saved:04d}.jpg"), bgr)
            saved += 1
            print(f"calibration {saved}/{args.count}")
    finally:
        camera.release()
        fpga.close()


if __name__ == "__main__":
    main()
