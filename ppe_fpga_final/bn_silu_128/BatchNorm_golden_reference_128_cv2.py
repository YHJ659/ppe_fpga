import torch
import torch.nn.functional as F
import numpy as np
from ultralytics import YOLO

torch.manual_seed(42)

model = YOLO("models/best.pt").model
model.eval()

save_dir = "BatchNorm_128/bn_silu_128cv2"
import os
os.makedirs(save_dir, exist_ok=True)

# ===== model.6.cv2 (C2f의 cv2, 1x1 Conv, 256->128) 기준 =====
weight_tensor = model.model[6].cv2.conv.weight.detach()  # [128, 256, 1, 1]
bn = model.model[6].cv2.bn

captured_input = {}
def hook(module, input, output):
    captured_input['data'] = input[0].detach()

h = model.model[6].cv2.register_forward_hook(hook)
dummy = torch.randn(1, 3, 640, 640)
model(dummy)
h.remove()

input_tensor = captured_input['data'][0]  # [256, 40, 40] — concat 직후 입력

# 양자화
w_min, w_max = weight_tensor.min().item(), weight_tensor.max().item()
weight_scale = max(abs(w_min), abs(w_max)) / 127.0
weight_int8 = torch.clamp(torch.round(weight_tensor / weight_scale), -128, 127).to(torch.int32)

i_min, i_max = input_tensor.min().item(), input_tensor.max().item()
input_scale = max(abs(i_min), abs(i_max)) / 127.0
input_int8 = torch.clamp(torch.round(input_tensor / input_scale), -128, 127).to(torch.int32)

print(f"input_scale = {input_scale}, weight_scale = {weight_scale}")

# conv (1x1, 패딩 없음)
conv_out = F.conv2d(input_int8.unsqueeze(0).float(), weight_int8.float(), padding=0)
conv_out = conv_out.squeeze(0)
conv_out.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/conv_out.bin")

# 역양자화 + BatchNorm + SiLU
conv_out_float = conv_out.unsqueeze(0) * input_scale * weight_scale
bn_out = F.batch_norm(
    conv_out_float, bn.running_mean, bn.running_var,
    bn.weight, bn.bias, training=False, eps=bn.eps
)
silu_out = (bn_out * torch.sigmoid(bn_out)).squeeze(0)

# 재양자화
o_min, o_max = silu_out.min().item(), silu_out.max().item()
output_scale = max(abs(o_min), abs(o_max)) / 127.0
output_int8 = torch.clamp(torch.round(silu_out / output_scale), -128, 127).to(torch.int32)
output_int8.numpy().flatten().tofile(f"{save_dir}/golden_output.bin")

print(f"output_scale = {output_scale}")

# bn_scale, bn_shift
gamma = bn.weight.detach()
beta = bn.bias.detach()
running_mean = bn.running_mean.detach()
running_var = bn.running_var.detach()
eps = bn.eps

bn_scale = gamma / torch.sqrt(running_var + eps)
bn_shift = beta - running_mean * bn_scale

bn_scale.numpy().astype(np.float32).tofile(f"{save_dir}/bn_scale.bin")
bn_shift.numpy().astype(np.float32).tofile(f"{save_dir}/bn_shift.bin")

print("저장 완료:", save_dir)