import cv2
import time
from ultralytics import YOLO
from thop import profile
import torch

# 경로는 수정하세요.
model = YOLO("best.pt")
model.info(detailed=True)

dummy_input = torch.randn(1, 3, 960, 540)
flops, params = profile(model.model, inputs=(dummy_input,))
print(f"Total FLOPs: {flops / 1e9:.2f} GFLOPs")
print(f"Total Params: {params / 1e6:.2f} M")

cap = cv2.VideoCapture(0, cv2.CAP_DSHOW)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 960)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 540)

frame_count = 0
start_time = time.time()



while True:
    ret, frame = cap.read()
    if not ret:
        break

    results = model.predict(frame, imgsz=960, conf=0.5, verbose=False)
    annotated = results[0].plot()
    cv2.imshow("PPE Detection", annotated)

    frame_count += 1
    if frame_count % 30 == 0:
        elapsed = time.time() - start_time
        print(f"평균 FPS: {frame_count / elapsed:.2f}")

    if cv2.waitKey(1) & 0xFF == ord('q'):
        break




cap.release()
cv2.destroyAllWindows()
