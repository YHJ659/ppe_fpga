import numpy as np

from ppe_verify.metrics import bbox_iou, compare_integer_tensors, compare_suite
from ppe_verify.mock_data import golden_frames, mock_dut_frames


def test_iou_identity() -> None:
    assert bbox_iou((1, 2, 10, 20), (1, 2, 10, 20)) == 1.0


def test_iou_disjoint() -> None:
    assert bbox_iou((0, 0, 1, 1), (2, 2, 3, 3)) == 0.0


def test_mock_passes_with_detection_tolerance() -> None:
    result = compare_suite(golden_frames(), mock_dut_frames(), 0.5, 0.1)
    assert result.passed


def test_mock_fault_is_caught() -> None:
    result = compare_suite(golden_frames(), mock_dut_frames(inject_fault=True), 0.5, 0.1)
    assert not result.passed
    assert sum(len(frame.missing) for frame in result.frames) == 1


def test_integer_tensor_comparison_reports_first_mismatch() -> None:
    expected = np.array([[1, 2], [3, 4]], dtype=np.int8)
    actual = np.array([[1, 9], [3, 4]], dtype=np.int8)
    report = compare_integer_tensors(expected, actual)
    assert report["passed"] is False
    assert report["first_index"] == (0, 1)
    assert report["expected"] == 2
    assert report["actual"] == 9

