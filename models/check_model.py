from ultralytics import YOLO

model = YOLO("models/best.pt")

m = model.model.model[6]

print(type(m))
print()

print("cv1")
print(m.cv1)

print()

print("cv2")
print(m.cv2)

print()

print("m")
print(m.m)
