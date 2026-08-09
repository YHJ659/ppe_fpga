#!/usr/bin/env python3
"""Export the real CPU partitions around the external FPGA model.6.

The exported graphs are intentionally split at the same point as
sw/hybrid_pipeline.py.  The pre graph returns the model.6 input feature and
the layer-4 skip tensor.  The post graph accepts the dequantized FPGA tensor
and that skip tensor, then runs layers 6-22 including the Detect head.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import onnx
import torch
from ultralytics import YOLO


HW_LAYER = 6
IMAGE_SHAPE = (1, 3, 640, 640)
FPGA_SHAPE = (1, 256, 40, 40)


class SplitPre(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = torch.nn.ModuleList(list(model.model[:HW_LAYER]))

    def forward(self, image):
        x = image
        saved = {}
        for module in self.model:
            if module.f != -1:
                x = (saved[module.f] if isinstance(module.f, int) else
                     [x if source == -1 else saved[source] for source in module.f])
            x = module(x)
            if module.i in (4,):
                saved[module.i] = x
        return x, saved[4]


class SplitPost(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model6 = model.model[HW_LAYER]
        self.model = torch.nn.ModuleList(list(model.model[HW_LAYER + 1:]))
        self.layer_offset = HW_LAYER + 1

    def forward(self, fpga_output, skip4):
        # The existing working hybrid calls model.6.cv2 on the dequantized
        # FPGA result before recording layer 6 for the later Concat.
        x = self.model6.cv2(fpga_output)
        saved = {4: skip4, 6: x}
        for module in self.model:
            if module.f != -1:
                x = (saved[module.f] if isinstance(module.f, int) else
                     [x if source == -1 else saved[source] for source in module.f])
            x = module(x)
            absolute_index = module.i
            if absolute_index in (9, 12, 15, 18, 21):
                saved[absolute_index] = x
        return x[0] if isinstance(x, (tuple, list)) else x


def tensor_info(graph):
    values = []
    for value in list(graph.input) + list(graph.output):
        shape = []
        tensor_type = value.type.tensor_type
        for dim in tensor_type.shape.dim:
            shape.append(dim.dim_value if dim.dim_value else dim.dim_param)
        values.append({"name": value.name, "shape": shape,
                       "dtype": tensor_type.elem_type})
    return values


def export_one(module, args, path, input_names, output_names):
    module.eval()
    torch.onnx.export(
        module, args, str(path), opset_version=17,
        input_names=input_names, output_names=output_names,
        do_constant_folding=True, dynamo=False)
    model = onnx.load(str(path))
    onnx.checker.check_model(model)
    print(f"CHECKED {path}")
    for item in tensor_info(model.graph):
        print(f"  {item['name']}: shape={item['shape']} dtype={item['dtype']}")
    return tensor_info(model.graph)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", default="models/best.pt")
    parser.add_argument("--output-dir", default="models/onnx")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    loaded = YOLO(args.weights)
    model = loaded.model.eval()
    if len(model.model) != 23:
        raise RuntimeError(f"expected 23 model layers, got {len(model.model)}")
    if model.model[HW_LAYER].cv2.conv.in_channels != 256:
        raise RuntimeError("model.6 is not the calibrated 256-channel boundary")

    pre = SplitPre(model)
    post = SplitPost(model)
    image = torch.zeros(IMAGE_SHAPE, dtype=torch.float32)
    with torch.inference_mode():
        feature5, skip4 = pre(image)
    if tuple(feature5.shape) != (1, 128, 40, 40):
        raise RuntimeError(f"unexpected FPGA input feature shape {tuple(feature5.shape)}")
    if skip4.ndim != 4:
        raise RuntimeError(f"unexpected layer-4 skip shape {tuple(skip4.shape)}")

    pre_info = export_one(pre, (image,), output_dir / "pre_model6.onnx",
                          ["image"], ["fpga_feature", "skip4"])
    post_info = export_one(
        post, (torch.zeros(FPGA_SHAPE), skip4),
        output_dir / "post_model6.onnx", ["fpga_output", "skip4"], ["prediction"])
    metadata = {
        "model_layers": 23,
        "hardware_layer": HW_LAYER,
        "pre_outputs": ["fpga_feature", "skip4"],
        "post_inputs": ["fpga_output", "skip4"],
        "pre_graph": pre_info,
        "post_graph": post_info,
        "fpga_feature_shape": list(feature5.shape),
        "fpga_output_shape": list(FPGA_SHAPE),
        "skip_cross_boundary_indices": [4],
    }
    (output_dir / "split_metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(f"WROTE {output_dir / 'split_metadata.json'}")
    try:
        import onnxruntime as ort
        pre_session = ort.InferenceSession(
            str(output_dir / "pre_model6.onnx"), providers=["CPUExecutionProvider"])
        post_session = ort.InferenceSession(
            str(output_dir / "post_model6.onnx"), providers=["CPUExecutionProvider"])
        pre_values = pre_session.run(None, {"image": np.zeros(IMAGE_SHAPE, np.float32)})
        post_values = post_session.run(None, {
            "fpga_output": np.zeros(FPGA_SHAPE, np.float32),
            "skip4": np.zeros(tuple(skip4.shape), np.float32),
        })
        print(f"ORT SMOKE PASS pre={[tuple(x.shape) for x in pre_values]} "
              f"post={[tuple(x.shape) for x in post_values]}")
    except ImportError:
        print("ORT SMOKE SKIPPED: onnxruntime is not installed")


if __name__ == "__main__":
    main()
