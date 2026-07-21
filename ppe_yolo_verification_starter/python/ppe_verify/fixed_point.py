from __future__ import annotations

import numpy as np


def integer_bounds(bits: int, signed: bool = True) -> tuple[int, int]:
    if bits <= 0:
        raise ValueError("bits must be positive")
    if signed:
        return -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return 0, (1 << bits) - 1


def _wrap(values: np.ndarray, bits: int, signed: bool) -> np.ndarray:
    modulus = 1 << bits
    wrapped = np.mod(values, modulus)
    if signed:
        sign = 1 << (bits - 1)
        wrapped = np.where(wrapped >= sign, wrapped - modulus, wrapped)
    return wrapped


def quantize(
    values: np.ndarray | list[float],
    *,
    bits: int = 8,
    fractional_bits: int = 7,
    signed: bool = True,
    rounding: str = "nearest_away_from_zero",
    overflow: str = "saturate",
) -> np.ndarray:
    array = np.asarray(values, dtype=np.float64)
    scaled = array * (1 << fractional_bits)
    if rounding == "nearest_away_from_zero":
        rounded = np.sign(scaled) * np.floor(np.abs(scaled) + 0.5)
    elif rounding == "toward_zero":
        rounded = np.trunc(scaled)
    elif rounding == "floor":
        rounded = np.floor(scaled)
    else:
        raise ValueError(f"unsupported rounding rule: {rounding}")

    integer = rounded.astype(np.int64)
    if overflow == "saturate":
        minimum, maximum = integer_bounds(bits, signed)
        integer = np.clip(integer, minimum, maximum)
    elif overflow == "wrap":
        integer = _wrap(integer, bits, signed)
    else:
        raise ValueError(f"unsupported overflow rule: {overflow}")
    return integer


def dequantize(values: np.ndarray | list[int], fractional_bits: int = 7) -> np.ndarray:
    return np.asarray(values, dtype=np.float64) / (1 << fractional_bits)


def requantize_accumulator(
    accumulator: int | np.ndarray,
    *,
    shift: int,
    output_bits: int = 8,
    rounding: str = "nearest_away_from_zero",
    overflow: str = "saturate",
) -> np.ndarray:
    if shift < 0:
        raise ValueError("shift must be non-negative")
    values = np.asarray(accumulator, dtype=np.int64)
    absolute = np.abs(values)
    if shift == 0:
        shifted = values
    elif rounding == "nearest_away_from_zero":
        magnitude = (absolute + (1 << (shift - 1))) >> shift
        shifted = np.where(values < 0, -magnitude, magnitude)
    elif rounding == "toward_zero":
        magnitude = absolute >> shift
        shifted = np.where(values < 0, -magnitude, magnitude)
    elif rounding == "arithmetic_shift":
        shifted = values >> shift
    else:
        raise ValueError(f"unsupported rounding rule: {rounding}")

    if overflow == "saturate":
        minimum, maximum = integer_bounds(output_bits, signed=True)
        shifted = np.clip(shifted, minimum, maximum)
    elif overflow == "wrap":
        shifted = _wrap(shifted, output_bits, signed=True)
    else:
        raise ValueError(f"unsupported overflow rule: {overflow}")
    return shifted.astype(np.int64)


def mac_golden(
    inputs: np.ndarray | list[int],
    weights: np.ndarray | list[int],
    *,
    bias_accumulator: int = 0,
    fractional_bits: int = 7,
    output_bits: int = 8,
) -> tuple[int, int]:
    x = np.asarray(inputs, dtype=np.int64)
    w = np.asarray(weights, dtype=np.int64)
    if x.shape != w.shape:
        raise ValueError(f"shape mismatch: inputs {x.shape}, weights {w.shape}")
    accumulator = int(np.sum(x * w, dtype=np.int64)) + int(bias_accumulator)
    output = int(
        requantize_accumulator(
            accumulator,
            shift=fractional_bits,
            output_bits=output_bits,
            rounding="nearest_away_from_zero",
            overflow="saturate",
        )
    )
    return accumulator, output

