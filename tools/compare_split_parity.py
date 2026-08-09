#!/usr/bin/env python3
"""Deterministic PyTorch-vs-ORT parity for both exported CPU partitions."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch
from ultralytics import YOLO

from export_split_onnx import SplitPost, SplitPre


def report(name, reference, actual):
    reference = np.asarray(reference, dtype=np.float32)
    actual = np.asarray(actual, dtype=np.float32)
    error = np.abs(reference - actual)
    print(f"{name}: shape={actual.shape} dtype={actual.dtype} "
          f"max_abs={error.max():.6g} mean_abs={error.mean():.6g} "
          f"ref_range=[{reference.min():.6g},{reference.max():.6g}]")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", default="models/best.pt")
    parser.add_argument("--graphs", default="models/onnx")
    args = parser.parse_args()
    model = YOLO(args.weights).model.eval()
    pre_pt, post_pt = SplitPre(model), SplitPost(model)
    image = torch.linspace(0.0, 1.0, 1 * 3 * 640 * 640).reshape(1, 3, 640, 640)
    with torch.inference_mode():
        feature_pt, skip_pt = pre_pt(image)
    pre_ort = ort.InferenceSession(str(Path(args.graphs) / "pre_model6.onnx"),
                                   providers=["CPUExecutionProvider"])
    post_ort = ort.InferenceSession(str(Path(args.graphs) / "post_model6.onnx"),
                                    providers=["CPUExecutionProvider"])
    feature_ort, skip_ort = pre_ort.run(None, {"image": image.numpy()})
    report("fpga_feature", feature_pt.numpy(), feature_ort)
    report("skip4", skip_pt.numpy(), skip_ort)

    rng = np.random.default_rng(6)
    fpga_output = rng.integers(-128, 128, (1, 256, 40, 40), dtype=np.int8)
    with torch.inference_mode():
        prediction_pt = post_pt(torch.from_numpy(fpga_output.astype(np.float32)),
                                skip_pt).numpy()
    prediction_ort = post_ort.run(None, {
        "fpga_output": fpga_output.astype(np.float32),
        "skip4": skip_ort,
    })[0]
    report("prediction", prediction_pt, prediction_ort)
    print("PARITY PASS" if np.allclose(prediction_pt, prediction_ort,
                                       rtol=1e-3, atol=1e-4) else "PARITY FAIL")


if __name__ == "__main__":
    main()
