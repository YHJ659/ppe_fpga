import numpy as np

from ppe_verify.fixed_point import (
    dequantize,
    integer_bounds,
    mac_golden,
    quantize,
    requantize_accumulator,
)


def test_signed_bounds() -> None:
    assert integer_bounds(8, signed=True) == (-128, 127)


def test_quantize_saturates() -> None:
    actual = quantize([-2.0, -1.0, 0.5, 1.0, 2.0], bits=8, fractional_bits=7)
    np.testing.assert_array_equal(actual, [-128, -128, 64, 127, 127])


def test_half_rounds_away_from_zero() -> None:
    actual = requantize_accumulator(
        np.array([63, 64, -63, -64]), shift=7, output_bits=8
    )
    np.testing.assert_array_equal(actual, [0, 1, 0, -1])


def test_dequantize() -> None:
    np.testing.assert_allclose(dequantize([-128, 0, 64, 127]), [-1.0, 0.0, 0.5, 127 / 128])


def test_mac_golden() -> None:
    accumulator, output = mac_golden([64, -64, 32, -32], [64, 64, -64, -64])
    assert accumulator == 0
    assert output == 0


def test_mac_saturation() -> None:
    accumulator, output = mac_golden([127] * 4, [127] * 4)
    assert accumulator == 4 * 127 * 127
    assert output == 127

