from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from ppe_verify.fixed_point import mac_golden


EDGE_CASES = [
    ([0, 0, 0, 0], [0, 0, 0, 0], 0),
    ([1, 0, 0, 0], [1, 0, 0, 0], 0),
    ([127, 127, 127, 127], [127, 127, 127, 127], 0),
    ([-128, -128, -128, -128], [127, 127, 127, 127], 0),
    ([64, -64, 32, -32], [64, 64, -64, -64], 0),
    ([10, 20, 30, 40], [-4, 3, -2, 1], 64),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate bit-accurate MAC vectors")
    parser.add_argument("--output", type=Path, default=Path("vectors/mac_vectors.txt"))
    parser.add_argument("--random-count", type=int, default=20)
    parser.add_argument("--seed", type=int, default=20260721)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rng = np.random.default_rng(args.seed)
    cases = list(EDGE_CASES)
    for _ in range(args.random_count):
        inputs = rng.integers(-128, 128, size=4).tolist()
        weights = rng.integers(-128, 128, size=4).tolist()
        bias = int(rng.integers(-1024, 1025))
        cases.append((inputs, weights, bias))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii") as handle:
        for inputs, weights, bias in cases:
            _, expected = mac_golden(inputs, weights, bias_accumulator=bias)
            values = [*inputs, *weights, bias, expected]
            handle.write(" ".join(str(value) for value in values) + "\n")

    print(f"wrote {len(cases)} vectors to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
