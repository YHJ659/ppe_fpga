"""model.6 FPGA boundary injection while preserving native YOLOv8 forward."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import torch

from sw.sw_model0to5 import validate_model0to5_boundary


class Model6Hybrid:
    """Replace only model.6.cv2's input with FPGA concat output.

    The outer model.6 pre-hook receives the native model.5 result, quantizes it
    for FPGA, and executes the accelerator.  The cv2 pre-hook then replaces its
    input.  cv2's checkpoint Conv+BN+SiLU and all model.7--22 graph/skip logic
    remain Ultralytics code.
    """

    def __init__(self, model: torch.nn.Module, fpga, calib_path: str | Path):
        validate_model0to5_boundary(model)
        with open(calib_path, encoding="utf-8") as f:
            calib = json.load(f)
        self.hw_in_scale = float(calib["boundary"]["hw_in_scale"])
        self.s_cat = float(calib["activation_scale"]["S_cat"])
        if self.hw_in_scale <= 0 or self.s_cat <= 0:
            raise ValueError("calibration scales must be positive")
        self.model6 = model.model[6]
        self.fpga = fpga
        self._replacement: torch.Tensor | None = None
        self._model6_handle = self.model6.register_forward_pre_hook(self._run_fpga)
        self._cv2_handle = self.model6.cv2.register_forward_pre_hook(self._replace_cv2_input)

    def _run_fpga(self, _module, args):
        x = args[0]
        if x.ndim != 4 or tuple(x.shape[1:]) != (128, 40, 40):
            raise RuntimeError(
                "FPGA model.6 is fixed at [batch=1, 128, 40, 40]; "
                f"received {tuple(x.shape)}. Use imgsz=640 and batch=1."
            )
        if x.shape[0] != 1:
            raise RuntimeError("FPGA model.6 supports batch=1 only")
        q = torch.clamp(torch.round(x.detach().float() / self.hw_in_scale), -128, 127)
        q_np = q.squeeze(0).to(torch.int8).cpu().numpy()
        cat_q = self.fpga.run(q_np)
        replacement = torch.from_numpy(np.ascontiguousarray(cat_q).astype(np.float32))
        self._replacement = (replacement * self.s_cat).unsqueeze(0).to(x.device, dtype=x.dtype)

    def _replace_cv2_input(self, _module, _args):
        if self._replacement is None:
            raise RuntimeError("model.6.cv2 called without an FPGA result")
        return (self._replacement,)

    def close(self) -> None:
        self._model6_handle.remove()
        self._cv2_handle.remove()
        self._replacement = None
