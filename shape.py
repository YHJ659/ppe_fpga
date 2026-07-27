from ultralytics import YOLO
import torch

model = YOLO("models/best.pt").model
model.eval()

def hook(module, input, output):
    print("model.6 입력 shape:", input[0].shape)
    print("model.6 출력 shape:", output.shape)

model.model[6].register_forward_hook(hook)

dummy = torch.randn(1, 3, 640, 640)
model(dummy)