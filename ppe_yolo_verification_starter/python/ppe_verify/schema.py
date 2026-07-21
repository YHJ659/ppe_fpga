from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Iterable


@dataclass(frozen=True)
class Detection:
    class_id: int
    class_name: str
    confidence: float
    bbox_xyxy: tuple[float, float, float, float]

    def __post_init__(self) -> None:
        x1, y1, x2, y2 = self.bbox_xyxy
        if x2 < x1 or y2 < y1:
            raise ValueError(f"invalid xyxy box: {self.bbox_xyxy}")
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError(f"confidence must be in [0, 1]: {self.confidence}")

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "Detection":
        box = value["bbox_xyxy"]
        if len(box) != 4:
            raise ValueError(f"bbox_xyxy must contain four numbers: {box}")
        return cls(
            class_id=int(value["class_id"]),
            class_name=str(value["class_name"]),
            confidence=float(value["confidence"]),
            bbox_xyxy=tuple(float(v) for v in box),
        )

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["bbox_xyxy"] = list(self.bbox_xyxy)
        return value


@dataclass(frozen=True)
class FrameResult:
    frame_id: str
    width: int
    height: int
    detections: tuple[Detection, ...]

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "FrameResult":
        return cls(
            frame_id=str(value["frame_id"]),
            width=int(value["width"]),
            height=int(value["height"]),
            detections=tuple(
                Detection.from_dict(detection)
                for detection in value.get("detections", [])
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "frame_id": self.frame_id,
            "width": self.width,
            "height": self.height,
            "detections": [detection.to_dict() for detection in self.detections],
        }


def frames_to_document(frames: Iterable[FrameResult]) -> dict[str, Any]:
    return {"schema_version": 1, "frames": [frame.to_dict() for frame in frames]}


def frames_from_document(document: dict[str, Any]) -> list[FrameResult]:
    if int(document.get("schema_version", 1)) != 1:
        raise ValueError(f"unsupported schema_version: {document.get('schema_version')}")
    frames = [FrameResult.from_dict(frame) for frame in document.get("frames", [])]
    ids = [frame.frame_id for frame in frames]
    if len(ids) != len(set(ids)):
        raise ValueError("frame_id values must be unique")
    return frames

