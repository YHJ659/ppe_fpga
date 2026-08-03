import torch
import numpy as np
import os
from ultralytics import YOLO

torch.manual_seed(42)

model = YOLO("models/best.pt").model
model.eval()

save_dir = "Split/split_cv1"
os.makedirs(save_dir, exist_ok=True)

# ===== model.6.cv1의 출력(128채널)을 캡처 — 이게 Split의 입력 =====
captured_output = {}
def hook(module, input, output):
    captured_output['data'] = output.detach()

h = model.model[6].cv1.register_forward_hook(hook)
dummy = torch.randn(1, 3, 640, 640)
model(dummy)
h.remove()

cv1_out_tensor = captured_output['data'][0]  # [128, 40, 40]

# 양자화 (cv1 SiLU 출력 기준 — bn_silu_128의 output_scale과 사실상 같은 개념)
i_min, i_max = cv1_out_tensor.min().item(), cv1_out_tensor.max().item()
input_scale = max(abs(i_min), abs(i_max)) / 127.0
input_int8 = torch.clamp(torch.round(cv1_out_tensor / input_scale), -128, 127).to(torch.int32)

# ===== Split 연산 (그냥 채널 자르기 — 이게 정답) =====
y0 = input_int8[:64, :, :]    # 앞쪽 절반
y1 = input_int8[64:, :, :]    # 뒤쪽 절반

# 파일로 저장
input_int8.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/input.bin")
y0.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/golden_y0.bin")
y1.numpy().astype(np.int32).flatten().tofile(f"{save_dir}/golden_y1.bin")

print(f"input_scale = {input_scale}")
print("저장 완료:", save_dir)