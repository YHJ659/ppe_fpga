"""Utilities for the untouched Ultralytics model.0--5 execution boundary."""
from __future__ import annotations

import torch


def validate_model0to5_boundary(model: torch.nn.Module) -> None:
    """Fail early if the loaded checkpoint is not the calibrated YOLOv8 graph."""
    layers = model.model
    if len(layers) < 7:
        raise RuntimeError("checkpoint does not contain model.0 through model.6")
    layer5, layer6 = layers[5], layers[6]
    if not hasattr(layer6, "cv2"):
        raise RuntimeError("model.6 is not the expected YOLOv8 C2f module")
    if getattr(layer5.conv, "out_channels", None) != 128:
        raise RuntimeError("model.5 output is not 128 channels")
    if layer6.cv2.conv.in_channels != 256 or layer6.cv2.conv.out_channels != 128:
        raise RuntimeError("model.6.cv2 is not the calibrated 256->128 convolution")
