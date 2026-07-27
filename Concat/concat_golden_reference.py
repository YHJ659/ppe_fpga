import torch
import torch.nn.functional as F
import numpy as np
import os
from ultralytics import YOLO

torch.manual_seed(42)

model = YOLO("models/best.pt").model
model.eval()

save_dir = "Concat/concat_c2f6"
os.makedirs(save_dir, exist_ok=True)

dummy = torch.randn(1, 3, 640, 640)

# ===== 4개 브랜치의 실제 출력을 각각 hook으로 캡처 =====
captured = {}

def make_hook(name):
    def hook(module, input, output):
        captured[name] = output.detach()
    return hook

# cv1의 출력(128채널) 캡처 -> 여기서 y0, y1로 나뉨
h_cv1 = model.model[6].cv1.register_forward_hook(make_hook('cv1_out'))
# m.0 (Bottleneck 0) 출력 캡처 -> y2
h_m0 = model.model[6].m[0].register_forward_hook(make_hook('m0_out'))
# m.1 (Bottleneck 1) 출력 캡처 -> y3
h_m1 = model.model[6].m[1].register_forward_hook(make_hook('m1_out'))

model(dummy)

h_cv1.remove()
h_m0.remove()
h_m1.remove()

# ===== 각 브랜치 양자화 =====
def quantize(tensor):
    t_min, t_max = tensor.min().item(), tensor.max().item()
    scale = max(abs(t_min), abs(t_max)) / 127.0
    q = torch.clamp(torch.round(tensor / scale), -128, 127).to(torch.int32)
    return q, scale

cv1_out = captured['cv1_out'][0]        # [128, 40, 40]
y0_float = cv1_out[:64, :, :]
y1_float = cv1_out[64:, :, :]

y0_int8, y0_scale = quantize(y0_float)
y1_int8, y1_scale = quantize(y1_float)

y2_float = captured['m0_out'][0]        # [64, 40, 40]
y2_int8, y2_scale = quantize(y2_float)

y3_float = captured['m1_out'][0]        # [64, 40, 40]
y3_int8, y3_scale = quantize(y3_float)

print(f"y0_scale={y0_scale}, y1_scale={y1_scale}, y2_scale={y2_scale}, y3_scale={y3_scale}")

# ===== 실제 concat 결과 (float 기준으로 합쳐서 -> 공통 스케일로 재양자화) =====
concat_float = torch.cat([y0_float, y1_float, y2_float, y3_float], dim=0)  # [256, 40, 40]

o_min, o_max = concat_float.min().item(), concat_float.max().item()
output_scale = max(abs(o_min), abs(o_max)) / 127.0
output_int8 = torch.clamp(torch.round(concat_float / output_scale), -128, 127).to(torch.int32)

print(f"output_scale = {output_scale}")

# ===== 파일 저장 =====
y0_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/y0.bin")
y1_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/y1.bin")
y2_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/y2.bin")
y3_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/y3.bin")
output_int8.numpy().flatten().tofile(f"{save_dir}/golden_output.bin")

print("저장 완료:", save_dir)