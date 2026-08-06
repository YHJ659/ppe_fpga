#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_scale_bins.py — calib_params.json 안의 스케일 스칼라들을
                         call_counter 순서에 맞는 .bin 파일로 추출
======================================================================
input_scale/weight_scale/output_scale (bn_silu), x_scale/fx_scale/
output_scale (residual_add), scale0~3+output_scale (concat, 1세트뿐)
전부 JSON 안에 숫자로만 있어서, bin_to_coe_float.py 가 읽을 float32
.bin 파일로 먼저 뽑아냅니다.

세트 순서는 항상 call_counter와 일치: m0.cv1=0, m0.cv2=1, m1.cv1=2, m1.cv2=3
(residual_add는 m0=0, m1=1 두 세트뿐)

사용법
  python extract_scale_bins.py --calib calib_out/calib_params.json --out calib_out/scale_bins
"""

import argparse
import json
import os

import numpy as np

# (도착 IP, 세트 순서, 이 세트에서 쓸 activation_scale 키들)
# calibrate_model6.py 의 activation_scale 키: S_in, S_cv1out, S_m0cv1, S_m0cv2,
# S_y2, S_m1cv1, S_m1cv2, S_y3, S_cat, S_out / weight_scale 키: cv1, m0_cv1, ...
BN64_SETS = [
    ("m0_cv1", "S_cv1out", "m0_cv1", "S_m0cv1"),
    ("m0_cv2", "S_m0cv1",  "m0_cv2", "S_m0cv2"),
    ("m1_cv1", "S_y2",     "m1_cv1", "S_m1cv1"),
    ("m1_cv2", "S_m1cv1",  "m1_cv2", "S_m1cv2"),
]
BN128_SETS = [
    ("cv1", "S_in",  "cv1", "S_cv1out"),
    ("cv2", "S_cat", "cv2", "S_out"),
]
RESIDUAL_SETS = [
    ("m0", "S_cv1out", "S_m0cv2", "S_y2"),
    ("m1", "S_y2",      "S_m1cv2", "S_y3"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--calib", default="calib_out/calib_params.json")
    ap.add_argument("--out", default="calib_out/scale_bins")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    with open(args.calib) as f:
        c = json.load(f)
    S, W = c["activation_scale"], c["weight_scale"]

    def save(name, vals):
        arr = np.array(vals, dtype=np.float32)
        path = os.path.join(args.out, f"{name}.bin")
        arr.tofile(path)
        print(f"[OK] {path}  {list(arr)}")

    # ---- bn_silu_64: input_scale/weight_scale/output_scale 각 4개 ----
    save("bn64_input_scale",  [S[i] for _, i, _, _ in BN64_SETS])
    save("bn64_weight_scale", [W[w] for _, _, w, _ in BN64_SETS])
    save("bn64_output_scale", [S[o] for _, _, _, o in BN64_SETS])

    # ---- bn_silu_128: 각 2개 ----
    save("bn128_input_scale",  [S[i] for _, i, _, _ in BN128_SETS])
    save("bn128_weight_scale", [W[w] for _, _, w, _ in BN128_SETS])
    save("bn128_output_scale", [S[o] for _, _, _, o in BN128_SETS])

    # ---- residual_add: x_scale/fx_scale/output_scale 각 2개 ----
    save("residual_x_scale",      [S[x]  for _, x, _, _ in RESIDUAL_SETS])
    save("residual_fx_scale",     [S[fx] for _, _, fx, _ in RESIDUAL_SETS])
    save("residual_output_scale", [S[o]  for _, _, _, o in RESIDUAL_SETS])

    # ---- concat: 1세트뿐 (재사용 없음), scale0~3 + output_scale ----
    save("concat_scale0", [S["S_cv1out"]])
    save("concat_scale1", [S["S_cv1out"]])
    save("concat_scale2", [S["S_y2"]])
    save("concat_scale3", [S["S_y3"]])
    save("concat_output_scale", [S["S_cat"]])

    print(f"\n[i] 전부 {args.out}/ 에 저장됨. "
          "bin_to_coe_float.py --bins <이 중 필요한 파일> --out xxx.coe 로 이어서 변환하세요.")


if __name__ == "__main__":
    main()