#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
calibrate_model6.py  —  model.6 (C2f) 통합 양자화 보정
=====================================================
기존 golden reference 스크립트 10개에 흩어져 있던 스케일 계산을 하나로 합칩니다.

기존 스크립트와 다른 점 (딱 두 가지):
  1) 입력이 torch.randn 이 아니라 실제 val 이미지 230장
  2) 경계마다 스케일을 "하나만" 계산해서 여러 IP가 공유하도록 함
     (기존: concat이 y0=0.0476, y1=0.0318 로 따로 계산했으나 split IP는
      리스케일을 안 하므로 실제 HW에서는 성립할 수 없는 값이었음)

bn_scale / bn_shift 계산식은 기존 스크립트 그대로입니다. 가중치 양자화도
best.pt 만 보므로 기존 weight.bin 과 동일한 값이 나옵니다.

사용법
  python calibrate_model6.py --weights models/best.pt \
      --images datasets/ppe/images/val --out calib_out
"""

import argparse
import glob
import json
import os

import numpy as np
import torch

QMAX = 127.0


# ---------------------------------------------------------------- 전처리
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


def load_image(path, imgsz=640):
    import cv2
    bgr = cv2.imread(path)
    if bgr is None:
        return None
    rgb = letterbox(bgr, imgsz)[:, :, ::-1].copy()
    return (torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0).unsqueeze(0)


# ------------------------------------------------- 활성화 통계 (2-pass)
class Collector:
    """1패스: 절대 최대값 -> 2패스: 히스토그램 -> MSE 최소 threshold"""

    def __init__(self, nbins=2048):
        self.nbins, self.amax = nbins, 0.0
        self.hist = self.edges = None

    def pass1(self, t):
        m = float(t.detach().abs().max())
        if m > self.amax:
            self.amax = m

    def open_hist(self):
        self.edges = np.linspace(0.0, max(self.amax, 1e-12), self.nbins + 1)
        self.hist = np.zeros(self.nbins, dtype=np.float64)

    def pass2(self, t):
        v = t.detach().abs().flatten().cpu().numpy()
        self.hist += np.histogram(v, bins=self.edges)[0]

    def scale(self, mode="mse", pct=99.99):
        if mode == "max":
            return self.amax / QMAX
        centers = 0.5 * (self.edges[:-1] + self.edges[1:])
        if mode == "percentile":
            c = np.cumsum(self.hist)
            if c[-1] == 0:
                return self.amax / QMAX
            i = min(int(np.searchsorted(c, c[-1] * pct / 100.0)), self.nbins - 1)
            return float(self.edges[i + 1]) / QMAX
        best_t, best_e = self.amax, None
        for i in range(int(self.nbins * 0.2), self.nbins):
            t = float(self.edges[i + 1])
            if t <= 0:
                continue
            s = t / QMAX
            q = np.clip(np.round(centers / s), -QMAX, QMAX) * s
            e = float(np.sum(self.hist * (centers - q) ** 2))
            if best_e is None or e < best_e:
                best_e, best_t = e, t
        return best_t / QMAX


# ------------------------------------------------------------------ 탭
TAPS = {
    "S_in":     "model.5 출력 = C2f 입력 (HW 입력 경계, 128ch)",
    "S_cv1out": "bn_silu_128(cv1) 출력 (128ch) — split/concat/residual 공유",
    "S_m0cv1":  "Bottleneck0 cv1 출력 (64ch)",
    "S_m0cv2":  "Bottleneck0 cv2 출력 (64ch) = F(x)",
    "S_y2":     "Bottleneck0 residual 출력 (64ch)",
    "S_m1cv1":  "Bottleneck1 cv1 출력 (64ch)",
    "S_m1cv2":  "Bottleneck1 cv2 출력 (64ch) = F(x)",
    "S_y3":     "Bottleneck1 residual 출력 (64ch)",
    "S_cat":    "concat 출력 (256ch)",
    "S_out":    "bn_silu_128(cv2) 출력 = C2f 출력 (HW 출력 경계, 128ch)",
}

CONVS = [
    ("cv1",    "cv1"),
    ("m0_cv1", "m.0.cv1"),
    ("m0_cv2", "m.0.cv2"),
    ("m1_cv1", "m.1.cv1"),
    ("m1_cv2", "m.1.cv2"),
    ("cv2",    "cv2"),
]


def get_mod(root, path):
    m = root
    for p in path.split("."):
        m = m[int(p)] if p.isdigit() else getattr(m, p)
    return m


# ----------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="models/best.pt")
    ap.add_argument("--images", required=True, help="val 이미지 디렉터리")
    ap.add_argument("--num", type=int, default=230)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--layer", type=int, default=6)
    ap.add_argument("--mode", default="mse", choices=["mse", "percentile", "max"])
    ap.add_argument("--pct", type=float, default=99.99)
    ap.add_argument("--nbins", type=int, default=2048)
    ap.add_argument("--out", default="calib_out")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)

    from ultralytics import YOLO
    model = YOLO(args.weights).model
    model.eval()
    net = model.model
    c2f = net[args.layer]
    print(f"[i] target = model.{args.layer} : {type(c2f).__name__}")

    files = []
    for e in ("*.jpg", "*.jpeg", "*.png", "*.bmp", "*.JPG", "*.PNG"):
        files += glob.glob(os.path.join(args.images, "**", e), recursive=True)
    files = sorted(set(files))[: args.num]
    if not files:
        raise SystemExit(f"[!] 이미지를 못 찾았습니다: {args.images}")
    print(f"[i] calibration images = {len(files)}")

    cap = {}

    def hk(name):
        def fn(_m, _i, o):
            cap[name] = o.detach()
        return fn

    hs = [
        net[args.layer - 1].register_forward_hook(hk("S_in")),
        c2f.cv1.register_forward_hook(hk("S_cv1out")),
        c2f.m[0].cv1.register_forward_hook(hk("S_m0cv1")),
        c2f.m[0].cv2.register_forward_hook(hk("S_m0cv2")),
        c2f.m[0].register_forward_hook(hk("S_y2")),
        c2f.m[1].cv1.register_forward_hook(hk("S_m1cv1")),
        c2f.m[1].cv2.register_forward_hook(hk("S_m1cv2")),
        c2f.m[1].register_forward_hook(hk("S_y3")),
        c2f.cv2.register_forward_hook(hk("S_out")),
    ]

    col = {k: Collector(args.nbins) for k in TAPS}

    def sweep(fn):
        with torch.no_grad():
            for k, f in enumerate(files):
                x = load_image(f, args.imgsz)
                if x is None:
                    continue
                model(x)
                # concat 은 모듈이 아니므로 C2f.forward 그대로 재구성
                y0, y1 = cap["S_cv1out"][0].chunk(2, 0)
                cap["S_cat"] = torch.cat(
                    [y0, y1, cap["S_y2"][0], cap["S_y3"][0]], 0)
                for name in TAPS:
                    fn(col[name], cap[name])
                if (k + 1) % 25 == 0:
                    print(f"    {k+1}/{len(files)}")

    print("[1/2] absolute max ...")
    sweep(lambda c, t: c.pass1(t))
    for c in col.values():
        c.open_hist()
    print("[2/2] histogram ...")
    sweep(lambda c, t: c.pass2(t))
    for h in hs:
        h.remove()

    S = {k: col[k].scale(args.mode, args.pct) for k in TAPS}
    print("\n=== 활성화 스케일 (10개) ===")
    for k in TAPS:
        keep = S[k] * QMAX / col[k].amax if col[k].amax > 0 else 1.0
        print(f"  {k:10s} = {S[k]:.10f}   |max|={col[k].amax:8.4f}  "
              f"keep={keep*100:5.1f}%")

    W = {}
    print("\n=== 가중치 스케일 (6개) ===")
    for tag, path in CONVS:
        mod = get_mod(c2f, path)
        wt = mod.conv.weight.detach()
        bn = mod.bn

        w_scale = max(abs(wt.min().item()), abs(wt.max().item())) / QMAX
        w_int8 = torch.clamp(torch.round(wt / w_scale), -128, 127).to(torch.int32)

        bn_scale = (bn.weight.detach()
                    / torch.sqrt(bn.running_var.detach() + bn.eps))
        bn_shift = bn.bias.detach() - bn.running_mean.detach() * bn_scale

        w_int8.numpy().flatten().tofile(f"{args.out}/{tag}_weight.bin")
        bn_scale.numpy().astype(np.float32).tofile(f"{args.out}/{tag}_bn_scale.bin")
        bn_shift.numpy().astype(np.float32).tofile(f"{args.out}/{tag}_bn_shift.bin")

        W[tag] = w_scale
        print(f"  {tag:8s} {str(list(wt.shape)):18s} weight_scale = {w_scale:.10f}")

    # ---- 파라미터 세트 (PS 호출 순서대로) ----
    P = [
        {"step": 1,  "ip": "conv1x1_cv1",   "note": "128->128, 스케일 인자 없음"},
        {"step": 2,  "ip": "bn_silu_128",   "input_scale": S["S_in"],
         "weight_scale": W["cv1"],    "output_scale": S["S_cv1out"]},
        {"step": 3,  "ip": "split_channel", "note": "스케일 인자 없음 (S_cv1out 유지)"},
        {"step": 4,  "ip": "conv3x3",       "layer_id": 0, "note": "m.0.cv1"},
        {"step": 5,  "ip": "bn_silu_64",    "input_scale": S["S_cv1out"],
         "weight_scale": W["m0_cv1"], "output_scale": S["S_m0cv1"]},
        {"step": 6,  "ip": "conv3x3",       "layer_id": 1, "note": "m.0.cv2"},
        {"step": 7,  "ip": "bn_silu_64",    "input_scale": S["S_m0cv1"],
         "weight_scale": W["m0_cv2"], "output_scale": S["S_m0cv2"]},
        {"step": 8,  "ip": "residual_add",  "x_scale": S["S_cv1out"],
         "fx_scale": S["S_m0cv2"],    "output_scale": S["S_y2"]},
        {"step": 9,  "ip": "conv3x3",       "layer_id": 2, "note": "m.1.cv1"},
        {"step": 10, "ip": "bn_silu_64",    "input_scale": S["S_y2"],
         "weight_scale": W["m1_cv1"], "output_scale": S["S_m1cv1"]},
        {"step": 11, "ip": "conv3x3",       "layer_id": 3, "note": "m.1.cv2"},
        {"step": 12, "ip": "bn_silu_64",    "input_scale": S["S_m1cv1"],
         "weight_scale": W["m1_cv2"], "output_scale": S["S_m1cv2"]},
        {"step": 13, "ip": "residual_add",  "x_scale": S["S_y2"],
         "fx_scale": S["S_m1cv2"],    "output_scale": S["S_y3"]},
        {"step": 14, "ip": "concat_channel",
         "scale0": S["S_cv1out"], "scale1": S["S_cv1out"],
         "scale2": S["S_y2"],     "scale3": S["S_y3"],
         "output_scale": S["S_cat"],
         "note": "scale0 == scale1 (둘 다 split 이전 bn_silu_128 출력)"},
        {"step": 15, "ip": "conv1x1_cv2",   "note": "256->128, 스케일 인자 없음"},
        {"step": 16, "ip": "bn_silu_128",   "input_scale": S["S_cat"],
         "weight_scale": W["cv2"],    "output_scale": S["S_out"]},
    ]

    result = {
        "meta": {"images": len(files), "mode": args.mode, "imgsz": args.imgsz,
                 "weights": args.weights,
                 "convention": "bn_out = acc*(input_scale*weight_scale)*bn_scale[c]"
                               " + bn_shift[c];  out = round(SiLU(bn_out)/output_scale)"},
        "activation_scale": S,
        "weight_scale": W,
        "boundary": {"hw_in_scale": S["S_in"], "hw_out_scale": S["S_out"],
                     "shape": [128, 40, 40]},
        "param_sets": P,
    }
    with open(f"{args.out}/calib_params.json", "w") as f:
        json.dump(result, f, indent=2)

    with open(f"{args.out}/model6_params.h", "w") as f:
        f.write("// auto-generated by calibrate_model6.py\n")
        f.write("#ifndef MODEL6_PARAMS_H\n#define MODEL6_PARAMS_H\n\n")
        for k, v in S.items():
            f.write(f"#define {k.upper():14s} {v:.10f}f\n")
        f.write("\n")
        for k, v in W.items():
            f.write(f"#define WSCALE_{k.upper():10s} {v:.10f}f\n")
        f.write("\n#endif\n")

    print(f"\n[OK] {args.out}/calib_params.json")
    print(f"[OK] {args.out}/model6_params.h")
    print(f"[OK] *_weight.bin / *_bn_scale.bin / *_bn_shift.bin")


if __name__ == "__main__":
    main()