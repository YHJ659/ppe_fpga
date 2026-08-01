#!/usr/bin/env python3
"""Check whether the submitted per-IP vectors form one connected C2f chain."""

from __future__ import annotations

import array
import hashlib
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BRANCH_ROOT = Path(os.environ.get("PPE_BRANCH_ROOT", ROOT / "branches"))
BRANCH = BRANCH_ROOT / "HyunJun_Yoo"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def int32_values(path: Path) -> array.array:
    values = array.array("i")
    with path.open("rb") as stream:
        values.fromfile(stream, path.stat().st_size // values.itemsize)
    if sys.byteorder != "little":
        values.byteswap()
    return values


def compare_int32(left: Path, right: Path) -> tuple[int, int, float, int]:
    a = int32_values(left)
    b = int32_values(right)
    if len(a) != len(b):
        raise ValueError(f"length mismatch: {left}={len(a)}, {right}={len(b)}")
    exact = 0
    maximum = 0
    total = 0
    for x, y in zip(a, b):
        delta = abs(x - y)
        exact += delta == 0
        maximum = max(maximum, delta)
        total += delta
    return exact, len(a), total / len(a), maximum


def require_elements(path: Path, count: int, item_bytes: int = 4) -> None:
    expected = count * item_bytes
    actual = path.stat().st_size
    if actual != expected:
        raise ValueError(f"{path}: expected {expected} bytes, got {actual}")


def main() -> int:
    c64 = 64 * 40 * 40
    c128 = 128 * 40 * 40
    c256 = 256 * 40 * 40

    size_contracts = {
        BRANCH / "conv3x3" / "input.bin": c64,
        BRANCH / "conv3x3" / "weight.bin": 64 * 64 * 3 * 3,
        BRANCH / "conv3x3" / "golden_output.bin": c64 * 2,  # int64
        BRANCH / "conv1x1" / "input.bin": c128,
        BRANCH / "conv1x1" / "weight.bin": 128 * 128,
        BRANCH / "conv1x1" / "golden_output.bin": c128 * 2,  # int64
        BRANCH / "Split" / "split_cv1" / "input.bin": c128,
        BRANCH / "Split" / "split_cv1" / "golden_y0.bin": c64,
        BRANCH / "Split" / "split_cv1" / "golden_y1.bin": c64,
        BRANCH / "Concat" / "concat_c2f6" / "golden_output.bin": c256,
    }
    for path, count in size_contracts.items():
        require_elements(path, count)
    print(f"PASS vector byte-size contracts: {len(size_contracts)} files")

    split_y0 = BRANCH / "Split" / "split_cv1" / "golden_y0.bin"
    split_y1 = BRANCH / "Split" / "split_cv1" / "golden_y1.bin"
    concat_y0 = BRANCH / "Concat" / "concat_c2f6" / "y0.bin"
    concat_y1 = BRANCH / "Concat" / "concat_c2f6" / "y1.bin"

    if sha256(split_y0) != sha256(concat_y0):
        raise ValueError("split y0 and concat y0 should be the same connected tensor")
    print("PASS connected tensor: split.y0 == concat.y0 (bit exact)")

    exact, count, mean_delta, max_delta = compare_int32(split_y1, concat_y1)
    if exact == count:
        print("PASS connected tensor: split.y1 == concat.y1")
    else:
        print(
            "BLOCKED quantization contract: split.y1 != concat.y1 "
            f"(exact={exact}/{count}, mean_abs_diff={mean_delta:.3f}, max_abs_diff={max_delta})"
        )

    print(
        "BLOCKED model6 chain: concat emits 256 channels, but the submitted "
        "conv1x1 consumes only 128 channels; final cv2 256->128 is absent."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
