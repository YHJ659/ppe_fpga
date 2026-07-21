from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ControlOutputs:
    busy: bool
    done: bool
    remaining_cycles: int
    completed_jobs: int


class AcceleratorControlModel:
    """Cycle-accurate reference for the learning-only ppe_control_mock RTL."""

    def __init__(self) -> None:
        self.busy = False
        self.done = False
        self.remaining_cycles = 0
        self.completed_jobs = 0

    def reset(self) -> ControlOutputs:
        self.busy = False
        self.done = False
        self.remaining_cycles = 0
        self.completed_jobs = 0
        return self.outputs()

    def clock(self, *, start: bool = False, requested_cycles: int = 0) -> ControlOutputs:
        if requested_cycles < 0 or requested_cycles > 0xFFFF:
            raise ValueError("requested_cycles must fit in an unsigned 16-bit register")

        self.done = False
        if start and not self.busy:
            self.busy = True
            self.remaining_cycles = max(1, requested_cycles)
        elif self.busy:
            if self.remaining_cycles <= 1:
                self.busy = False
                self.done = True
                self.remaining_cycles = 0
                self.completed_jobs += 1
            else:
                self.remaining_cycles -= 1
        return self.outputs()

    def outputs(self) -> ControlOutputs:
        return ControlOutputs(
            busy=self.busy,
            done=self.done,
            remaining_cycles=self.remaining_cycles,
            completed_jobs=self.completed_jobs,
        )

