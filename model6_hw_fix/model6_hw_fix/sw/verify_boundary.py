#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_boundary.py — 하드웨어 출력이 맞는지 혼자 확인하는 스크립트
====================================================================
results/verification.md 의 수치를 그대로 재현한다. 보드 없이 돈다.

    python3 verify_boundary.py

무엇을 하는가
  best.pt 의 가중치와 calib_params.json 의 스케일로, 하드웨어와 **무관하게**
  기대값을 정수 연산으로 계산한 뒤 실제 보드 출력과 대조한다.
  y0/y1(채널 0~127)은 conv1x1 -> bn128 -> split -> concat 만 지나는
  픽셀별 순수 함수라 오차 없이 재현할 수 있다.

경계 배열 규약 — 여기서 대부분 어긋난다
  DMA 와 HLS 사이는 **픽셀 우선(HWC)** 이다.
      입력  int8 [40][40][128]  204,800 B
      출력  int8 [40][40][256]  409,600 B
  AXI-Stream 한 beat 이 한 픽셀의 전 채널이고 DMA 가 그 순서로 쓴다.
  conv1x1_cv1/tb_conv1x1_stream.cpp 가 이 규약을 못박고 있다.

      for (h) for (w) { for (c) px.ch[c] = in[c][h][w]; in_s.write(px); }

  인수인계 문서의 "CHW" 는 오류다. CHW 로 읽으면 값은 다 맞는데 자리가
  뒤섞여 일치율이 3% 대로 떨어진다. 아래 --wrong-layout 으로 재현해 볼 수 있다.
"""

import argparse
import json

import numpy as np
import torch

H = W = 40
IN_CH, OUT_CH = 128, 256


def bn_fold(bn):
    """BatchNorm 을 scale/shift 로 접는다."""
    g = (bn.weight / torch.sqrt(bn.running_var + bn.eps)).detach().numpy()
    b = (bn.bias - bn.running_mean * torch.from_numpy(g)).detach().numpy()
    return g, b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="models/best.pt")
    ap.add_argument("--calib", default="calib_out/calib_params.json")
    ap.add_argument("--input", default="data/hw_input_hwc.bin")
    ap.add_argument("--output", default="data/hw_output_full.bin")
    ap.add_argument("--wrong-layout", action="store_true",
                    help="일부러 CHW 로 읽어 3%% 가 나오는 것을 보여준다")
    args = ap.parse_args()

    # torch 2.6 부터 torch.load 의 weights_only 기본값이 True 로 바뀌었다.
    # ultralytics 8.0.x 는 그걸 모르고 불러서 UnpicklingError 가 난다.
    # 여기서 읽는 것은 본인 소유의 체크포인트이므로 예전 동작으로 되돌린다.
    _orig_load = torch.load

    def _load(*a, **k):
        k.setdefault("weights_only", False)
        return _orig_load(*a, **k)

    torch.load = _load

    from ultralytics import YOLO
    cal = json.load(open(args.calib))
    S_in = cal["boundary"]["hw_in_scale"]
    S_c1 = cal["activation_scale"]["S_cv1out"]
    S_cat = cal["activation_scale"]["S_cat"]
    W_cv1 = cal["weight_scale"]["cv1"]

    m6 = YOLO(args.weights).model.model[6]
    w = torch.clamp(torch.round(m6.cv1.conv.weight.detach() / W_cv1),
                    -128, 127).numpy().reshape(IN_CH, IN_CH).astype(np.int32)
    g, b = bn_fold(m6.cv1.bn)

    x = np.fromfile(args.input, np.int8)
    hw = np.fromfile(args.output, np.int8)
    assert x.size == IN_CH * H * W, x.size
    assert hw.size == OUT_CH * H * W, hw.size

    if args.wrong_layout:
        # 문서의 CHW 를 그대로 믿었을 때
        hw = hw.reshape(OUT_CH, H, W).transpose(1, 2, 0).reshape(-1, OUT_CH)
        tag = "CHW 로 읽음 (문서대로, 틀린 방식)"
    else:
        hw = hw.reshape(H, W, OUT_CH).reshape(-1, OUT_CH)
        tag = "HWC 로 읽음 (테스트벤치 규약, 맞는 방식)"
    hw = hw.astype(np.int32)

    # 하드웨어와 무관하게 계산한 기대값
    xi = x.reshape(H * W, IN_CH).astype(np.int32)
    acc = xi @ w.T                                   # 정수, 오차 없음
    v = acc * (S_in * W_cv1) * g + b                 # bn128
    silu = v / (1.0 + np.exp(-v))
    y = np.clip(np.round(silu / S_c1), -128, 127)    # int8 로 양자화
    exp = np.clip(np.round(y * S_c1 / S_cat), -128, 127)   # concat 재양자화

    got = hw[:, :IN_CH]
    same = int((exp == got).sum())
    per = np.array([(exp[:, c] == got[:, c]).all() for c in range(IN_CH)])

    print(f"\n  {tag}\n")
    print(f"  y0/y1 (채널 0~127, 1600픽셀)")
    print(f"    일치            {same / exp.size * 100:7.2f}%")
    print(f"    불일치 바이트    {exp.size - same:7d} / {exp.size}")
    print(f"    완전일치 채널    {int(per.sum()):7d} / {IN_CH}")
    r = np.corrcoef(exp.ravel(), got.ravel())[0, 1]
    print(f"    상관계수        {r:7.3f}")
    ok = same == exp.size
    print(f"\n  {'>>> 통과 — 기대값과 완전히 같다' if ok else '>>> 불일치 있음'}")
    if not ok and not args.wrong_layout:
        print("      --wrong-layout 을 붙여 돌려보면 배열 규약 문제인지 갈린다.")


if __name__ == "__main__":
    main()
