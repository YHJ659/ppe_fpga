#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bin_to_coe_multiset.py — conv3x3 4벌 가중치를 하나의 .coe로 합치기
====================================================================
call_counter % 4 순서(0=m0.cv1, 1=m0.cv2, 2=m1.cv1, 3=m1.cv2)대로
네 개 .bin 파일을 이어붙여서, weight_bank[N_SET][OUT_CH][IN_CH][K][K]
전체를 초기화할 .coe 하나를 만듭니다.

conv3x3의 weight는 conv1x1과 마찬가지로 실행 중 절대 안 바뀌는
고정값이라, PS가 런타임에 쓸 필요가 없습니다 — 비트스트림에
미리 박아넣습니다 (.coe + Block Memory Generator, Stand-Alone,
AXI Interconnect 불필요).

사용법
  python bin_to_coe_multiset.py \
      --bins calib_out/m0_cv1_weight.bin calib_out/m0_cv2_weight.bin \
             calib_out/m1_cv1_weight.bin calib_out/m1_cv2_weight.bin \
      --out conv3x3_weight_bank.coe
"""

import argparse

import numpy as np


def to_twos_complement_bin(v: int, bits: int = 8) -> str:
    if v < 0:
        v += 1 << bits
    return format(v, f"0{bits}b")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bins", nargs=4, required=True,
                    help="순서대로: m0.cv1 m0.cv2 m1.cv1 m1.cv2 (call_counter 0,1,2,3)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    labels = ["m0.cv1 (call_counter=0)", "m0.cv2 (call_counter=1)",
              "m1.cv1 (call_counter=2)", "m1.cv2 (call_counter=3)"]

    all_data = []
    for path, label in zip(args.bins, labels):
        # ★ 이전에 겪은 dtype 함정과 동일 — calibrate_model6.py는
        # weight를 int32로 저장함 (값은 int8 범위)
        d = np.fromfile(path, dtype=np.int32)
        vmin, vmax = int(d.min()), int(d.max())
        if vmin < -128 or vmax > 127:
            raise SystemExit(f"[!] {path} 값 범위 {vmin}~{vmax} 가 int8 벗어남")
        print(f"[i] {label}: {path} -> {d.size} elems, range {vmin}~{vmax}")
        all_data.append(d)

    sizes = {d.size for d in all_data}
    if len(sizes) != 1:
        raise SystemExit(f"[!] 4개 파일 크기가 서로 다름: {[d.size for d in all_data]}")
    per_set = sizes.pop()
    total = per_set * 4
    print(f"[i] 세트당 {per_set}개 x 4세트 = 총 {total}개")

    with open(args.out, "w") as f:
        f.write("; conv3x3 4-set weight_bank init file, auto-generated\n")
        f.write("; order: m0.cv1, m0.cv2, m1.cv1, m1.cv2 (call_counter 0,1,2,3)\n")
        f.write(f"; per-set elems = {per_set}, total = {total}\n")
        f.write("memory_initialization_radix=2;\n")
        f.write("memory_initialization_vector=\n")

        lines = []
        for d in all_data:
            lines.extend(to_twos_complement_bin(int(v)) for v in d)
        f.write(",\n".join(lines))
        f.write(";\n")

    print(f"[OK] {args.out} ({len(lines)} words, 8bit each)")
    print(f"[i] Block Memory Generator 설정: Stand-Alone, Width=8, Depth={total}, "
          "Load Init File 체크 -> 이 .coe 지정")


if __name__ == "__main__":
    main()