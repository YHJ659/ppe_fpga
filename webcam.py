from ultralytics import YOLO
import cv2
import time

model=YOLO("models/best.pt")
names=model.names
cap=cv2.VideoCapture(0)
prev=time.time()

while True:
    ret,frame=cap.read()
    if not ret: break
    results=model.predict(frame,conf=0.4,verbose=False)
    result=results[0]
    img=frame.copy()

    helmet=vest=mask=False
    for box in result.boxes:
        label=names[int(box.cls[0])]
        if label=="Hardhat": helmet=True
        elif label=="Safety Vest": vest=True
        elif label=="Mask": mask=True

    passed=helmet and vest and mask
    person_color=(0,255,0) if passed else (0,0,255)

    for box in result.boxes:
        label=names[int(box.cls[0])]
        conf=float(box.conf[0])
        x1,y1,x2,y2=map(int,box.xyxy[0])

        if label=="Person":
            c=(0,0,0)
        elif label in ["Hardhat","Safety Vest","Mask"]:
            c=(0,255,0)
        else:
            c=(0,0,255)

        cv2.rectangle(img,(x1,y1),(x2,y2),c,2)
        cv2.putText(img,f"{label} {conf:.2f}",(x1,y1-10),
                    cv2.FONT_HERSHEY_SIMPLEX,0.6,c,2)

    now=time.time()
    fps=1/(now-prev)
    prev=now

    cv2.putText(img,f"FPS : {fps:.2f}",(20,40),
                cv2.FONT_HERSHEY_SIMPLEX,0.8,(255,255,255),2)
    cv2.putText(img,"STATUS : PASS" if passed else "STATUS : FAIL",
                (20,80),cv2.FONT_HERSHEY_SIMPLEX,1,person_color,3)

    info=[("Helmet",helmet,130),("Vest",vest,165),("Mask",mask,200)]
    for text,ok,y in info:
        cv2.putText(img,f"{text} : {'OK' if ok else 'NO'}",
                    (20,y),cv2.FONT_HERSHEY_SIMPLEX,0.7,
                    (0,255,0) if ok else (0,0,255),2)

    cv2.imshow("PPE Detection",img)
    if cv2.waitKey(1)&0xFF==ord("q"):
        break

cap.release()
cv2.destroyAllWindows()
