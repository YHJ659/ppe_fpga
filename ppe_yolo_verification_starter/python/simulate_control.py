from __future__ import annotations

import argparse

from ppe_verify.control_model import AcceleratorControlModel


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Show a START/BUSY/DONE accelerator trace")
    parser.add_argument("--work-cycles", type=int, default=5)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    model = AcceleratorControlModel()
    print("cycle | start | busy | done | remaining | jobs")
    print("------+-------+------+------+-----------+-----")
    state = model.reset()
    print(f"{0:5d} | {0:5d} | {int(state.busy):4d} | {int(state.done):4d} | {state.remaining_cycles:9d} | {state.completed_jobs:4d}")

    timeout = args.work_cycles + 5
    for cycle in range(1, timeout + 1):
        start = cycle == 1
        state = model.clock(start=start, requested_cycles=args.work_cycles)
        print(
            f"{cycle:5d} | {int(start):5d} | {int(state.busy):4d} | {int(state.done):4d} | "
            f"{state.remaining_cycles:9d} | {state.completed_jobs:4d}"
        )
        if state.done:
            print("PASS: START request reached DONE without timeout")
            return 0
    print("FAIL: timeout waiting for DONE")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

