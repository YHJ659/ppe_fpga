from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

import numpy as np

from .schema import Detection, FrameResult


def bbox_iou(
    left: tuple[float, float, float, float],
    right: tuple[float, float, float, float],
) -> float:
    lx1, ly1, lx2, ly2 = left
    rx1, ry1, rx2, ry2 = right
    ix1, iy1 = max(lx1, rx1), max(ly1, ry1)
    ix2, iy2 = min(lx2, rx2), min(ly2, ry2)
    intersection = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    left_area = max(0.0, lx2 - lx1) * max(0.0, ly2 - ly1)
    right_area = max(0.0, rx2 - rx1) * max(0.0, ry2 - ry1)
    union = left_area + right_area - intersection
    return intersection / union if union > 0.0 else 0.0


@dataclass(frozen=True)
class DetectionMatch:
    expected: Detection
    actual: Detection
    iou: float
    confidence_error: float


@dataclass
class FrameComparison:
    frame_id: str
    matches: list[DetectionMatch] = field(default_factory=list)
    missing: list[Detection] = field(default_factory=list)
    unexpected: list[Detection] = field(default_factory=list)
    confidence_mismatches: list[DetectionMatch] = field(default_factory=list)
    dimension_mismatch: str | None = None

    @property
    def passed(self) -> bool:
        return not (
            self.missing
            or self.unexpected
            or self.confidence_mismatches
            or self.dimension_mismatch
        )


@dataclass
class SuiteComparison:
    frames: list[FrameComparison]
    missing_frames: list[str]
    unexpected_frames: list[str]

    @property
    def passed(self) -> bool:
        return (
            not self.missing_frames
            and not self.unexpected_frames
            and all(frame.passed for frame in self.frames)
        )


def compare_frame(
    expected: FrameResult,
    actual: FrameResult,
    iou_threshold: float,
    confidence_tolerance: float,
) -> FrameComparison:
    result = FrameComparison(frame_id=expected.frame_id)
    if (expected.width, expected.height) != (actual.width, actual.height):
        result.dimension_mismatch = (
            f"expected {expected.width}x{expected.height}, "
            f"actual {actual.width}x{actual.height}"
        )

    unused_actual = set(range(len(actual.detections)))
    for golden in expected.detections:
        candidates: list[tuple[float, int]] = []
        for index in unused_actual:
            observed = actual.detections[index]
            if observed.class_id != golden.class_id:
                continue
            candidates.append((bbox_iou(golden.bbox_xyxy, observed.bbox_xyxy), index))

        if not candidates:
            result.missing.append(golden)
            continue

        best_iou, best_index = max(candidates, key=lambda item: item[0])
        if best_iou < iou_threshold:
            result.missing.append(golden)
            continue

        observed = actual.detections[best_index]
        unused_actual.remove(best_index)
        match = DetectionMatch(
            expected=golden,
            actual=observed,
            iou=best_iou,
            confidence_error=abs(golden.confidence - observed.confidence),
        )
        result.matches.append(match)
        if match.confidence_error > confidence_tolerance:
            result.confidence_mismatches.append(match)

    result.unexpected.extend(actual.detections[index] for index in sorted(unused_actual))
    return result


def compare_suite(
    expected_frames: Iterable[FrameResult],
    actual_frames: Iterable[FrameResult],
    iou_threshold: float = 0.5,
    confidence_tolerance: float = 0.1,
) -> SuiteComparison:
    if not 0.0 <= iou_threshold <= 1.0:
        raise ValueError("iou_threshold must be in [0, 1]")
    if confidence_tolerance < 0.0:
        raise ValueError("confidence_tolerance must be non-negative")

    expected = {frame.frame_id: frame for frame in expected_frames}
    actual = {frame.frame_id: frame for frame in actual_frames}
    shared_ids = sorted(expected.keys() & actual.keys())
    return SuiteComparison(
        frames=[
            compare_frame(
                expected[frame_id],
                actual[frame_id],
                iou_threshold,
                confidence_tolerance,
            )
            for frame_id in shared_ids
        ],
        missing_frames=sorted(expected.keys() - actual.keys()),
        unexpected_frames=sorted(actual.keys() - expected.keys()),
    )


def compare_integer_tensors(expected: np.ndarray, actual: np.ndarray) -> dict[str, object]:
    """Bit-exact comparison for quantized layer outputs."""
    if expected.shape != actual.shape:
        return {
            "passed": False,
            "reason": f"shape mismatch: expected {expected.shape}, actual {actual.shape}",
        }
    mismatch = np.argwhere(expected != actual)
    if mismatch.size == 0:
        return {"passed": True, "mismatch_count": 0, "max_abs_error": 0}
    first = tuple(int(index) for index in mismatch[0])
    delta = actual.astype(np.int64) - expected.astype(np.int64)
    return {
        "passed": False,
        "mismatch_count": int(mismatch.shape[0]),
        "first_index": first,
        "expected": int(expected[first]),
        "actual": int(actual[first]),
        "max_abs_error": int(np.max(np.abs(delta))),
    }

