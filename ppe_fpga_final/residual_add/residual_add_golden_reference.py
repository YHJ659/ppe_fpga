import torch
import torch.nn.functional as F
import numpy as np
import os
from ultralytics import YOLO

torch.manual_seed(42)

model = YOLO("models/best.pt").model
model.eval()

save_dir = "residual_add/residual_m0"
os.makedirs(save_dir, exist_ok=True)

# ===== m.0.cv2 (Bottleneck 0의 두 번째 conv3x3) =====
weight_tensor = model.model[6].m[0].cv2.conv.weight.detach()  # [64, 64, 3, 3]
bn = model.model[6].m[0].cv2.bn

# m.0.cv2의 입력 = m.0.cv1 -> bn_silu의 출력. 이걸 실제로 hook으로 캡처
captured_input = {}
def hook(module, input, output):
    captured_input['data'] = input[0].detach()

h = model.model[6].m[0].cv2.register_forward_hook(hook)
dummy = torch.randn(1, 3, 640, 640)
model(dummy)
h.remove()

cv2_input_tensor = captured_input['data'][0]  # [64, 40, 40] (m.0.cv1의 SiLU 출력)

# 양자화
w_min, w_max = weight_tensor.min().item(), weight_tensor.max().item()
weight_scale = max(abs(w_min), abs(w_max)) / 127.0
weight_int8 = torch.clamp(torch.round(weight_tensor / weight_scale), -128, 127).to(torch.int32)

i_min, i_max = cv2_input_tensor.min().item(), cv2_input_tensor.max().item()
cv2_input_scale = max(abs(i_min), abs(i_max)) / 127.0
cv2_input_int8 = torch.clamp(torch.round(cv2_input_tensor / cv2_input_scale), -128, 127).to(torch.int32)

# conv -> BN -> SiLU (fx = F(x))
conv_out = F.conv2d(cv2_input_int8.unsqueeze(0).float(), weight_int8.float(), padding=1).squeeze(0)
conv_out_float = conv_out.unsqueeze(0) * cv2_input_scale * weight_scale
bn_out = F.batch_norm(conv_out_float, bn.running_mean, bn.running_var, bn.weight, bn.bias, training=False, eps=bn.eps)
fx_float = (bn_out * torch.sigmoid(bn_out)).squeeze(0)

fx_min, fx_max = fx_float.min().item(), fx_float.max().item()
fx_scale = max(abs(fx_min), abs(fx_max)) / 127.0
fx_int8 = torch.clamp(torch.round(fx_float / fx_scale), -128, 127).to(torch.int32)

print(f"fx_scale = {fx_scale}")

# ===== Bottleneck 최초 입력 x (Shortcut 경로) =====
# m.0의 입력을 캡처 (m.0.cv1의 입력과 동일한 지점)
captured_x = {}
def hook_x(module, input, output):
    captured_x['data'] = input[0].detach()

hx = model.model[6].m[0].register_forward_hook(hook_x)
model(dummy)
hx.remove()

x_tensor = captured_x['data'][0]
x_min, x_max = x_tensor.min().item(), x_tensor.max().item()
x_scale = max(abs(x_min), abs(x_max)) / 127.0
x_int8 = torch.clamp(torch.round(x_tensor / x_scale), -128, 127).to(torch.int32)

print(f"x_scale = {x_scale}")

# ===== 잔차 덧셈 골든 레퍼런스 =====
x_float = x_int8.float() * x_scale
sum_float = x_float + fx_float

o_min, o_max = sum_float.min().item(), sum_float.max().item()
output_scale = max(abs(o_min), abs(o_max)) / 127.0
output_int8 = torch.clamp(torch.round(sum_float / output_scale), -128, 127).to(torch.int32)

x_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/x_input.bin")
fx_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/fx_input.bin")
output_int8.numpy().flatten().tofile(f"{save_dir}/golden_output.bin")

print(f"output_scale = {output_scale}")
print("저장 완료:", save_dir)