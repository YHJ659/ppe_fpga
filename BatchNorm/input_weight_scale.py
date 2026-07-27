import torch
import torch.nn.functional as F
import numpy as np
import os

model_path = "models/best.pt"
from ultralytics import YOLO

torch.manual_seed(42)

model = YOLO(model_path).model
model.eval()

save_dir = "BatchNorm/bn_silu_m0cv1"
os.makedirs(save_dir, exist_ok=True)

# ===== 1. 가중치 및 BatchNorm 파라미터 추출 =====
conv_layer = model.model[6].m[0].cv1.conv
bn_layer = model.model[6].m[0].cv1.bn

weight_tensor = conv_layer.weight.detach()  # [64, 64, 3, 3]

# ===== 2. 실제 입력(feature map) 캡처 =====
captured_input = {}
def hook(module, input, output):
    captured_input['data'] = input[0].detach()



h = model.model[6].m[0].cv1.register_forward_hook(hook)
dummy = torch.randn(1, 3, 640, 640)
model(dummy)
h.remove()

input_tensor = captured_input['data'][0]  # [64, 40, 40]

# ===== 3. 입력/가중치 양자화 (INT8) — 스케일 팩터를 이번엔 명확히 변수로 보관 =====
w_min, w_max = weight_tensor.min().item(), weight_tensor.max().item()
weight_scale = max(abs(w_min), abs(w_max)) / 127.0
weight_int8 = torch.clamp(torch.round(weight_tensor / weight_scale), -128, 127).to(torch.int32)

i_min, i_max = input_tensor.min().item(), input_tensor.max().item()
input_scale = max(abs(i_min), abs(i_max)) / 127.0
input_int8 = torch.clamp(torch.round(input_tensor / input_scale), -128, 127).to(torch.int32)

print(f"input_scale = {input_scale}, weight_scale = {weight_scale}")

# ===== 4. INT8로 컨볼루션 (raw 정수 누적값, conv3x3.cpp와 동일 로직) =====
conv_out_raw = F.conv2d(
    input_int8.unsqueeze(0).float(),
    weight_int8.float(),
    padding=1
).squeeze(0)  # [64, 40, 40], 아직 raw INT32 스케일

# ===== 5. 역양자화 (raw INT32 -> 실제 float 물리량) =====
conv_out_float = conv_out_raw * input_scale * weight_scale

# ===== 6. BatchNorm 적용 (실제 float 값 기준) =====
bn_out = F.batch_norm(
    conv_out_float.unsqueeze(0),
    bn_layer.running_mean, bn_layer.running_var,
    bn_layer.weight, bn_layer.bias,
    training=False, eps=bn_layer.eps
).squeeze(0)

# ===== 7. SiLU 적용 =====
silu_out = bn_out * torch.sigmoid(bn_out)

# ===== 8. 다음 레이어 입력으로 쓸 재양자화 (INT8) =====
o_min, o_max = silu_out.min().item(), silu_out.max().item()
output_scale = max(abs(o_min), abs(o_max)) / 127.0
output_int8 = torch.clamp(torch.round(silu_out / output_scale), -128, 127).to(torch.int32)

print(f"output_scale = {output_scale}")

# ===== 9. HLS scale/shift (BatchNorm을 곱셈+덧셈으로 미리 합친 값) =====
gamma = bn_layer.weight.detach()
beta = bn_layer.bias.detach()
running_mean = bn_layer.running_mean.detach()
running_var = bn_layer.running_var.detach()
eps = bn_layer.eps

bn_scale = gamma / torch.sqrt(running_var + eps)
bn_shift = beta - running_mean * bn_scale

# ===== 10. 파일로 저장 =====
input_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/input.bin")
weight_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/weight.bin")
bn_scale.numpy().astype(np.float32).tofile(f"{save_dir}/bn_scale.bin")
bn_shift.numpy().astype(np.float32).tofile(f"{save_dir}/bn_shift.bin")
output_int8.numpy().flatten().tofile(f"{save_dir}/golden_output.bin")

# 스케일 값들도 텍스트로 남겨두기 (HLS 코드에 상수로 넣거나, 나중에 역추적할 때 필요)
with open(f"{save_dir}/scales.txt", "w") as f:
    f.write(f"input_scale={input_scale}\n")
    f.write(f"weight_scale={weight_scale}\n")
    f.write(f"output_scale={output_scale}\n")

print("저장 완료:", save_dir)