import torch
import numpy as np
from ultralytics import YOLO

model = YOLO("models/best.pt").model
model.eval()

def extract_bn_scale_shift(bn_module, save_prefix):
    gamma = bn_module.weight.detach()
    beta = bn_module.bias.detach()
    running_mean = bn_module.running_mean.detach()
    running_var = bn_module.running_var.detach()
    eps = bn_module.eps

    scale = gamma / torch.sqrt(running_var + eps)
    shift = beta - running_mean * scale

    scale.numpy().astype(np.float32).tofile(f"{save_prefix}_scale.bin")
    shift.numpy().astype(np.float32).tofile(f"{save_prefix}_shift.bin")

    print(f"[{save_prefix}] scale 범위: {scale.min().item():.4f} ~ {scale.max().item():.4f}")
    print(f"[{save_prefix}] shift 범위: {shift.min().item():.4f} ~ {shift.max().item():.4f}")

    return scale, shift

# model.6.cv1의 BatchNorm (C2f의 cv1, 128채널)
extract_bn_scale_shift(model.model[6].cv1.bn, "BatchNorm/bn/cv1")

# model.6.m.0.cv1의 BatchNorm (Bottleneck 0의 첫 conv3x3, 64채널)
extract_bn_scale_shift(model.model[6].m[0].cv1.bn, "BatchNorm/bn/m0_cv1")