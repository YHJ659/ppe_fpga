#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_xsa.py — XSA 를 보드에 올리기 전에 5초 만에 검사한다
============================================================
Vivado 는 "적힌 것끼리 앞뒤가 맞는가"만 본다. "적어야 할 걸 다 적었는가"는
검사하지 않는다. 그래서 연결이 빠져도 비트스트림은 정상적으로 나오고,
오히려 배선이 줄어 타이밍과 자원 수치는 더 좋아 보인다.

이 스크립트는 그 사각지대만 골라서 본다.

  1) 미연결 인터페이스 (__NOC__)
  2) 마스터인데 주소 세그먼트가 없는 것 (메모리를 못 봄)
  3) PS 슬레이브 포트(S_AXI_HP*) 활성화 여부
  4) 클럭/리셋이 안 붙은 핀

사용법
  python check_xsa.py ppe_fpga_yoo.xsa
  python check_xsa.py design_1.hwh
"""

import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

# 미연결이어도 정상인 것들 (출력 상태핀, 인터럽트, 여분 포트 등)
BENIGN_SUFFIX = ("_reset_out_n", "interrupt", "ap_ctrl", "_irq")
BENIGN_PATTERN = re.compile(r"M\d\d_AXI$")      # 인터커넥트 여분 마스터 포트


def load_hwh(path):
    path = Path(path)
    if path.suffix == ".hwh":
        return ET.parse(path).getroot(), path.name
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if n.endswith(".hwh")]
        if not names:
            raise SystemExit(f"[!] XSA 안에 .hwh 가 없습니다: {path}")
        # XSA 에는 IP 내부 서브디자인의 .hwh 도 함께 들어 있다
        # (예: SmartConnect 의 switchboard/mmu). PS 가 들어 있는 것이 최상위다.
        best = None
        for n in names:
            with z.open(n) as f:
                root = ET.parse(f).getroot()
            has_ps = any("zynq" in m.attrib.get("MODTYPE", "").lower()
                         for m in root.iter("MODULE"))
            if has_ps:
                return root, n
            if best is None:
                best, best_name = root, n
        print(f"[!] PS 가 있는 .hwh 를 못 찾아 {best_name} 로 진행합니다\n")
        return best, best_name


def main():
    if len(sys.argv) < 2:
        raise SystemExit("사용법: check_xsa.py <xsa 또는 hwh>")
    root, src = load_hwh(sys.argv[1])
    print(f"[검사 대상] {sys.argv[1]}  ({src})\n")

    problems = []

    # ---------------------------------------------- 1) 미연결 인터페이스
    noc = []
    for m in root.iter("MODULE"):
        inst = m.attrib.get("INSTANCE", "")
        for bi in m.iter("BUSINTERFACE"):
            a = bi.attrib
            if a.get("BUSNAME") != "__NOC__":
                continue
            name = a.get("NAME", "")
            benign = (name.endswith(BENIGN_SUFFIX)
                      or BENIGN_PATTERN.search(name)
                      or a.get("TYPE") in ("TARGET", "SLAVE"))
            noc.append((inst, name, a.get("TYPE"), benign))

    print("=== 1) 미연결 인터페이스 ===")
    if not noc:
        print("  없음")
    for inst, name, ty, benign in noc:
        mark = "" if benign else "   <<< 확인 필요"
        print(f"  {inst}.{name} ({ty}){mark}")
        if not benign:
            problems.append(f"{inst}.{name} 미연결 ({ty})")

    # -------------------------------- 2) 주소 세그먼트 없는 마스터 찾기
    # AXI-Stream 마스터(M_AXIS)는 메모리맵이 아니라 주소가 필요 없다.
    # PS 자체의 마스터는 안 쓰면 0개인 게 정상이므로 실패로 치지 않는다.
    masters = set()
    for m in root.iter("MODULE"):
        inst = m.attrib.get("INSTANCE", "")
        is_ps = "zynq" in m.attrib.get("MODTYPE", "").lower()
        for bi in m.iter("BUSINTERFACE"):
            a = bi.attrib
            name = a.get("NAME", "")
            if a.get("TYPE") != "MASTER":
                continue
            if not name.startswith("M_AXI") or name.startswith("M_AXIS"):
                continue
            masters.add((inst, name, is_ps))
    seg_by_master = {}
    for s in root.iter("MEMRANGE"):
        mi = s.attrib.get("MASTERBUSINTERFACE")
        if mi:
            seg_by_master.setdefault(mi, []).append(
                (s.attrib.get("INSTANCE"), s.attrib.get("BASEVALUE"),
                 s.attrib.get("HIGHVALUE")))

    print("\n=== 2) 메모리맵 AXI 마스터별 주소 세그먼트 ===")
    for inst, name, is_ps in sorted(masters):
        segs = seg_by_master.get(name, [])
        if segs:
            print(f"  {inst}.{name}: {len(segs)}개")
            for tgt, lo, hi in sorted(set(segs))[:4]:
                print(f"      -> {tgt} {lo} ~ {hi}")
        elif is_ps:
            print(f"  {inst}.{name}: 0개   (PS 마스터 미사용 — 무해)")
        else:
            print(f"  {inst}.{name}: 0개   <<< 메모리를 볼 수 없음")
            problems.append(f"{inst}.{name} 에 주소 세그먼트 없음")

    # ------------------------------------------- 3) PS 슬레이브 포트 활성화
    print("\n=== 3) PS 슬레이브 포트 (PL -> DDR 통로) ===")
    ps_slaves = []
    for m in root.iter("MODULE"):
        if "zynq" not in m.attrib.get("MODTYPE", "").lower():
            continue
        for bi in m.iter("BUSINTERFACE"):
            a = bi.attrib
            if a.get("NAME", "").startswith("S_AXI"):
                ps_slaves.append((a.get("NAME"), a.get("BUSNAME")))
    if ps_slaves:
        for name, busname in ps_slaves:
            print(f"  {name:22s} {busname}")
    else:
        print("  활성화된 S_AXI_HP*/HPC* 포트 없음   <<< PL 이 DDR 에 접근 불가")
        problems.append("PS 에 슬레이브 포트가 하나도 활성화되지 않음")

    # ------------------------------------------------- 4) 클럭/리셋 미연결
    print("\n=== 4) 클럭/리셋 미연결 핀 ===")
    dangling = []
    for m in root.iter("MODULE"):
        inst = m.attrib.get("INSTANCE", "")
        for p in m.iter("PORT"):
            a = p.attrib
            nm = a.get("NAME", "")
            if a.get("DIR") != "I":
                continue
            if not any(k in nm.lower() for k in ("aclk", "aresetn", "ap_clk",
                                                 "ap_rst")):
                continue
            if a.get("SIGNAME") in (None, "", "None"):
                dangling.append(f"{inst}.{nm}")
    if dangling:
        for d in dangling:
            print(f"  {d}   <<< 미연결")
            problems.append(f"{d} 클럭/리셋 미연결")
    else:
        print("  없음")

    # ------------------------------------------------------------- 판정
    print("\n" + "=" * 60)
    if problems:
        print(f"[실패] 확인이 필요한 항목 {len(problems)}개")
        for p in problems:
            print(f"  - {p}")
        print("\n비트스트림이 정상 생성되었더라도 위 항목은 동작하지 않습니다.")
        return 1
    print("[통과] 구조적 미연결이 발견되지 않았습니다.")
    print("(단, 이 검사는 '빠진 연결'만 봅니다. 데이터패스 교착이나 수치")
    print(" 정확성은 실제 보드 실행으로만 확인됩니다.)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
