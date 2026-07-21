"""Live camera demo based on the team's prototype. This is not a regression test."""

from __future__ import annotations

import argparse
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, default=Path("models/best.pt"))
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=540)
    parser.add_argument("--imgsz", type=int, default=960)
    parser.add_argument("--conf", type=float, default=0.50)
    return parser.parse_args()


def main() -> int:
    try:
        import cv2
        from ultralytics import YOLO
    except ImportError as error:
        raise SystemExit("opencv-python and ultralytics are required; install requirements.txt") from error

    args = parse_args()
    model = YOLO(str(args.model))
    model.info(detailed=True)

    backend = cv2.CAP_DSHOW if hasattr(cv2, "CAP_DSHOW") else cv2.CAP_ANY
    cap = cv2.VideoCapture(args.camera, backend)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    if not cap.isOpened():
        raise SystemExit(f"camera {args.camera} could not be opened")

    frame_count = 0
    start_time = time.perf_counter()
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            result = model.predict(frame, imgsz=args.imgsz, conf=args.conf, verbose=False)[0]
            cv2.imshow("PPE Detection", result.plot())
            frame_count += 1
            if frame_count % 30 == 0:
                elapsed = time.perf_counter() - start_time
                print(f"average FPS: {frame_count / elapsed:.2f}")
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
    finally:
        cap.release()
        cv2.destroyAllWindows()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

