#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sw_model0to5.py  —  2단계: model.0~5 소프트웨어 구현 (A안)
===========================================================
전체 YOLOv8n을 float로 실행하고, model.5 출력을 hook으로 가로채서
HW(model.6)가 기대하는 형식으로 양자화합니다.

A안 (전체 forward 후 중간값 가로채기)을 쓴 이유:
  - model.6~22도 같이 계산되지만, model.5까지의 결과값 자체는
    B안(진짜로 잘라서 도는 방식)과 완전히 동일함
  - 지금 단계 목표는 "HW가 정확한 입력을 받는지" 확인이라 속도는 무관
  - fps를 실측하는 5단계에서 필요하면 B안으로 교체 (model.6~22를
    이중으로 계산하는 낭비를 없애기 위해)

HW 입력 규약 (calibrate_model6.py 의 boundary.hw_in_scale 과 동일 규약):
  hw_input_int8 = clamp(round(feature_map_float / S_in), -128, 127)
  shape = [128, 40, 40], dtype = int8, order = CHW
"""

import argparse
import json

import numpy as np
import torch


def load_calib(calib_json):
    with open(calib_json) as f:
        c = json.load(f)
    return c


class Model0to5Capture:
    """model.5 출력을 hook으로 캡처하는 래퍼 (A안: 전체 forward)"""

    def __init__(self, yolo_model, layer_idx=5):
        self.net = yolo_model.model  # nn.Sequential
        self.layer_idx = layer_idx
        self._captured = None
        self._handle = self.net.model[layer_idx].register_forward_hook(self._hook)

    def _hook(self, _m, _i, output):
        self._captured = output.detach()

    def __call__(self, x):
        """
        x: [1, 3, 640, 640] float, 0~1 정규화된 입력
        return: model.5 출력 [1, 128, 40, 40] float (아직 양자화 전)
        """
        with torch.no_grad():
            self.net(x)  # 전체 forward. model.6~22 결과는 버림
        return self._captured

    def close(self):
        self._handle.remove()


def quantize_to_hw_input(feat_float, s_in):
    """
    feat_float : [1, 128, 40, 40] 또는 [128, 40, 40] float tensor
    s_in       : calib_params.json 의 boundary.hw_in_scale (스칼라)
    return     : numpy int8 배열, shape [128, 40, 40], CHW
    """
    if feat_float.dim() == 4:
        feat_float = feat_float.squeeze(0)
    q = torch.clamp(torch.round(feat_float / s_in), -128, 127)
    return q.to(torch.int8).cpu().numpy()  # [128, 40, 40], CHW


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


def preprocess_frame(bgr_frame, imgsz=640):
    """웹캠 프레임(BGR, HWC, uint8) -> [1,3,H,W] float 0~1"""
    rgb = letterbox(bgr_frame, imgsz)[:, :, ::-1].copy()
    x = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0
    return x.unsqueeze(0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="models/best.pt")
    ap.add_argument("--calib", default="calib_out/calib_params.json")
    ap.add_argument("--image", required=True, help="테스트용 이미지 1장")
    ap.add_argument("--out", default="hw_input.bin")
    args = ap.parse_args()

    calib = load_calib(args.calib)
    s_in = calib["boundary"]["hw_in_scale"]
    print(f"[i] hw_in_scale (S_in) = {s_in:.10f}")

    from ultralytics import YOLO
    yolo = YOLO(args.weights)
    yolo.model.eval()

    cap = Model0to5Capture(yolo)

    import cv2
    bgr = cv2.imread(args.image)
    if bgr is None:
        raise SystemExit(f"[!] 이미지를 못 읽었습니다: {args.image}")
    x = preprocess_frame(bgr)

    feat = cap(x)  # [1, 128, 40, 40] float
    cap.close()

    print(f"[i] model.5 출력 shape = {tuple(feat.shape)}, "
          f"|max| = {feat.abs().max().item():.4f}")

    hw_in = quantize_to_hw_input(feat, s_in)  # [128, 40, 40] int8
    assert hw_in.shape == (128, 40, 40), hw_in.shape

    sat = np.mean(np.abs(hw_in) == 127) * 100
    print(f"[i] 포화(±127) 비율 = {sat:.2f}%  (10% 넘으면 S_in 재점검 필요)")

    hw_in.tofile(args.out)  # CHW, int8, 128*40*40 = 204800 bytes
    print(f"[OK] {args.out}  ({hw_in.nbytes} bytes, dtype=int8, shape=[128,40,40] CHW)")


if __name__ == "__main__":
    main()