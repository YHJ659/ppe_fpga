#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sw_model7up.py  —  3단계: HW 출력 이후 소프트웨어 (cv2 + model.7~)
===================================================================
[2026-08-07 갱신 — cv2 SW 이전 반영]

cv2 가 자원 문제로 하드웨어에서 빠지면서 HW/SW 경계가 옮겨졌습니다.

    [SW] model.0~5 -> hw_input.bin (int8, 128ch, S_in)
              -> [HW] cv1 ~ concat
                   -> hw_output.bin (int8, **256ch**, **S_cat**)
                        -> [SW] cv2 + BN + SiLU -> model.7~22

바뀐 점 두 가지 (인수인계 문서 1절·4절):
  * 후크 지점: model.6 **출력** 대체  ->  model.6.cv2 **입력** 대체
    (register_forward_hook -> register_forward_pre_hook)
  * 스케일: boundary.hw_out_scale (무효)  ->  activation_scale.S_cat

cv2 가중치를 따로 뽑을 필요는 없습니다. best.pt 의 model.6.cv2 에 float
가중치가 그대로 있고, 입력만 바꿔치기하면 PyTorch 가 cv2 -> BN -> SiLU ->
model.7~22 를 원래대로 실행합니다. skip connection 도 자동 처리됩니다.

3가지 모드
  float_ref   : 후크 없음. 순수 SW 전체 (5단계 기준값 A)
  hw_emulate  : concat 출력을 S_cat 으로 양자화->역양자화만 흉내
                (실제 HW 없이 로직·오차를 미리 확인)
  hw_readback : 실제 HW 가 DMA 로 내보낸 int8 .bin 을 주입 (5단계 본시험)

사용법
  python sw_model7up.py --weights models/best.pt --image X.jpg --mode float_ref
  python sw_model7up.py --weights models/best.pt --image X.jpg --mode hw_emulate
  python sw_model7up.py --weights models/best.pt --image X.jpg \
      --mode hw_readback --hw-output-bin hw_output.bin
"""

import argparse
import json

import numpy as np
import torch

# HW 출력 = concat 출력 = cv2 입력
HW_OUT_SHAPE = (1, 256, 40, 40)
HW_OUT_BYTES = int(np.prod(HW_OUT_SHAPE))      # 409,600


def load_calib(path):
    with open(path) as f:
        return json.load(f)


def get_s_cat(calib):
    """HW 출력 경계 스케일. boundary.hw_out_scale 은 cv2 가 HW 에 있던
    시절 값이라 더 이상 쓰지 않는다."""
    return calib["activation_scale"]["S_cat"]


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


def quantize_dequantize(feat_float, scale):
    """HW 경계 왕복을 흉내. 포화 비율도 함께 돌려준다."""
    q = torch.clamp(torch.round(feat_float / scale), -128, 127)
    saturated = float((q.abs() == 127).float().mean().item())
    return q * scale, saturated


def dequantize_from_bin(bin_path, scale, shape=HW_OUT_SHAPE):
    raw = np.fromfile(bin_path, dtype=np.int8).astype(np.float32)
    if raw.size != HW_OUT_BYTES:
        raise SystemExit(
            f"[!] hw_output_bin 크기 불일치: {raw.size} bytes "
            f"(기대 {HW_OUT_BYTES} = 256ch x 40 x 40). "
            f"128채널(204,800)로 착각하지 않았는지 확인하세요.")
    return torch.from_numpy(raw.reshape(shape)) * scale


def cv2_module(model):
    """model.6(C2f)의 cv2. 이 모듈의 입력이 곧 concat 출력 = HW 출력 경계."""
    return model.model.model[6].cv2


def capture_cv2_input(model, x):
    """순수 float 실행 + cv2 입력(concat 출력, 256ch) 캡처."""
    holder = {}

    def pre_hook(_m, args):
        holder["value"] = args[0].detach()
        return None                      # 원래 입력 그대로 통과

    handle = cv2_module(model).register_forward_pre_hook(pre_hook)
    with torch.no_grad():
        out = model.model(x)
    handle.remove()
    return holder["value"], out


def run_with_cv2_input(model, x, replacement):
    """cv2 의 입력을 replacement 로 바꿔치고 나머지는 원래대로 실행.
    cv2 -> BN -> SiLU -> model.7~22 가 전부 float 로 자동 진행된다."""
    def pre_hook(_m, _args):
        return (replacement,)

    handle = cv2_module(model).register_forward_pre_hook(pre_hook)
    with torch.no_grad():
        out = model.model(x)
    handle.remove()
    return out


def primary(out):
    return out[0] if isinstance(out, (list, tuple)) else out


def decode(prediction, conf, iou, nc):
    from ultralytics.yolo.utils.ops import non_max_suppression
    return non_max_suppression(prediction.clone(), conf, iou, nc=nc)[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="models/best.pt")
    ap.add_argument("--image", required=True)
    ap.add_argument("--mode", required=True,
                    choices=["float_ref", "hw_emulate", "hw_readback"])
    ap.add_argument("--calib", default="calib_out/calib_params.json")
    ap.add_argument("--hw-output-bin", default=None)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--iou", type=float, default=0.45)
    ap.add_argument("--save-npy", default=None)
    args = ap.parse_args()

    from ultralytics import YOLO
    yolo = YOLO(args.weights)
    yolo.model.eval()
    names = yolo.names if isinstance(yolo.names, dict) else \
        {i: n for i, n in enumerate(yolo.names)}
    nc = len(names)

    x = preprocess(args.image, args.imgsz)

    # 어느 모드든 기준값(순수 SW)과 concat 출력을 먼저 확보한다.
    concat_float, ref_out = capture_cv2_input(yolo, x)
    if tuple(concat_float.shape) != HW_OUT_SHAPE:
        raise SystemExit(f"[!] cv2 입력 shape 예상과 다름: "
                         f"{tuple(concat_float.shape)} vs {HW_OUT_SHAPE}")
    print(f"[i] HW 출력 경계(= cv2 입력) shape = {tuple(concat_float.shape)}, "
          f"|max| = {concat_float.abs().max().item():.4f}")

    if args.mode == "float_ref":
        out = ref_out
        print("[i] mode = float_ref (순수 SW 전체, 후크 없음)")

    elif args.mode == "hw_emulate":
        s_cat = get_s_cat(load_calib(args.calib))
        emulated, sat = quantize_dequantize(concat_float, s_cat)
        out = run_with_cv2_input(yolo, x, emulated)
        err = (emulated - concat_float).abs()
        print(f"[i] mode = hw_emulate, S_cat = {s_cat:.10f}")
        print(f"[i] 양자화 오차 mean|err| = {err.mean().item():.6f}, "
              f"max|err| = {err.max().item():.6f}")
        print(f"[i] 포화(±127) 비율 = {sat*100:.3f}%")

    else:  # hw_readback
        if args.hw_output_bin is None:
            raise SystemExit("[!] hw_readback 모드는 --hw-output-bin 이 필요합니다")
        s_cat = get_s_cat(load_calib(args.calib))
        hw_feat = dequantize_from_bin(args.hw_output_bin, s_cat)
        out = run_with_cv2_input(yolo, x, hw_feat)
        err = (hw_feat - concat_float).abs()
        print(f"[i] mode = hw_readback, S_cat = {s_cat:.10f}")
        print(f"[i] HW vs SW concat 출력 차이: mean = {err.mean().item():.6f}, "
              f"max = {err.max().item():.6f}")
        # int8 단계에서 몇 개나 정확히 일치하는지가 진짜 판정 기준
        sw_q = torch.clamp(torch.round(concat_float / s_cat), -128, 127)
        hw_q = torch.round(hw_feat / s_cat)
        diff = (sw_q - hw_q).abs()
        print(f"[i] int8 완전일치 {int((diff==0).sum())}/{diff.numel()} "
              f"({(diff==0).float().mean().item()*100:.3f}%), "
              f"±1 이내 {(diff<=1).float().mean().item()*100:.3f}%, "
              f"최대차 {int(diff.max())} LSB")

    ref_det = decode(primary(ref_out), args.conf, args.iou, nc)
    det = decode(primary(out), args.conf, args.iou, nc)
    print(f"[i] 검출: 순수SW {len(ref_det)}건 / 이번모드 {len(det)}건")
    for d in det.cpu().tolist():
        print(f"      {names[int(d[5])]:16s} {d[4]:.3f}  "
              f"[{d[0]:.0f},{d[1]:.0f},{d[2]:.0f},{d[3]:.0f}]")

    if args.save_npy:
        np.save(args.save_npy, concat_float.cpu().numpy())
        print(f"[OK] {args.save_npy} 저장 (concat 출력 float, {HW_OUT_SHAPE})")


if __name__ == "__main__":
    main()
