from __future__ import annotations

import argparse
from pathlib import Path

from ppe_verify.io_utils import save_results
from ppe_verify.schema import Detection, FrameResult


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export Ultralytics YOLO outputs as golden JSON")
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--images", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--imgsz", type=int, default=960)
    parser.add_argument("--conf", type=float, default=0.50)
    parser.add_argument("--device", default="cpu")
    return parser.parse_args()


def collect_images(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return sorted(
        candidate
        for candidate in path.iterdir()
        if candidate.is_file() and candidate.suffix.lower() in IMAGE_SUFFIXES
    )


def main() -> int:
    args = parse_args()
    try:
        from ultralytics import YOLO
    except ImportError as error:
        raise SystemExit("ultralytics is required: python3 -m pip install -r requirements.txt") from error

    if not args.model.is_file():
        raise SystemExit(f"model not found: {args.model}")
    images = collect_images(args.images)
    if not images:
        raise SystemExit(f"no images found: {args.images}")

    model = YOLO(str(args.model))
    frames: list[FrameResult] = []
    for image_path in images:
        result = model.predict(
            source=str(image_path),
            imgsz=args.imgsz,
            conf=args.conf,
            device=args.device,
            verbose=False,
        )[0]
        height, width = result.orig_shape
        names = result.names
        detections: list[Detection] = []
        if result.boxes is not None:
            boxes = result.boxes.xyxy.detach().cpu().numpy()
            confidences = result.boxes.conf.detach().cpu().numpy()
            class_ids = result.boxes.cls.detach().cpu().numpy().astype(int)
            for box, confidence, class_id in zip(boxes, confidences, class_ids):
                detections.append(
                    Detection(
                        class_id=int(class_id),
                        class_name=str(names[int(class_id)]),
                        confidence=float(confidence),
                        bbox_xyxy=tuple(float(value) for value in box),
                    )
                )
        frames.append(
            FrameResult(
                frame_id=image_path.name,
                width=int(width),
                height=int(height),
                detections=tuple(detections),
            )
        )

    save_results(args.output, frames)
    print(f"wrote {len(frames)} frame(s) to {args.output}")
    print(f"model classes: {model.names}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

