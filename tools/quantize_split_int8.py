#!/usr/bin/env python3
"""Static QDQ INT8 quantization using real PRE/POST calibration tensors."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from onnxruntime.quantization import (
    CalibrationDataReader, CalibrationMethod, QuantFormat, QuantType,
    quantize_static,
)


class Reader(CalibrationDataReader):
    def __init__(self, files, names):
        self.items = []
        for path in files:
            with np.load(path) as sample:
                self.items.append({name: np.asarray(sample[name], dtype=np.float32)
                                   for name in names})
        self.index = 0

    def get_next(self):
        if self.index >= len(self.items):
            return None
        item = self.items[self.index]
        self.index += 1
        return item


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--calibration", default="calib_int8")
    parser.add_argument("--graphs", default="models/onnx")
    args = parser.parse_args()
    files = sorted(Path(args.calibration).glob("sample_*.npz"))
    if len(files) < 10:
        raise RuntimeError("collect at least 10 real calibration samples first")
    graph_dir = Path(args.graphs)
    options = {
        "ActivationSymmetric": True,
        "WeightSymmetric": True,
        "DedicatedQDQPair": True,
    }
    quantize_static(
        str(graph_dir / "pre_model6.onnx"),
        str(graph_dir / "pre_model6_int8.onnx"),
        Reader(files, ["image"]),
        quant_format=QuantFormat.QDQ,
        activation_type=QuantType.QInt8,
        weight_type=QuantType.QInt8,
        per_channel=True,
        calibrate_method=CalibrationMethod.MinMax,
        extra_options=options)
    quantize_static(
        str(graph_dir / "post_model6.onnx"),
        str(graph_dir / "post_model6_int8.onnx"),
        Reader(files, ["fpga_output", "skip4"]),
        quant_format=QuantFormat.QDQ,
        activation_type=QuantType.QInt8,
        weight_type=QuantType.QInt8,
        per_channel=True,
        calibrate_method=CalibrationMethod.MinMax,
        extra_options=options)
    print("WROTE pre_model6_int8.onnx and post_model6_int8.onnx")


if __name__ == "__main__":
    main()
