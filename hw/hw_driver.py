"""ctypes client for the /dev/model6_dma kernel DMA-proxy."""
from __future__ import annotations

import ctypes
import os
import subprocess
from pathlib import Path

import numpy as np


INPUT_SHAPE = (128, 40, 40)
OUTPUT_SHAPE = (256, 40, 40)
_HERE = Path(__file__).resolve().parent
_LIBRARY = _HERE / "libmodel6_hw_driver.so"


def _load_library() -> ctypes.CDLL:
    source = _HERE / "hw_driver.c"
    if not _LIBRARY.exists() or _LIBRARY.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["make", "-C", str(_HERE)], check=True)
    lib = ctypes.CDLL(str(_LIBRARY), use_errno=True)
    lib.model6_create.argtypes = ()
    lib.model6_create.restype = ctypes.c_void_p
    lib.model6_destroy.argtypes = (ctypes.c_void_p,)
    lib.model6_destroy.restype = None
    lib.model6_run.argtypes = (
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int8),
        ctypes.POINTER(ctypes.c_int8),
        ctypes.c_uint,
    )
    lib.model6_run.restype = ctypes.c_int
    return lib


class Model6Fpga:
    """FPGA model.6 runner backed by the model6_dma kernel module."""

    def __init__(self, _unused_xsa_path: str | Path | None = None):
        self.lib = _load_library()
        self.handle = self.lib.model6_create()
        if not self.handle:
            err = ctypes.get_errno()
            raise RuntimeError(
                "cannot open /dev/model6_dma; load the model6_dma kernel module: "
                f"{os.strerror(err)}"
            )
        self._output = np.empty(OUTPUT_SHAPE, dtype=np.int8)

    def run(self, input_int8: np.ndarray) -> np.ndarray:
        src = np.ascontiguousarray(input_int8, dtype=np.int8)
        if src.shape != INPUT_SHAPE:
            raise ValueError(f"model.6 input must be {INPUT_SHAPE}, got {src.shape}")
        rc = self.lib.model6_run(
            self.handle,
            src.ctypes.data_as(ctypes.POINTER(ctypes.c_int8)),
            self._output.ctypes.data_as(ctypes.POINTER(ctypes.c_int8)),
            2000,
        )
        if rc:
            raise RuntimeError(f"model.6 DMA transfer failed: errno {-rc}")
        return self._output

    def close(self) -> None:
        if getattr(self, "handle", None):
            self.lib.model6_destroy(self.handle)
            self.handle = None
