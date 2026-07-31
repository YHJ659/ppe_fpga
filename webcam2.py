from ultralytics import YOLO
import cv2
import time

print("Loading model...")
model = YOLO("models/best.pt")
names = model.names
print("Model Loaded!")

cap = cv2.VideoCapture(0, cv2.CAP_V4L2)

cap.set(cv2.CAP_PROP_FRAME_WIDTH,640)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT,480)

if not cap.isOpened():
    print("Camera open failed")
    exit()

prev=time.time()

frame_count=0
last_result=None

while True:

    ret,frame=cap.read()

    if not ret:
        continue

    frame_count+=1

    h,w=frame.shape[:2]

    small=cv2.resize(frame,(320,320))

    if frame_count%3==0 or last_result is None:

        results=model.predict(
            small,
            imgsz=320,
            conf=0.4,
            verbose=False
        )

        last_result=results[0]

    result=last_result

    helmet=False
    vest=False
    mask=False

    sx=w/320
    sy=h/320

    for box in result.boxes:

        label=names[int(box.cls[0])]

        if label=="Hardhat":
            helmet=True
        elif label=="Safety Vest":
            vest=True
        elif label=="Mask":
            mask=True

        x1,y1,x2,y2=box.xyxy[0]

        x1=int(x1*sx)
        x2=int(x2*sx)
        y1=int(y1*sy)
        y2=int(y2*sy)

        conf=float(box.conf[0])

        if label=="Person":
            color=(255,255,0)
        elif label in ["Hardhat","Safety Vest","Mask"]:
            color=(0,255,0)
        else:
            color=(0,0,255)

        cv2.rectangle(frame,(x1,y1),(x2,y2),color,2)

        cv2.putText(
            frame,
            f"{label} {conf:.2f}",
            (x1,y1-8),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.5,
            color,
            2
        )

    passed=helmet and vest and mask

    now=time.time()

    fps=1/(now-prev)

    prev=now

    cv2.putText(frame,
                f"FPS : {fps:.1f}",
                (15,30),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.8,
                (255,255,255),
                2)

    cv2.putText(frame,
                "PASS" if passed else "FAIL",
                (15,65),
                cv2.FONT_HERSHEY_SIMPLEX,
                1,
                (0,255,0) if passed else (0,0,255),
                2)

    cv2.imshow("PPE Detection",frame)

    if cv2.waitKey(1)&0xFF==ord("q"):
        break

cap.release()
cv2.destroyAllWindows()
