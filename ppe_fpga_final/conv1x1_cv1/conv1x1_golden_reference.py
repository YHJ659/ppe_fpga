import torch
import numpy as np
from ultralytics import YOLO

model = YOLO("models/best.pt").model
model.eval()

# model.6.cv1 (C2f 블록의 cv1, 1x1 Conv)의 실제 가중치 추출
weight_tensor = model.model[6].cv1.conv.weight.detach()  # shape: [128, 128, 1, 1]
print("가중치 shape:", weight_tensor.shape)

# float32 → INT8 양자화
w_min, w_max = weight_tensor.min().item(), weight_tensor.max().item()
scale = max(abs(w_min), abs(w_max)) / 127.0
weight_int8 = torch.clamp(torch.round(weight_tensor / scale), -128, 127).to(torch.int32)

print(f"스케일 팩터: {scale}")
print(f"양자화 후 범위: {weight_int8.min().item()} ~ {weight_int8.max().item()}")

# model.6.cv1에 실제로 들어가는 입력(feature map) 캡처
captured_input = {}
def hook(module, input, output):
    captured_input['data'] = input[0].detach()

h = model.model[6].cv1.register_forward_hook(hook)
dummy = torch.randn(1, 3, 640, 640)
model(dummy)
h.remove()

input_tensor = captured_input['data'][0]  # [128, 40, 40] (배치 차원 제거)
i_min, i_max = input_tensor.min().item(), input_tensor.max().item()
i_scale = max(abs(i_min), abs(i_max)) / 127.0
input_int8 = torch.clamp(torch.round(input_tensor / i_scale), -128, 127).to(torch.int32)

# golden reference 계산 (1x1 Conv, 패딩 없음)
import torch.nn.functional as F
output_golden = F.conv2d(
    input_int8.unsqueeze(0).float(),
    weight_int8.float(),
    padding=0   # 1x1 커널은 패딩이 필요 없음
).squeeze(0).to(torch.int64)

# 파일로 저장 (conv1x1 전용 폴더에)
input_int8.numpy().astype(np.int32).flatten().tofile("conv1x1/input.bin")
weight_int8.numpy().astype(np.int32).flatten().tofile("conv1x1/weight.bin")
output_golden.numpy().flatten().tofile("conv1x1/golden_output.bin")

print("저장 완료: 실제 model.6.cv1 가중치 기반 input.bin, weight.bin, golden_output.bin")