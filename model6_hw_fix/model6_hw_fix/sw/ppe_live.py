#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ppe_live.py — SW(0~5) + HW(model.6) + SW(7~22) 실시간 파이프라인
=================================================================
보드에서 돌린다. 비트스트림은 시작할 때 한 번만 굽는다.

기존 sw_model7up.py 는 "전체를 돌리고 후크로 가로채기" 였다. 검증에는 맞지만
카메라에서는 model.6~22 를 두 번 계산하는 낭비다. 여기서는 레이어를 순서대로
돌면서 6번째만 하드웨어 결과로 갈아끼운다.

YOLOv8n 의 6번 출력은 11번(Concat)에서 다시 쓰이므로, ultralytics 의
DetectionModel 이 하는 것과 똑같이 save 목록을 유지해야 한다.

경계 규약 (보드 실측으로 확정된 것)
    입력  : int8, 픽셀 우선(HWC), [40][40][128], 204,800 B
    출력  : int8, 픽셀 우선(HWC), [40][40][256], 409,600 B
    스케일: 입력 S_in, 출력 S_cat

모드
    --image  파일        한 장 돌리고 검출과 단계별 시간을 찍는다 (검증용)
    --camera 0           카메라를 열어 MJPEG 로 내보낸다 (--port 8090)
"""

import argparse
import ctypes
import json
import mmap
import os
import struct
import time

os.environ.setdefault("XILINX_XRT", "/usr")
os.environ.setdefault("BOARD", "KV260")

import cv2  # noqa: E402
import numpy as np  # noqa: E402
import torch  # noqa: E402

AFI_FS, AFI_MASK, AFI_WANT = 0xFD615000, 0x00000F00, 0x00000A00
AFIFM_HP0, AFIFM_RD, AFIFM_WR = 0xFD380000, 0x00, 0x14
BASE = {"concat": 0xA0000000, "conv3x3": 0xA0010000, "bn_silu64": 0xA0020000,
        "residual": 0xA0030000, "bneck_rt": 0xA0040000, "bn128": 0xA0070000}
DMA = 0xA0050000
CONCAT_OFF = {"scale0": 0x10, "scale1": 0x18, "scale2": 0x20,
              "scale3": 0x28, "output_scale": 0x30}
MM2S_CR, MM2S_SR, MM2S_SA, MM2S_SA_MSB, MM2S_LEN = 0x00, 0x04, 0x18, 0x1C, 0x28
S2MM_CR, S2MM_SR, S2MM_DA, S2MM_DA_MSB, S2MM_LEN = 0x30, 0x34, 0x48, 0x4C, 0x58
DONE = 0x2 | (1 << 12)          # Idle 또는 IOC. TLAST 가 없어 Idle 은 안 선다.
H = W = 40
IN_CH, OUT_CH = 128, 256
IN_BYTES, OUT_BYTES = IN_CH * H * W, OUT_CH * H * W
HW_LAYER = 6


class Raw:
    def __init__(self, base, size=0x10000):
        page = base & ~0xFFF
        self.delta = base - page
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, size + self.delta, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
        self.buf = ctypes.c_char.from_buffer(self.mm)
        self.addr = ctypes.addressof(self.buf) + self.delta

    def r(self, off):
        return ctypes.c_uint32.from_address(self.addr + off).value

    def w(self, off, val):
        ctypes.c_uint32.from_address(self.addr + off).value = val & 0xFFFFFFFF


class Model6HW:
    """model.6 을 도는 FPGA. 비트스트림은 생성자에서 한 번만 굽는다."""

    def __init__(self, bitfile, calib, timeout=2.0):
        from pynq import Bitstream, allocate
        Bitstream(bitfile).download()

        a = Raw(AFI_FS, 0x1000)
        a.w(0, (a.r(0) & ~AFI_MASK) | AFI_WANT)     # PS->PL 마스터 폭 128bit
        f = Raw(AFIFM_HP0, 0x1000)
        for off in (AFIFM_RD, AFIFM_WR):
            f.w(off, (f.r(off) & ~0x3) | 2)         # PL->PS 슬레이브 폭 32bit

        self.ip = {n: Raw(b) for n, b in BASE.items()}
        sc = next(s for s in calib["param_sets"] if s["ip"] == "concat_channel")
        for k, off in CONCAT_OFF.items():
            self.ip["concat"].w(off, struct.unpack("<I", struct.pack("<f", sc[k]))[0])
        bad = [k for k, o in CONCAT_OFF.items()
               if self.ip["concat"].r(o) != struct.unpack("<I", struct.pack("<f", sc[k]))[0]]
        if bad:
            raise SystemExit(f"[!] concat 스칼라가 반영되지 않음: {bad}")

        for m in self.ip.values():
            m.w(0x00, (1 << 7) | 1)                 # auto_restart + ap_start
        time.sleep(0.02)

        self.dma = Raw(DMA)
        self.tx = allocate(shape=(IN_BYTES,), dtype=np.int8)
        self.rx = allocate(shape=(OUT_BYTES,), dtype=np.int8)
        self.timeout = timeout
        self.frames = 0

    def run(self, payload_hwc):
        """payload_hwc: int8 1차원 204,800개 (픽셀 우선). 반환도 int8 1차원."""
        self.tx[:] = payload_hwc
        self.tx.flush()

        # S2MM 은 한 프레임을 다 받은 뒤 DMAIntErr 로 halt 한다 (TLAST 없음).
        # 다음 프레임을 받으려면 코어를 리셋해야 한다. 12프레임 연속 시험에서
        # 프레임 사이에 값이 어긋나지 않음을 확인했다.
        d = self.dma
        d.w(MM2S_CR, 4)
        time.sleep(0.002)
        d.w(MM2S_CR, 1)
        d.w(S2MM_CR, 1)

        d.w(S2MM_DA, self.rx.physical_address & 0xFFFFFFFF)
        d.w(S2MM_DA_MSB, 0)
        d.w(S2MM_LEN, OUT_BYTES)
        d.w(MM2S_SA, self.tx.physical_address & 0xFFFFFFFF)
        d.w(MM2S_SA_MSB, 0)
        d.w(MM2S_LEN, IN_BYTES)

        dl = time.monotonic() + self.timeout
        while time.monotonic() < dl and not (d.r(S2MM_SR) & DONE):
            pass
        if not (d.r(S2MM_SR) & DONE):
            raise TimeoutError(f"S2MM 미완료 SR=0x{d.r(S2MM_SR):08x}")
        self.rx.invalidate()
        self.frames += 1
        return np.array(self.rx, dtype=np.int8)

    def close(self):
        self.tx.freebuffer()
        self.rx.freebuffer()


def letterbox(img, new_shape=640, color=(114, 114, 114)):
    h, w = img.shape[:2]
    r = min(new_shape / h, new_shape / w)
    nh, nw = int(round(h * r)), int(round(w * r))
    im = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    top, left = (new_shape - nh) // 2, (new_shape - nw) // 2
    return cv2.copyMakeBorder(im, top, new_shape - nh - top,
                              left, new_shape - nw - left,
                              cv2.BORDER_CONSTANT, value=color), r, left, top


class Pipeline:
    def __init__(self, weights, calib_path, bitfile, imgsz=640,
                 conf=0.25, iou=0.45, hw=True):
        from ultralytics import YOLO
        self.calib = json.load(open(calib_path))
        self.s_in = self.calib["boundary"]["hw_in_scale"]
        self.s_cat = self.calib["activation_scale"]["S_cat"]
        y = YOLO(weights)
        y.model.eval()
        self.net = y.model
        self.names = y.model.names
        self.imgsz, self.conf, self.iou = imgsz, conf, iou
        self.hw = Model6HW(bitfile, self.calib) if hw else None

    # --- model.6 경계 -------------------------------------------------
    def _to_hw(self, feat):
        q = torch.clamp(torch.round(feat[0] / self.s_in), -128, 127)
        chw = q.to(torch.int8).numpy()                    # (128,40,40)
        return np.ascontiguousarray(chw.transpose(1, 2, 0)).ravel()

    def _from_hw(self, raw):
        hwc = raw.reshape(H, W, OUT_CH).astype(np.float32)
        chw = np.ascontiguousarray(hwc.transpose(2, 0, 1))
        return torch.from_numpy(chw).unsqueeze(0) * self.s_cat

    # --- 레이어를 직접 돌면서 6번만 갈아끼운다 -------------------------
    def _forward(self, x, t):
        y = []
        for m in self.net.model:
            if m.f != -1:
                x = y[m.f] if isinstance(m.f, int) else \
                    [x if j == -1 else y[j] for j in m.f]
            if m.i == HW_LAYER and self.hw is not None:
                t["sw0_5"] = time.monotonic() - t["_t0"]
                payload = self._to_hw(x)
                t0 = time.monotonic()
                raw = self.hw.run(payload)
                t["hw6"] = time.monotonic() - t0
                x = m.cv2(self._from_hw(raw))             # concat -> cv2
                t["_t1"] = time.monotonic()
            else:
                x = m(x)
            y.append(x if m.i in self.net.save else None)
        return x

    def infer(self, bgr):
        from ultralytics.yolo.utils.ops import non_max_suppression
        t = {"_t0": time.monotonic()}
        im, r, dx, dy = letterbox(bgr, self.imgsz)
        xt = torch.from_numpy(im[:, :, ::-1].copy()).permute(2, 0, 1)
        xt = (xt.float() / 255.0).unsqueeze(0)
        t["pre"] = time.monotonic() - t["_t0"]
        with torch.no_grad():
            out = self._forward(xt, t)
        pred = out[0] if isinstance(out, (list, tuple)) else out
        t["sw7_22"] = time.monotonic() - t.get("_t1", t["_t0"])
        det = non_max_suppression(pred.clone(), self.conf, self.iou,
                                  nc=len(self.names))[0]
        t["total"] = time.monotonic() - t["_t0"]
        if len(det):
            det[:, [0, 2]] = (det[:, [0, 2]] - dx) / r
            det[:, [1, 3]] = (det[:, [1, 3]] - dy) / r
        return det, t


PALETTE = [(56, 56, 255), (49, 210, 207), (10, 249, 72), (23, 204, 146),
           (134, 219, 61), (52, 147, 26), (187, 212, 0), (168, 153, 44),
           (255, 194, 0), (147, 69, 52)]


def draw(frame, det, names, fps=None):
    for *xyxy, cf, cl in det.tolist():
        c = PALETTE[int(cl) % len(PALETTE)]
        p1 = (int(xyxy[0]), int(xyxy[1]))
        p2 = (int(xyxy[2]), int(xyxy[3]))
        cv2.rectangle(frame, p1, p2, c, 2)
        lab = f"{names[int(cl)]} {cf:.2f}"
        (tw, th), _ = cv2.getTextSize(lab, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        cv2.rectangle(frame, (p1[0], p1[1] - th - 6), (p1[0] + tw + 4, p1[1]), c, -1)
        cv2.putText(frame, lab, (p1[0] + 2, p1[1] - 4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
    if fps is not None:
        cv2.putText(frame, f"FPGA model.6  {fps:.2f} fps", (8, 24),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
    return frame


def serve(pipe, cam, port, width, height):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    cap = cv2.VideoCapture(cam)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    if not cap.isOpened():
        raise SystemExit(f"[!] 카메라 {cam} 를 열 수 없다")
    state = {"fps": 0.0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type",
                             "multipart/x-mixed-replace; boundary=f")
            self.end_headers()
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                t0 = time.monotonic()
                det, t = pipe.infer(frame)
                dt = time.monotonic() - t0
                state["fps"] = 0.8 * state["fps"] + 0.2 * (1.0 / dt)
                draw(frame, det, pipe.names, state["fps"])
                ok, jpg = cv2.imencode(".jpg", frame,
                                       [cv2.IMWRITE_JPEG_QUALITY, 80])
                if not ok:
                    continue
                try:
                    self.wfile.write(b"--f\r\nContent-Type: image/jpeg\r\n"
                                     b"Content-Length: " +
                                     str(len(jpg)).encode() + b"\r\n\r\n")
                    self.wfile.write(jpg.tobytes())
                    self.wfile.write(b"\r\n")
                except (BrokenPipeError, ConnectionResetError):
                    break

    print(f"[i] http://0.0.0.0:{port}/  (맥에서 SSH 터널로 보세요)")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default="models/best.pt")
    ap.add_argument("--calib", default="calib_out/calib_params.json")
    ap.add_argument("--bitfile", default="hw/ppe_fpga_yoo_fix4.bit")
    ap.add_argument("--image", default=None)
    ap.add_argument("--camera", type=int, default=None)
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--no-hw", action="store_true",
                    help="FPGA 없이 순수 SW 로 (대조군)")
    args = ap.parse_args()

    print(f"[1] 모델/비트스트림 준비 (hw={'끔' if args.no_hw else '켬'})")
    pipe = Pipeline(args.weights, args.calib, args.bitfile, hw=not args.no_hw)

    if args.image:
        bgr = cv2.imread(args.image)
        if bgr is None:
            raise SystemExit(f"[!] 이미지를 못 읽음: {args.image}")
        for k in range(args.repeat):
            det, t = pipe.infer(bgr)
            if k == args.repeat - 1:
                print(f"\n[2] 검출 {len(det)}건")
                for *xy, cf, cl in det.tolist():
                    print(f"    {pipe.names[int(cl)]:16s} {cf:.3f}  "
                          f"[{int(xy[0])},{int(xy[1])},{int(xy[2])},{int(xy[3])}]")
                print(f"\n[3] 단계별 시간 (초)")
                for k2 in ("pre", "sw0_5", "hw6", "sw7_22", "total"):
                    if k2 in t:
                        print(f"    {k2:8s} {t[k2]:.4f}")
                print(f"    -> {1/t['total']:.2f} fps")
    elif args.camera is not None:
        serve(pipe, args.camera, args.port, args.width, args.height)
    else:
        raise SystemExit("--image 또는 --camera 중 하나를 주세요")


if __name__ == "__main__":
    main()
