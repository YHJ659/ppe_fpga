from __future__ import annotations

from dataclasses import replace

from .schema import Detection, FrameResult


def _d(
    class_id: int,
    class_name: str,
    confidence: float,
    box: tuple[float, float, float, float],
) -> Detection:
    return Detection(class_id, class_name, confidence, box)


def golden_frames() -> list[FrameResult]:
    return [
        FrameResult("empty_site.jpg", 960, 540, ()),
        FrameResult(
            "worker_safe.jpg",
            960,
            540,
            (
                _d(0, "helmet", 0.94, (410, 52, 505, 155)),
                _d(2, "safety_vest", 0.91, (365, 145, 565, 450)),
            ),
        ),
        FrameResult(
            "worker_unsafe.jpg",
            960,
            540,
            (
                _d(1, "no_helmet", 0.88, (180, 60, 265, 165)),
                _d(3, "no_safety_vest", 0.84, (145, 155, 310, 445)),
            ),
        ),
        FrameResult(
            "two_workers.jpg",
            960,
            540,
            (
                _d(0, "helmet", 0.92, (240, 48, 325, 145)),
                _d(2, "safety_vest", 0.89, (205, 135, 360, 430)),
                _d(1, "no_helmet", 0.81, (635, 70, 715, 165)),
                _d(3, "no_safety_vest", 0.78, (600, 155, 760, 445)),
            ),
        ),
    ]


def mock_dut_frames(inject_fault: bool = False) -> list[FrameResult]:
    """Return slightly quantized-looking outputs, optionally with a real fault."""
    frames: list[FrameResult] = []
    for frame in golden_frames():
        detections = tuple(
            replace(
                detection,
                confidence=max(0.0, detection.confidence - 0.02),
                bbox_xyxy=tuple(value + 1.0 for value in detection.bbox_xyxy),
            )
            for detection in frame.detections
        )
        frames.append(replace(frame, detections=detections))

    if inject_fault:
        target = frames[-1]
        # 마지막 작업자의 no_safety_vest 검출을 잃어버린 DUT를 흉내 낸다.
        frames[-1] = replace(target, detections=target.detections[:-1])
    return frames

