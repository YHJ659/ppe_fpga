#!/usr/bin/env python3
"""Reproduce two correctness defects in the submitted detection comparator."""

from __future__ import annotations

import os
import sys
import types
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BRANCH_ROOT = Path(os.environ.get("PPE_BRANCH_ROOT", ROOT / "branches"))
PYTHON_ROOT = BRANCH_ROOT / "Sangheon_Oh" / "ppe_yolo_verification_starter" / "python"
sys.path.insert(0, str(PYTHON_ROOT))

# metrics.py only needs NumPy for an unrelated tensor helper.  Keep this
# comparator probe dependency-free instead of downloading packages.
sys.modules.setdefault("numpy", types.ModuleType("numpy"))

from ppe_verify.metrics import compare_frame  # noqa: E402
from ppe_verify.schema import Detection, FrameResult  # noqa: E402


def det(name: str, box: tuple[float, float, float, float]) -> Detection:
    return Detection(class_id=0, class_name=name, confidence=0.9, bbox_xyxy=box)


def frame(*detections: Detection) -> FrameResult:
    return FrameResult("frame", 100, 100, tuple(detections))


def main() -> int:
    # A complete matching exists: g0->a1 and g1->a0.  Greedy g0->a0 consumes
    # the only candidate for g1 and therefore creates a false FAIL.
    g0 = det("helmet", (0, 0, 10, 10))
    g1 = det("helmet", (4, 0, 14, 10))
    a0 = det("helmet", (1, 0, 11, 10))
    a1 = det("helmet", (-2, 0, 8, 10))
    greedy = compare_frame(frame(g0, g1), frame(a0, a1), 0.5, 0.1)
    if greedy.passed:
        print("FIXED comparator matching: complete bipartite match found")
    else:
        print(
            "REPRODUCED greedy false FAIL: "
            f"matches={len(greedy.matches)} missing={len(greedy.missing)} "
            f"unexpected={len(greedy.unexpected)}"
        )

    wrong_name = compare_frame(
        frame(det("helmet", (0, 0, 10, 10))),
        frame(det("no_helmet", (0, 0, 10, 10))),
        0.5,
        0.1,
    )
    if wrong_name.passed:
        print("REPRODUCED class-map false PASS: class_id=0 accepted helmet -> no_helmet")
    else:
        print("FIXED class-map validation: class name mismatch rejected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
