#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
coe_stride4.py — 파라미터 BRAM 의 주소 규약을 맞춘 .coe 를 만든다
==================================================================
HLS 가 BRAM 포트로 내보내는 주소는 **바이트 주소**다. Block Memory
Generator 는 그걸 **워드 주소**로 읽는다. 원소가 4바이트(float)면
채널 c 를 읽으려 할 때 실제로는 4c 번 칸이 읽힌다.

보드에서 실측으로 확정한 사실 (영입력 + 실제 이미지, 128/128 채널 일치):

    읽히는 칸 = (4 * c) mod 256          # 주소선이 8비트라 되감김

원소가 1바이트(int8 가중치)면 바이트 주소 = 원소 번호라 문제가 없다.
실제로 conv1x1 의 곱셈·누적은 처음부터 정확했다.

고치는 방법은 두 줄이다.
  1) 32비트 메모리의 깊이를 4배로 잡는다  -> 주소선이 2비트 넓어져 안 되감김
  2) 값을 0, 4, 8, ... 번 칸에 놓는다     -> 주소 4c 가 원소 c 에 정확히 떨어짐
사이의 빈 칸은 0 으로 채운다. 읽히지 않는다.

덤으로 bn128 의 슬롯1 을 슬롯0(cv1) 값으로 덮는다. 설계에서 cv2 가
삭제되어 이 IP 는 프레임당 한 번만 불리는데, call_counter 는 static 이라
2프레임째에 슬롯1 을 읽는다. 단일 프레임 시험으로는 절대 안 잡히는 종류다.
"""

import argparse
import os
import re
import shutil

ENTRY = re.compile(r"^([01]+)\s*[,;]", re.M)

# (파일, 원소당 비트, 슬롯 수) — 32비트인 것만 stride 4 로 편다
WIDTH32 = {
    "bn128_bn_scale.coe", "bn128_bn_shift.coe",
    "bn128_input_scale.coe", "bn128_weight_scale.coe", "bn128_output_scale.coe",
    "bn64_bn_scale.coe", "bn64_bn_shift.coe",
    "bn64_input_scale.coe", "bn64_weight_scale.coe", "bn64_output_scale.coe",
    "residual_x_scale.coe", "residual_fx_scale.coe", "residual_output_scale.coe",
}
# cv2 가 삭제되어 슬롯1 이 쓰이면 안 되는 것 (슬롯0 을 복사한다)
MIRROR_SLOT1 = {"bn128_bn_scale.coe", "bn128_bn_shift.coe"}


def read_entries(path):
    return ENTRY.findall(open(path).read())


def write_coe(path, entries, note):
    with open(path, "w") as f:
        f.write(f"; {note}\n")
        f.write("memory_initialization_radix=2;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(entries) + ";\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="coe_fixed")
    ap.add_argument("--dst", default="coe_addr4")
    args = ap.parse_args()
    os.makedirs(args.dst, exist_ok=True)

    print(f"{'파일':34s}{'원소':>8s}{'폭':>5s}{'새 깊이':>9s}  비고")
    for name in sorted(os.listdir(args.src)):
        if not name.endswith(".coe"):
            continue
        src, dst = os.path.join(args.src, name), os.path.join(args.dst, name)
        ent = read_entries(src)
        if name not in WIDTH32:
            shutil.copyfile(src, dst)
            print(f"{name:34s}{len(ent):8d}{len(ent[0]):5d}{len(ent):9d}  "
                  f"1바이트라 그대로")
            continue

        note = ""
        if name in MIRROR_SLOT1:
            h = len(ent) // 2
            ent = ent[:h] + ent[:h]
            note = "슬롯1 을 슬롯0 으로 덮음, "

        zero = "0" * 32
        out = []
        for e in ent:
            out.append(e)
            out.extend([zero] * 3)
        write_coe(dst, out, f"stride-4 addressing, from {name}")
        print(f"{name:34s}{len(ent):8d}{len(ent[0]):5d}{len(out):9d}  "
              f"{note}값을 0,4,8… 칸에 배치")

    print(f"\n[OK] {args.dst}/ 에 생성. build 스크립트에서 32비트 BRAM 깊이를 "
          f"4배로 올려야 짝이 맞는다.")


if __name__ == "__main__":
    main()
