from ppe_verify.control_model import AcceleratorControlModel


def test_start_busy_done_sequence() -> None:
    model = AcceleratorControlModel()
    assert model.clock(start=True, requested_cycles=3).busy
    assert model.clock().remaining_cycles == 2
    assert model.clock().remaining_cycles == 1
    final = model.clock()
    assert final.done
    assert not final.busy
    assert final.completed_jobs == 1


def test_start_while_busy_is_ignored() -> None:
    model = AcceleratorControlModel()
    model.clock(start=True, requested_cycles=2)
    state = model.clock(start=True, requested_cycles=99)
    assert state.remaining_cycles == 1
    assert model.clock().completed_jobs == 1


def test_zero_cycle_job_uses_one_cycle() -> None:
    model = AcceleratorControlModel()
    assert model.clock(start=True, requested_cycles=0).remaining_cycles == 1
    assert model.clock().done


def test_reset_clears_state() -> None:
    model = AcceleratorControlModel()
    model.clock(start=True, requested_cycles=3)
    assert model.reset().completed_jobs == 0
    assert not model.outputs().busy

