#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sw_model7up.py  —  3단계: model.7~ 소프트웨어 구현
====================================================
HW model.6의 출력(int8)을 받아 역양자화하고, model.7부터 이어서 실행합니다.

핵심 아이디어: skip connection을 손으로 재구현하지 않습니다.
YOLOv8의 DetectionModel.forward는 이미 어느 레이어가 어느 인덱스를
참조하는지 스스로 관리합니다(self.save). model.6에 forward hook을 걸어
"원래 계산값을 우리가 만든 값으로 바꿔치기"만 하면, 그 뒤(model.7~22)는
원본 forward가 그대로 알아서 돌아갑니다 — model.6이 실제로 float으로
계산됐는지 HW int8 왕복을 거쳤는지는 model.7 입장에서 구분되지 않습니다.

3가지 모드
  float_ref   : 후크 없음. 순수 SW 전체 (5단계 기준값 A)
  hw_emulate  : model.6을 float로 계산 후 int8 양자화->역양자화만 흉내
                (실제 HW 없이 "HW가 있었다면"을 미리 확인)
  hw_readback : 실제 HW에서 DMA로 읽어온 int8 배열(.bin)을 그대로 주입
                (진짜 HW 붙인 뒤 4단계 PS 코드에서 이 경로를 씀)

사용법
  # 순수 SW 기준값
  python sw_model7up.py --weights models/best.pt --image X.jpg \
      --mode float_ref

  # HW 있었다면 어떤 오차가 생겼을지 미리 확인 (하드웨어 없이)
  python sw_model7up.py --weights models/best.pt --image X.jpg \
      --mode hw_emulate --calib calib_out/calib_params.json

  # 실제 HW 출력(.bin)을 넣어 최종 검출 결과 생성
  python sw_model7up.py --weights models/best.pt --image X.jpg \
      --mode hw_readback --hw-output-bin hw_output.bin \
      --calib calib_out/calib_params.json
"""

import argparse
import json

import numpy as np
import torch


def load_calib(path):
    with open(path) as f:
        return json.load(f)


def letterbox(img, new_shape=640, color=(114, 114, 114)):
    import cv2
    h, w = img.shape[:2]
    r = min(new_shape / h, new_shape / w)
    nh, nw = int(round(h * r)), int(round(w * r))
    img = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    top, left = (new_shape - nh) // 2, (new_shape - nw) // 2
    return cv2.copyMakeBorder(img, top, new_shape - nh - top,
                              left, new_shape - nw - left,
                              cv2.BORDER_CONSTANT, value=color)


def preprocess(image_path, imgsz=640):
    import cv2
    bgr = cv2.imread(image_path)
    if bgr is None:
        raise SystemExit(f"[!] 이미지를 못 읽었습니다: {image_path}")
    rgb = letterbox(bgr, imgsz)[:, :, ::-1].copy()
    x = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0
    return x.unsqueeze(0)


def quantize_dequantize(feat_float, s_out):
    """model.6 출력을 int8로 양자화 후 즉시 역양자화 — HW 왕복을 흉내"""
    q = torch.clamp(torch.round(feat_float / s_out), -128, 127)
    return q * s_out  # float로 복귀 (양자화 오차만 남음)


def dequantize_from_bin(bin_path, s_out, shape=(1, 128, 40, 40)):
    """실제 HW에서 읽어온 int8 .bin -> float 텐서"""
    raw = np.fromfile(bin_path, dtype=np.int8).astype(np.float32)
    expected = int(np.prod(shape))
    if raw.size != expected:
        raise SystemExit(f"[!] hw_output_bin 크기 불일치: {raw.size} vs {expected}")
    return torch.from_numpy(raw.reshape(shape)) * s_out


def make_replace_hook(replacement_holder):
    """model.6 forward hook: output을 replacement_holder['value']로 바꿔치기.
    replacement_holder가 비어 있으면(None) 원래 값을 그대로 통과시킴
    (float_ref 모드에서는 이 후크를 아예 안 붙이므로 도달하지 않음)"""
    def hook(_module, _input, output):
        return replacement_holder["value"]
    return hook


def run(model, x, layer6_replacement=None):
    """
    layer6_replacement: None이면 순수 float 그대로 (float_ref).
                        텐서면 model.6 출력을 이 값으로 바꿔치기.
    return: (raw_model6_output, final_detection_output)
    """
    cap6 = {}
    holder = {"value": layer6_replacement}

    def cap_hook(_m, _i, o):
        cap6["raw"] = o.detach()
        if layer6_replacement is not None:
            return layer6_replacement
        return None  # 원래 값 그대로 사용

    h = model.model.model[6].register_forward_hook(cap_hook)
    with torch.no_grad():
        out = model.model(x)
    h.remove()
    return cap6["raw"], out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="models/best.pt")
    ap.add_argument("--image", required=True)
    ap.add_argument("--mode", required=True,
                    choices=["float_ref", "hw_emulate", "hw_readback"])
    ap.add_argument("--calib", default="calib_out/calib_params.json",
                    help="hw_emulate/hw_readback 모드에서 S_out 조회용")
    ap.add_argument("--hw-output-bin", default=None,
                    help="hw_readback 모드: 실제 HW int8 출력 .bin 경로")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--save-npy", default=None,
                    help="model.6 원본/대체값을 비교용으로 저장 (선택)")
    args = ap.parse_args()

    from ultralytics import YOLO
    yolo = YOLO(args.weights)
    yolo.model.eval()

    x = preprocess(args.image, args.imgsz)

    if args.mode == "float_ref":
        raw6, out = run(yolo, x, layer6_replacement=None)
        print("[i] mode = float_ref (순수 SW 전체, 후크 없음)")

    elif args.mode == "hw_emulate":
        calib = load_calib(args.calib)
        s_out = calib["boundary"]["hw_out_scale"]
        # 실제 model.6 값을 float로 한 번 계산해두기 위해 우선 replacement=None으로 돎
        raw6_true, _ = run(yolo, x, layer6_replacement=None)
        emulated = quantize_dequantize(raw6_true, s_out)
        raw6, out = run(yolo, x, layer6_replacement=emulated)
        err = (emulated - raw6_true).abs()
        print(f"[i] mode = hw_emulate, S_out = {s_out:.10f}")
        print(f"[i] 양자화 오차: mean|err| = {err.mean().item():.5f}, "
              f"max|err| = {err.max().item():.5f} "
              f"(model.6 |max| = {raw6_true.abs().max().item():.4f})")

    else:  # hw_readback
        if args.hw_output_bin is None:
            raise SystemExit("[!] hw_readback 모드는 --hw-output-bin 이 필요합니다")
        calib = load_calib(args.calib)
        s_out = calib["boundary"]["hw_out_scale"]
        shape = tuple([1] + calib["boundary"]["shape"])  # [1,128,40,40]
        hw_feat = dequantize_from_bin(args.hw_output_bin, s_out, shape)
        raw6, out = run(yolo, x, layer6_replacement=hw_feat)
        print(f"[i] mode = hw_readback, {args.hw_output_bin} 로부터 역양자화, "
              f"S_out = {s_out:.10f}")

    print(f"[i] model.6 출력으로 실제 사용된 shape = {tuple(raw6.shape)}")

    # ultralytics YOLO(...) 를 통째로 부르지 않고 model.model(x)만 돌렸으므로
    # out은 raw head 출력(리스트/텐서, NMS 이전)입니다.
    if isinstance(out, (list, tuple)):
        print(f"[i] raw output = {len(out)}개 텐서, out[0].shape = {tuple(out[0].shape)}")
    else:
        print(f"[i] raw output shape = {tuple(out.shape)}")

    if args.save_npy:
        np.save(args.save_npy, raw6.cpu().numpy())
        print(f"[OK] {args.save_npy} 저장 (model.6 출력, float, [1,128,40,40])")


if __name__ == "__main__":
    main()