#!/usr/bin/env python3
"""Benchmark real hybrid inference latency on the target machine.

This deliberately reports inference throughput separately from camera/display
throughput. Optional ORT/ncnn backends are reported as unavailable until their
native runtime is installed on the KV260.
"""
from __future__ import annotations

import argparse
import statistics
import time
from pathlib import Path

import cv2

from sw.final_hybrid_pipeline import FinalHybridPipeline
from sw.ort_hybrid_pipeline import OrtHybridPipeline


ROOT = Path(__file__).resolve().parents[1]


def summarize(samples):
    values = sorted(samples)
    return {"median": statistics.median(values),
            "mean": statistics.mean(values),
            "p95": values[min(len(values) - 1, int(len(values) * 0.95))]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--warmup", type=int, default=10)
    parser.add_argument("--frames", type=int, default=30)
    parser.add_argument("--threads", type=int, default=0)
    parser.add_argument("--channels-last", action="store_true")
    parser.add_argument("--backend", choices=("pytorch", "ort", "ort-int8"),
                        default="ort")
    args = parser.parse_args()

    image = cv2.imread(args.image)
    if image is None:
        raise SystemExit(f"cannot read {args.image}")
    if args.backend == "pytorch":
        pipe = FinalHybridPipeline(ROOT / "models/best.pt",
                                    ROOT / "calib_out/calib_params.json",
                                    backend="pytorch", threads=args.threads or 1,
                                    channels_last=args.channels_last)
    else:
        pipe = OrtHybridPipeline(ROOT / "models/best.pt",
                                 ROOT / "calib_out/calib_params.json",
                                 graph_dir=ROOT / "models/onnx",
                                 threads=args.threads or 1,
                                 graph_suffix="_int8" if args.backend == "ort-int8" else "")
    try:
        for _ in range(args.warmup):
            pipe.infer(image)
        samples = []
        part_keys = (("pre", "sw0_5", "fpga6", "sw7_22", "post")
                     if args.backend == "pytorch" else
                     ("pre", "ort_a", "fpga6", "ort_b", "post"))
        parts = {key: [] for key in part_keys}
        for _ in range(args.frames):
            _, timing = pipe.infer(image)
            samples.append(timing["total"])
            for key in parts:
                parts[key].append(timing.get(key, 0.0))
        print(f"Backend: {args.backend}")
        keys = (*part_keys, "total")
        for key in keys:
            stats = summarize(samples if key == "total" else parts[key])
            print(f"{key:8s}: median={stats['median']*1000:.2f} ms "
                  f"mean={stats['mean']*1000:.2f} ms p95={stats['p95']*1000:.2f} ms")
        print(f"REAL inference FPS (median): {1/statistics.median(samples):.3f}")
    finally:
        pipe.close()


if __name__ == "__main__":
    main()
