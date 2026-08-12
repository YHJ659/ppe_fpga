#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_model6.py — model.6 하드웨어 실행 (AFI_FS 교정 포함)
========================================================
오늘 확인된 두 가지를 반영한 최종 실행기.

1) PS 마스터 포트 폭 교정
   팀 XSA 의 psu_init 은 FPD_SLCR.AFI_FS(0xFD615000) 를 0xA00 으로 설정한다
   (HPM0/HPM1 = 128bit). 이 코드는 부팅 시 FSBL 이 실행하는데, PYNQ 로
   .bit 만 갈아끼우면 적용되지 않아 PS 는 32bit 인 채로 남는다.
   그러면 주소 % 16 != 0 인 레지스터 쓰기가 조용히 버려진다.
   -> DMA 의 SA/LENGTH 를 못 써서 전송 자체가 불가능했다.

2) MMIO 는 ctypes 단일 32비트 스토어로
   (PYNQ MMIO / mmap 슬라이스도 동작은 같았으나 의도를 명확히 하기 위함)

주의: DMA 의 C_SG_LENGTH_WIDTH 를 확인해 한 번에 보낼 수 있는 최대 크기를
넘지 않도록 나눠 보낸다.
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

import numpy as np  # noqa: E402

AFI_FS = 0xFD615000
AFI_FS_MASK, AFI_FS_WANT = 0x00000F00, 0x00000A00

BASE = {"concat": 0xA0000000, "conv3x3": 0xA0010000, "bn_silu64": 0xA0020000,
        "residual": 0xA0030000, "bneck_rt": 0xA0040000, "bn128": 0xA0070000}
DMA = 0xA0050000
AP_CTRL, AP_IDLE, AP_START, AUTO_RESTART = 0x00, 1 << 2, 1 << 0, 1 << 7
CONCAT_OFF = {"scale0": 0x10, "scale1": 0x18, "scale2": 0x20,
              "scale3": 0x28, "output_scale": 0x30}

MM2S_CR, MM2S_SR, MM2S_SA, MM2S_SA_MSB, MM2S_LEN = 0x00, 0x04, 0x18, 0x1C, 0x28
S2MM_CR, S2MM_SR, S2MM_DA, S2MM_DA_MSB, S2MM_LEN = 0x30, 0x34, 0x48, 0x4C, 0x58

# 전송 완료 판정: Idle(bit1) 또는 IOC(bit12).
# HLS 스트림에 TLAST 가 없어서 S2MM 은 지정 길이를 다 받고도 스트림이 계속
# 흐르는 것으로 보고 Idle 로 가지 않는다 (DMAIntErr 를 세우고 halt 한다).
# 하지만 IOC 는 요청한 바이트를 다 쓴 시점에 정확히 선다. Idle 만 기다리면
# 데이터가 이미 다 왔는데도 타임아웃까지 그냥 서 있게 된다.
DONE = 0x2 | (1 << 12)
IN_BYTES, OUT_BYTES = 128 * 40 * 40, 256 * 40 * 40


class Raw:
    def __init__(self, base, size=0x10000):
        self.page = base & ~0xFFF
        self.delta = base - self.page
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, size + self.delta, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=self.page)
        self.buf = ctypes.c_char.from_buffer(self.mm)
        self.addr = ctypes.addressof(self.buf) + self.delta

    def r(self, off):
        return ctypes.c_uint32.from_address(self.addr + off).value

    def w(self, off, val):
        ctypes.c_uint32.from_address(self.addr + off).value = val & 0xFFFFFFFF


def f32(v):
    return struct.unpack("<I", struct.pack("<f", float(v)))[0]


def sr(v):
    n = [(0, "halted"), (1, "idle"), (4, "IntErr"), (5, "SlvErr"), (6, "DecErr")]
    on = [x for b, x in n if v >> b & 1]
    return f"0x{v:08x} [{' '.join(on) if on else '-'}]"


# PL -> PS 슬레이브 포트(HP0)의 폭은 AFI_FS 가 아니라 AFIFM2 가 관장한다.
# 이쪽이 어긋나면 DDR 쓰기가 16바이트마다 4바이트만 들어간다.
AFIFM_HP0 = 0xFD380000
AFIFM_RDCTRL, AFIFM_WRCTRL = 0x00, 0x14
WIDTH_CODE = {128: 0, 64: 1, 32: 2}


def fix_afi(hp0_width=32):
    a = Raw(AFI_FS, 0x1000)
    before = a.r(0)
    a.w(0, (before & ~AFI_FS_MASK) | AFI_FS_WANT)
    print(f"[AFI_FS ] 0x{before:08X} -> 0x{a.r(0):08X}   "
          f"(HPM0/HPM1 = PS->PL 마스터, 128bit)")

    code = WIDTH_CODE[hp0_width]
    f = Raw(AFIFM_HP0, 0x1000)
    b_rd, b_wr = f.r(AFIFM_RDCTRL), f.r(AFIFM_WRCTRL)
    f.w(AFIFM_RDCTRL, (b_rd & ~0x3) | code)
    f.w(AFIFM_WRCTRL, (b_wr & ~0x3) | code)
    inv = {v: k for k, v in WIDTH_CODE.items()}
    print(f"[AFIFM2 ] RD 0x{b_rd:08X}->0x{f.r(AFIFM_RDCTRL):08X}  "
          f"WR 0x{b_wr:08X}->0x{f.r(AFIFM_WRCTRL):08X}   "
          f"(HP0 = PL->PS 슬레이브, {inv[f.r(AFIFM_RDCTRL) & 3]}bit)")


# 한 번에 보낼 수 있는 최대 바이트 수.
#
# 절대 레지스터를 써보며 알아내면 안 된다. AXI DMA 는 LENGTH 에 0 이 아닌 값을
# 쓰는 것 자체가 "전송 시작" 명령이다 (PG021). 주소를 넣기 전에 한도를 떠보면
# 주소 0 에서 긁은 쓰레기가 회로로 밀려 들어가고, 그 길이가 128 의 배수가
# 아니면 이후 모든 픽셀의 채널이 밀린다.
#
# C_SG_LENGTH_WIDTH = 14 이므로 한도는 2^14-1 = 16383.
# 그 아래에서 픽셀 경계에 맞춰 자른다. 조각 끝에는 TLAST 가 붙고 폭 변환기가
# 거기서 1024비트 단어를 끊으므로, 조각 크기는 반드시 픽셀 크기의 배수여야 한다.
# 빌드에서 c_sg_length_width = 26 으로 올렸다 (기본 14 였다).
# 14 였을 때는 한 번에 16383 B 뿐이라 나눠 보내야 했는데, HLS 스트림에
# TLAST 가 없어서 S2MM 은 첫 조각 뒤 DMAIntErr 로 멈춰버린다. 나눠 받기가
# 원리상 불가능하므로 한 번에 받는 폭을 확보한 것이다.
LEN_LIMIT = (1 << 26) - 1
IN_PIX_BYTES, OUT_PIX_BYTES = 128, 256
IN_CHUNK = LEN_LIMIT // IN_PIX_BYTES * IN_PIX_BYTES
OUT_CHUNK = LEN_LIMIT // OUT_PIX_BYTES * OUT_PIX_BYTES


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bitfile", default="hw/ppe_fpga_yoo_2.bit")
    ap.add_argument("--calib", default="calib_out/calib_params.json")
    ap.add_argument("--input", default="hw_input.bin")
    ap.add_argument("--output", default="hw_output.bin")
    ap.add_argument("--timeout", type=float, default=10.0)
    args = ap.parse_args()

    calib = json.load(open(args.calib))
    payload = np.fromfile(args.input, dtype=np.int8)
    assert payload.size == IN_BYTES, payload.size

    from pynq import Bitstream, allocate
    print(f"[1] 비트스트림 로드 {args.bitfile}")
    Bitstream(args.bitfile).download()

    print("[2] PS 마스터 포트 폭 교정")
    fix_afi()

    ip = {n: Raw(a) for n, a in BASE.items()}
    print("\n[3] concat 스칼라 5개 write + 읽기 확인")
    sc = next(s for s in calib["param_sets"] if s["ip"] == "concat_channel")
    for k, off in CONCAT_OFF.items():
        ip["concat"].w(off, f32(sc[k]))
    bad = [k for k, off in CONCAT_OFF.items()
           if ip["concat"].r(off) != f32(sc[k])]
    for k, off in CONCAT_OFF.items():
        print(f"    {k:13s} @{off:#04x} = 0x{ip['concat'].r(off):08x} "
              f"({sc[k]:.10f})")
    if bad:
        print(f"    [!] 반영 안 된 것: {bad}")
        return
    print("    5개 전부 반영됨")

    print("\n[4] Auto Restart + ap_start")
    for n, m in ip.items():
        m.w(AP_CTRL, AUTO_RESTART | AP_START)
    time.sleep(0.02)
    for n, m in ip.items():
        print(f"    {n:10s} 0x{m.r(AP_CTRL):04x}")

    dma = Raw(DMA)
    dma.w(MM2S_CR, 4)
    time.sleep(0.05)
    dma.w(MM2S_CR, 1)
    dma.w(S2MM_CR, 1)
    time.sleep(0.02)
    print(f"\n[5] DMA 준비  한도 {LEN_LIMIT} B "
          f"-> 입력 {IN_CHUNK} B({IN_CHUNK // IN_PIX_BYTES}픽셀) "
          f"/ 출력 {OUT_CHUNK} B({OUT_CHUNK // OUT_PIX_BYTES}픽셀) 씩")

    tx = allocate(shape=(IN_BYTES,), dtype=np.int8)
    rx = allocate(shape=(OUT_BYTES,), dtype=np.int8)
    tx[:] = payload
    rx[:] = np.int8(-86)
    tx.flush()
    rx.flush()

    chunks_in = [(o, min(IN_CHUNK, IN_BYTES - o))
                 for o in range(0, IN_BYTES, IN_CHUNK)]
    chunks_out = [(o, min(OUT_CHUNK, OUT_BYTES - o))
                  for o in range(0, OUT_BYTES, OUT_CHUNK)]
    assert all(n % IN_PIX_BYTES == 0 for _, n in chunks_in)
    assert all(n % OUT_PIX_BYTES == 0 for _, n in chunks_out)
    print(f"    입력 {len(chunks_in)}조각, 출력 {len(chunks_out)}조각 "
          f"(모두 픽셀 경계에 맞음)")

    # 입력을 다 밀어넣은 뒤에 출력을 받으면 회로 안이 가득 차서 멈춘다.
    # 수신 자리를 늘 하나 걸어둔 채로 송신을 이어간다.
    start = time.monotonic()
    ii = oi = 0
    tx_busy = rx_armed = False
    dl = start + args.timeout
    while oi < len(chunks_out) and time.monotonic() < dl:
        moved = False
        if not rx_armed:
            o, n = chunks_out[oi]
            dma.w(S2MM_DA, (rx.physical_address + o) & 0xFFFFFFFF)
            dma.w(S2MM_DA_MSB, 0)
            dma.w(S2MM_LEN, n)
            rx_armed, moved = True, True
        if not tx_busy and ii < len(chunks_in):
            o, n = chunks_in[ii]
            dma.w(MM2S_SA, (tx.physical_address + o) & 0xFFFFFFFF)
            dma.w(MM2S_SA_MSB, 0)
            dma.w(MM2S_LEN, n)
            tx_busy, moved = True, True
        if tx_busy and dma.r(MM2S_SR) & DONE:
            ii, tx_busy, moved = ii + 1, False, True
        if rx_armed and dma.r(S2MM_SR) & DONE:
            oi, rx_armed, moved = oi + 1, False, True
        if moved:
            dl = time.monotonic() + args.timeout
        else:
            time.sleep(0.0002)

    ok = oi == len(chunks_out)
    if not ok:
        print(f"    [!] 입력 {ii}/{len(chunks_in)} 조각, "
              f"출력 {oi}/{len(chunks_out)} 조각에서 멈춤")
        print(f"        MM2S={sr(dma.r(MM2S_SR))}  S2MM={sr(dma.r(S2MM_SR))}")

    elapsed = time.monotonic() - start
    rx.invalidate()
    out = np.array(rx, dtype=np.int8)
    changed = int((out != np.int8(-86)).sum())

    print(f"\n[6] {elapsed:.3f}s   MM2S={sr(dma.r(MM2S_SR))}  "
          f"S2MM={sr(dma.r(S2MM_SR))}")
    print(f"    수신 버퍼 변화 {changed} / {OUT_BYTES} B")
    if dma.r(S2MM_SR) & (1 << 4) and changed <= (1 << 14):
        print("    [!] S2MM 이 16 KB 언저리에서 DMAIntErr 로 멈췄다. 이 비트스트림은"
              " c_sg_length_width 가 14 인 옛 것일 가능성이 높다.")
        print("        LENGTH 레지스터가 14비트면 큰 값을 써도 잘려서 들어간다.")
    for n, m in ip.items():
        v = m.r(AP_CTRL)
        print(f"    {n:10s} 0x{v:04x} idle={1 if v & AP_IDLE else 0}")

    if changed:
        out.tofile(args.output)
        print(f"\n[OK] {args.output} 저장 "
              f"(비영 {int((out != 0).sum())} B, {changed / OUT_BYTES * 100:.1f}% 변화)")
    else:
        print("\n[!] 데이터가 오지 않음")
    tx.freebuffer()
    rx.freebuffer()


if __name__ == "__main__":
    main()
