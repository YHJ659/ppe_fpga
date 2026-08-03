import torch
import torch.nn.functional as F
import numpy as np
from ultralytics import YOLO


torch.manual_seed(42)
model = YOLO("models/best.pt").model
model.eval()

# ===== 1. 가중치 추출 =====
weight_tensor = model.model[6].m[0].cv1.conv.weight.detach()  # [64, 64, 3, 3]
bn = model.model[6].m[0].cv1.bn

# ===== 2. 실제 입력(feature map) 캡처 =====
captured_input = {}
def hook(module, input, output):
    captured_input['data'] = input[0].detach()

h = model.model[6].m[0].cv1.register_forward_hook(hook)
dummy = torch.randn(1, 3, 640, 640)
model(dummy)
h.remove()

input_tensor = captured_input['data'][0]  # [64, 40, 40]

# ===== 3. 입력/가중치 양자화 (INT8) — 이 부분이 빠져 있었음 =====
w_min, w_max = weight_tensor.min().item(), weight_tensor.max().item()
weight_scale = max(abs(w_min), abs(w_max)) / 127.0
weight_int8 = torch.clamp(torch.round(weight_tensor / weight_scale), -128, 127).to(torch.int32)

i_min, i_max = input_tensor.min().item(), input_tensor.max().item()
input_scale = max(abs(i_min), abs(i_max)) / 127.0
input_int8 = torch.clamp(torch.round(input_tensor / input_scale), -128, 127).to(torch.int32)

print(f"input_scale = {input_scale}, weight_scale = {weight_scale}")

# ===== 4. conv 연산 =====
conv_out = F.conv2d(input_int8.unsqueeze(0).float(), weight_int8.float(), padding=1)
conv_out = conv_out.squeeze(0)  # [1,64,40,40] -> [64,40,40]

# conv_out.bin 저장
conv_out.numpy().astype(np.int32).flatten().tofile("BatchNorm/bn_silu_m0cv1/conv_out.bin")

# ===== 5. 역양자화 =====
conv_out_float = conv_out.unsqueeze(0) * input_scale * weight_scale

# ===== 6. BatchNorm =====
bn_out = F.batch_norm(
    conv_out_float, bn.running_mean, bn.running_var,
    bn.weight, bn.bias, training=False, eps=bn.eps
)

# ===== 7. SiLU =====
silu_out = bn_out * torch.sigmoid(bn_out)

# ===== 8. 재양자화 =====
silu_out = silu_out.squeeze(0)
o_min, o_max = silu_out.min().item(), silu_out.max().item()
output_scale = max(abs(o_min), abs(o_max)) / 127.0
output_int8 = torch.clamp(torch.round(silu_out / output_scale), -128, 127).to(torch.int32)

# golden_output.bin 저장
output_int8.numpy().flatten().tofile("BatchNorm/bn_silu_m0cv1/golden_output.bin")

# ===== 9. bn_scale, bn_shift도 이 스크립트에서 같이 생성 (한 곳에서 관리) =====
gamma = bn.weight.detach()
beta = bn.bias.detach()
running_mean = bn.running_mean.detach()
running_var = bn.running_var.detach()
eps = bn.eps

bn_scale = gamma / torch.sqrt(running_var + eps)
bn_shift = beta - running_mean * bn_scale

bn_scale.numpy().astype(np.float32).tofile("BatchNorm/bn_silu_m0cv1/bn_scale.bin")
bn_shift.numpy().astype(np.float32).tofile("BatchNorm/bn_silu_m0cv1/bn_shift.bin")

print(f"output_scale = {output_scale}")
print("conv_out.bin, golden_output.bin, bn_scale.bin, bn_shift.bin 저장 완료")