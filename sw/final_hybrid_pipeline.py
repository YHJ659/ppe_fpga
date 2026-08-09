"""Production backend selector with a safe PyTorch fallback."""
from __future__ import annotations

from pathlib import Path

from sw.hybrid_pipeline import HybridPipeline


class FinalHybridPipeline:
    def __init__(self, weights, calib, conf=0.5, iou=0.45, backend="auto",
                 threads=1, channels_last=False):
        self.backend_name = "pytorch"
        if backend in ("auto", "ort"):
            try:
                from sw.ort_hybrid_pipeline import OrtHybridPipeline
                graph_dir = Path(calib).resolve().parents[1] / "models" / "onnx"
                self.impl = OrtHybridPipeline(
                    weights, calib, graph_dir=graph_dir, conf=conf, iou=iou,
                    threads=threads)
                self.backend_name = "ort-fp32"
                print("MODEL6 backend: ORT FP32")
                return
            except Exception as error:
                if backend == "ort":
                    raise
                print(f"MODEL6 backend: ORT unavailable ({error}); using PyTorch")
        self.impl = HybridPipeline(weights, calib, conf=conf, iou=iou,
                                   threads=threads or None,
                                   channels_last=channels_last)
        print("MODEL6 backend: PyTorch fallback")

    @property
    def names(self):
        return self.impl.names

    @property
    def inference_backend(self):
        return self.backend_name

    def infer(self, frame):
        return self.impl.infer(frame)

    def close(self):
        self.impl.close()
