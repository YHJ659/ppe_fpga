from __future__ import annotations

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Profile a YOLO model with a BCHW dummy tensor")
    parser.add_argument("--model", type=Path, default=Path("models/best.pt"))
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=540)
    return parser.parse_args()


def main() -> int:
    try:
        import torch
        from thop import profile
        from ultralytics import YOLO
    except ImportError as error:
        raise SystemExit("torch, thop, and ultralytics are required") from error

    args = parse_args()
    model = YOLO(str(args.model))
    model.info(detailed=True)
    # Camera width x height = 960 x 540 -> BCHW tensor = 1 x 3 x 540 x 960.
    dummy = torch.randn(1, 3, args.height, args.width)
    flops, params = profile(model.model, inputs=(dummy,), verbose=False)
    print(f"Total FLOPs: {flops / 1e9:.2f} GFLOPs")
    print(f"Total Params: {params / 1e6:.2f} M")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

