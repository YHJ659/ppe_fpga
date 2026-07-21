from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable

from .schema import FrameResult, frames_from_document, frames_to_document


def load_results(path: str | Path) -> list[FrameResult]:
    source = Path(path)
    with source.open("r", encoding="utf-8") as handle:
        return frames_from_document(json.load(handle))


def save_results(path: str | Path, frames: Iterable[FrameResult]) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8") as handle:
        json.dump(frames_to_document(frames), handle, indent=2, ensure_ascii=False)
        handle.write("\n")

