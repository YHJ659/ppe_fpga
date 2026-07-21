from __future__ import annotations

from .metrics import SuiteComparison


def _describe_detection(prefix: str, detection: object) -> str:
    return (
        f"{prefix} class={detection.class_name}({detection.class_id}) "
        f"conf={detection.confidence:.3f} box={tuple(round(v, 1) for v in detection.bbox_xyxy)}"
    )


def render_report(comparison: SuiteComparison) -> str:
    lines = ["=== PPE VERIFICATION REPORT ==="]
    for frame_id in comparison.missing_frames:
        lines.append(f"[FAIL] missing frame: {frame_id}")
    for frame_id in comparison.unexpected_frames:
        lines.append(f"[FAIL] unexpected frame: {frame_id}")

    total_matches = 0
    for frame in comparison.frames:
        total_matches += len(frame.matches)
        status = "PASS" if frame.passed else "FAIL"
        lines.append(
            f"[{status}] {frame.frame_id}: matched={len(frame.matches)} "
            f"missing={len(frame.missing)} unexpected={len(frame.unexpected)}"
        )
        if frame.dimension_mismatch:
            lines.append(f"  dimension mismatch: {frame.dimension_mismatch}")
        for detection in frame.missing:
            lines.append("  " + _describe_detection("missing", detection))
        for detection in frame.unexpected:
            lines.append("  " + _describe_detection("unexpected", detection))
        for match in frame.confidence_mismatches:
            lines.append(
                "  confidence mismatch "
                f"class={match.expected.class_name} expected={match.expected.confidence:.3f} "
                f"actual={match.actual.confidence:.3f} error={match.confidence_error:.3f}"
            )

    final = "PASS" if comparison.passed else "FAIL"
    lines.append(f"RESULT: {final} ({len(comparison.frames)} frames, {total_matches} matches)")
    return "\n".join(lines)

