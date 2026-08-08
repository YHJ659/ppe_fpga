#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_multi.py — 비트스트림을 한 번만 굽고 여러 프레임을 연속으로 돌린다
=====================================================================
카메라 구동의 실제 조건이 이것이다. run_model6.py 는 프레임마다 비트스트림을
다시 구워서 모든 상태가 초기화된 "첫 프레임" 만 시험한 셈이었다.

여기서 확인하려는 것 두 가지.

1) 2프레임째부터도 맞는가
   HLS IP 들의 call_counter 는 static 이라 프레임마다 증가한다.
       bn_silu_128  N_SET=2, 프레임당 1회  -> 프레임마다 슬롯 0,1,0,1...
       bn_silu_64   N_SET=4, 프레임당 4회  -> 프레임 안에서 0,1,2,3 순환
       conv3x3      N_SET=4, 프레임당 4회  -> 같음
       residual     N_SET=2, 프레임당 2회  -> 같음
   bn_silu_128 만 프레임 사이에 슬롯이 바뀐다. 그래서 .coe 의 슬롯1 을
   슬롯0(cv1) 값으로 덮어 두었다. 그게 실제로 통하는지 여기서 드러난다.

2) 프레임 사이에 DMA 를 복구할 수 있는가
   HLS 스트림에 TLAST 가 없어 S2MM 은 지정 길이를 다 받은 뒤 DMAIntErr 로
   halt 한다. 다음 프레임을 받으려면 리셋이 필요한데, 그때 회로 안에 남은
   데이터가 다음 프레임 머리에 섞이면 이후가 전부 밀린다.
"""

import argparse
import ctypes
import glob
import json
import mmap
import os
import struct
import time

os.environ.setdefault("XILINX_XRT", "/usr")
os.environ.setdefault("BOARD", "KV260")

import numpy as np  # noqa: E402

AFI_FS, AFI_MASK, AFI_WANT = 0xFD615000, 0x00000F00, 0x00000A00
AFIFM_HP0, AFIFM_RD, AFIFM_WR = 0xFD380000, 0x00, 0x14

BASE = {"concat": 0xA0000000, "conv3x3": 0xA0010000, "bn_silu64": 0xA0020000,
        "residual": 0xA0030000, "bneck_rt": 0xA0040000, "bn128": 0xA0070000}
DMA = 0xA0050000
CONCAT_OFF = {"scale0": 0x10, "scale1": 0x18, "scale2": 0x20,
              "scale3": 0x28, "output_scale": 0x30}
MM2S_CR, MM2S_SR, MM2S_SA, MM2S_SA_MSB, MM2S_LEN = 0x00, 0x04, 0x18, 0x1C, 0x28
S2MM_CR, S2MM_SR, S2MM_DA, S2MM_DA_MSB, S2MM_LEN = 0x30, 0x34, 0x48, 0x4C, 0x58
DONE = 0x2 | (1 << 12)
IN_BYTES, OUT_BYTES = 128 * 40 * 40, 256 * 40 * 40
FILL = np.int8(-86)


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


def f32(v):
    return struct.unpack("<I", struct.pack("<f", float(v)))[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bitfile", default="hw/ppe_fpga_yoo_fix4.bit")
    ap.add_argument("--calib", default="calib_out/calib_params.json")
    ap.add_argument("--indir", default="multi")
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--repeat", type=int, default=1,
                    help="입력 묶음을 몇 바퀴 돌릴지 (슬롯 순환 확인용)")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.indir, "in*.bin")))
    if not files:
        raise SystemExit(f"[!] {args.indir}/in*.bin 이 없다")
    calib = json.load(open(args.calib))

    from pynq import Bitstream, allocate
    print(f"[1] 비트스트림 1회 로드 {args.bitfile}")
    Bitstream(args.bitfile).download()

    a = Raw(AFI_FS, 0x1000)
    a.w(0, (a.r(0) & ~AFI_MASK) | AFI_WANT)
    f = Raw(AFIFM_HP0, 0x1000)
    for off in (AFIFM_RD, AFIFM_WR):
        f.w(off, (f.r(off) & ~0x3) | 2)
    print(f"[2] AFI_FS=0x{a.r(0):08X}  AFIFM2={f.r(AFIFM_RD) & 3}(=32bit)")

    ip = {n: Raw(b) for n, b in BASE.items()}
    sc = next(s for s in calib["param_sets"] if s["ip"] == "concat_channel")
    for k, off in CONCAT_OFF.items():
        ip["concat"].w(off, f32(sc[k]))
    bad = [k for k, o in CONCAT_OFF.items() if ip["concat"].r(o) != f32(sc[k])]
    print(f"[3] concat 스칼라 {'5개 반영' if not bad else '실패 ' + str(bad)}")

    for m in ip.values():
        m.w(0x00, (1 << 7) | 1)
    time.sleep(0.02)
    print("[4] IP 6개 auto_restart + ap_start")

    dma = Raw(DMA)
    tx = allocate(shape=(IN_BYTES,), dtype=np.int8)
    rx = allocate(shape=(OUT_BYTES,), dtype=np.int8)

    order = [p for _ in range(args.repeat) for p in files]
    print(f"\n[5] {len(order)} 프레임 연속 (비트스트림 재로드 없음)\n")
    print(f"    {'#':>3s} {'입력':10s}{'받은바이트':>11s}{'초':>8s}  상태")
    ok_all = True
    for n, path in enumerate(order):
        tx[:] = np.fromfile(path, dtype=np.int8)
        rx[:] = FILL
        tx.flush()
        rx.flush()

        dma.w(MM2S_CR, 4)                 # 코어 리셋 (양 채널 동시)
        time.sleep(0.002)
        dma.w(MM2S_CR, 1)
        dma.w(S2MM_CR, 1)

        t0 = time.monotonic()
        dma.w(S2MM_DA, rx.physical_address & 0xFFFFFFFF)
        dma.w(S2MM_DA_MSB, 0)
        dma.w(S2MM_LEN, OUT_BYTES)
        dma.w(MM2S_SA, tx.physical_address & 0xFFFFFFFF)
        dma.w(MM2S_SA_MSB, 0)
        dma.w(MM2S_LEN, IN_BYTES)
        dl = t0 + args.timeout
        while time.monotonic() < dl:
            if dma.r(S2MM_SR) & DONE:
                break
            time.sleep(0.0002)
        dt = time.monotonic() - t0

        rx.invalidate()
        out = np.array(rx, dtype=np.int8)
        got = int((out != FILL).sum())
        out.tofile(os.path.join(args.indir, f"out{n}.bin"))
        good = got == OUT_BYTES
        ok_all &= good
        print(f"    {n:3d} {os.path.basename(path):10s}{got:11d}{dt:8.3f}  "
              f"{'OK' if good else '미완'}  "
              f"S2MM=0x{dma.r(S2MM_SR):08x}")

    print(f"\n[6] {'전부 전량 수신' if ok_all else '일부 실패'}")
    tx.freebuffer()
    rx.freebuffer()


if __name__ == "__main__":
    main()
