# FPGA 프로젝트 대화형 명령 수행 이력

작성 기준일: 2026-08-12  
조사 범위: 로컬 저장소, 로컬 Bash history, Vivado journal/log/report, Vitis workspace metadata/build log, 현재 Codex transcript에서 사용자가 재전달한 KV260/Jupyter 출력  
주의: 이 문서는 기존 소스나 자동 생성물을 수정하거나 빌드를 재실행하지 않고 작성했다.

## 증거 등급과 검증 상태

- `[A]`: 로그·저널·노트북에서 명령과 결과를 직접 확인
- `[B]`: 명령은 확인했지만 결과 일부가 없음
- `[C]`: 현재 Codex transcript에서 실행 지시와 사용자가 붙여넣은 결과로 확인
- `[D]`: Codex가 제안했으나 실행 여부 확인 불가
- `[E]`: 팀 자료에만 존재하여 사용자 개인 수행 여부 확인 불가
- `[VERIFIED_MANUAL_ACTION]`: 사용자 입력 또는 사용자가 시작한 도구 동작과 결과가 교차 확인됨
- `[SUGGESTED_NOT_VERIFIED]`: 제안 흔적만 있고 실제 실행 근거가 없음
- `[MANUAL_ACTION_FROM_LOG]`: transcript에는 없으나 로그·history에서 확인됨

## 조사 결과 요약

| 항목 | 확인 결과 |
|---|---:|
| 검증된 수동 행동 그룹 | 30 |
| 제안됐으나 실행 미확인 그룹 | 8 |
| Vivado journal 명령 레코드 | 281 |
| Vitis HLS console 명령 | 0 — 로컬 `vitis_hls.log`에는 banner만 존재 |
| 프로젝트 관련 Bash history 항목 | 138 |
| transcript로 복원한 Jupyter 논리 셀 그룹 | 8 |
| 확인 가능한 날짜 범위 | 2026-07-31 ~ 2026-08-12 |

Vivado의 281개 레코드에는 사용자가 Tcl Console에서 입력한 명령뿐 아니라 GUI가 journal에 기록한 `startgroup/endgroup` 및 자동 생성 명령도 포함된다. 개별 레코드를 모두 개인 타이핑으로 주장하지 않는다.

## 2026-07-31 — HLS 소스·IP 조사

환경: 일반 Ubuntu shell  
근거: `/home/sogang/.bash_history` 1276행 이후, timestamp 미저장

`[B][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

실행 흔적:

```bash
vitis_hls
find . -type f \( -name "bn_silu_64.cpp" -o -name "bn_silu_128.cpp" \)
cat -n /home/sogang/ppe_fpga_ho/BatchNorm/bn_silu_64.cpp | grep -A 15 "void bn_silu"
find . -type f \( -name "residual_add.cpp" -o -name "split_channel.cpp" \)
find /home/sogang/ppe_fpga_ho -type f -path "*/impl/ip/*.zip"
```

목적: BN/SiLU, residual, split, conv3x3 HLS 소스와 export IP 위치 확인.

오류와 수정:

```text
cat -n [residual_add 파일 경로] ...
cat -n [split_channel 파일 경로] ...
```

대괄호 placeholder를 그대로 입력한 뒤 실제 절대경로를 사용해 재실행한 흔적이 있다. 또한 `vitis hls`를 실행한 뒤 `vitis_hls`로 수정했다.

결론: HLS 도구 실행과 shell 기반 소스/IP 조사는 확인되지만, `vitis_hls>` 또는 `vitis_hls%` 내부의 `open_project`, `csynth_design` 등은 로컬 로그에서 복원되지 않았다.

## 2026-07-31 — Vivado DMA passthrough 최소 설계

환경: Vivado 2022.2 Tcl Console/GUI  
근거: `vivado_6955.backup.jou`, `vivado_6955.backup.log`  
프로젝트: `ppe_dma_passthrough`

### 프로젝트와 Block Design 생성

`[A][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

확인된 흐름:

```tcl
create_project ppe_dma_passthrough ... -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property ip_repo_paths ... [current_project]
update_ip_catalog
create_bd_design design_1
```

BD에는 Zynq UltraScale+ MPSoC, AXI DMA, HLS `axis_passthrough`, Processor System Reset, SmartConnect가 생성됐다. DMA는 simple mode로 구성됐고 MM2S → HLS passthrough → S2MM 스트림 경로가 연결됐다.

### Clock/Reset와 Tcl 입력 오류

`[A][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

보존할 실패 사례:

```tcl
get_bd_intf_pins axis_passthrough_0/
output_stream
```

결과: 첫 명령은 pin을 찾지 못했고, 둘째 줄은 `invalid command name "output_stream"`.

```tcl
connect_bd_net [pl_clk0]
```

결과: 연결할 pin이 두 개 이상 필요하다는 오류.

```tcl
get_bd_pinszynq_ultra_ps_e_0/pl_clk0
```

결과: `invalid command name`.

그 다음 `set clk_src`, `set clk_dst`, `connect_bd_net` 방식으로 수정했고 이미 연결된 net은 조회 후 누락 clock만 연결했다.

### Validate Design 실패와 수정

`[A][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

초기 `validate_bd_design`은 다음 문제를 보고했다.

- DMA control address 미할당
- `/axi_dma_0/m_axi_mm2s_aclk` clock 미연결/부적합
- `/smartconnect_0/aclk` clock 미연결

clock 연결과 `assign_bd_address` 수행 뒤 다시 validate했다. 이 과정은 GUI/Tcl journal에서 명령과 결과가 함께 확인된다.

### Synthesis, blackbox, timing 확인

`[A][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

확인된 명령군:

```tcl
launch_runs synth_1
wait_on_run synth_1
open_run synth_1
get_cells -hier -filter {IS_BLACKBOX == 1}
report_utilization
report_timing_summary
report_drc
check_timing
```

결과:

- 계층 synthesis 중간 보고에는 7개 module black box가 표시됐지만, 최종 synthesized design에서 `get_cells ... IS_BLACKBOX == 1`은 일치 cell이 없었다. 따라서 이 DMA passthrough 설계의 최종 design-level blackbox는 0으로 확인된다.
- Synthesis timing: WNS `+7.270 ns`, TNS `0`; hold는 WHS `-0.082 ns`, THS `-353.106 ns`, hold failing endpoints `10,326`으로 constraints 미충족.
- 이 수치는 전체 model.6 implementation 결과가 아니라 DMA passthrough 최소 설계 결과다.

### Implementation, route, bitstream, XSA

`[A][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

확인된 흐름:

```tcl
launch_runs impl_1 -to_step route_design
wait_on_run impl_1
open_run impl_1
report_route_status
report_timing_summary
launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1
write_hw_platform ...
write_bd_tcl -force ...
```

route 초기 상태에는 failed nets `9,183`(unrouted `8,206`, partial `977`)이 기록됐지만 최종 route는 failed/unrouted/partial/overlap이 모두 0이었다. 다른 재시도에서는 초기 failed nets `9,180` 후 최종 0이었다.

최종 routed timing:

- WNS `+5.904 ns`
- TNS `0`
- WHS `+0.010 ns`
- THS `0`
- timing constraints 충족

Bitgen은 오류 0, `write_bitstream completed successfully`, run status `Complete`, progress `100%`로 확인된다. 이후 hardware platform/XSA와 BD Tcl 백업 작성 흔적도 있다.

주의: 사용자 예시의 `pen_run impl_1` → `open_run impl_1` 오타는 로컬 journal/history에서 발견되지 않았다. 반면 `targets -set ...`을 Vivado에 입력해 `invalid command name "targets"`가 난 잘못된-console 사례는 확인됐다.

## 2026-07-31 — Vitis application build 및 Run/Debug

환경: Vitis IDE/XSCT 자동 실행  
근거: `vitis_workspace/.metadata/.log`, application build logs

### 최초 DMA application build 실패

`[A][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

`dma_loopback` Debug build가 15:16:45에 다음 오류로 실패했다.

```text
fatal error: xparameters.h: No such file or directory
```

### v2 build 성공

`[A][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

`dma_loopback_v2` build는 15:34:21에 성공했고 ELF size는 다음과 같다.

```text
text 48176, data 4232, bss 22820, total 75228
```

### Hardware Run/Debug

`[A][MANUAL_ACTION_FROM_LOG][VERIFIED_MANUAL_ACTION]`

15:35:43~15:35:54에 IDE Run/Debugger가 생성한 XSCT sequence가 기록됐다.

```tcl
connect -url tcp:127.0.0.1:3121
targets ...
fpga -file ...bit
loadhw -hw ...xsa
rst -processor
dow ...fsbl.elf
con
dow ...dma_loopback_v2.elf
con
```

Xilinx cable과 XCK26 target 인식, FPGA program, XSA load, FSBL 및 application ELF download는 성공했다. 다만 UART의 최종 DMA `PASS` 출력은 발견되지 않았으므로 보드 프로그램 전달까지는 A, DMA 기능 완료는 확인 필요다. XSCT 명령은 사용자가 한 줄씩 직접 입력했다기보다 사용자가 시작한 IDE Run/Debug가 자동 실행한 것으로 분류한다.

## 날짜 확인 불가 — 서버 전송, 터널, 보드 탐색

환경: 일반 shell/SSH  
근거: `.bash_history`(timestamp 없음), 현재 transcript

`[B/C][VERIFIED_MANUAL_ACTION]`

확인된 명령 예:

```bash
ssh -Y -R 3121:localhost:3121 edu004@192.168.0.51
rsync -av ~/ppe_fpga_ho/export/ edu004@192.168.0.51:/DATA/home/edu004/workspace/ppe_fpga_ho/ip_repo_v2/
ping -c 2 192.168.1.56
ip neigh
sudo arp-scan --interface=enp3s0 192.168.0.0/23
ssh ubuntu@192.168.1.253
```

보드 IP가 `.56`과 `.253` 사이에서 혼동됐고 ARP scan으로 Xilinx 장치를 확인한 뒤 `.253`에 SSH 접속해 `hostname -I`가 `192.168.1.253`임을 확인했다.

오류 보존:

- `cd /ppe_fpga_ho` 실패 후 올바른 프로젝트 디렉터리로 이동
- `~/cd`, `/cd`, `cd~`, `/cd~`, `/~cd` 등 잘못된 shell 입력
- `scp ... ubuntu@192.168.1.253`에서 destination colon 누락 후 `ubuntu@...:/home/...`로 수정
- KV260에서 SGP1 hostname을 resolve하지 못해 pull 방식 SCP 실패, SGP1에서 KV260 IP로 push 방식 전송

## 2026-08-09 transcript — KV260 카메라·DPU 환경 조사

환경: `ubuntu@kria` SSH shell  
근거: 현재 Codex transcript에 사용자가 붙여넣은 출력

`[C][VERIFIED_MANUAL_ACTION]`

실행 및 결과:

```bash
lsusb
ls -l /dev/video*
```

KV260 `.253`에서 Logitech C270(`046d:0825`)과 `/dev/video0`, `/dev/video1`이 확인됐다.

다른 KV260 `.56`에서는 mouse/keyboard만 보이고 `/dev/video*`가 없었다. 이는 서로 다른 보드를 혼동했던 원인을 설명한다.

DPU 관련 조사에서는 `pynq_dpu`, `xir`, `vart` import 가능 여부, `.xmodel`, 기존 `yolo_dpu.bit/.hwh`, Python 스크립트 위치를 확인했다. 이후 root 권한, Python 환경, XRT device, `xclbinutil` 경로 문제를 순차 확인했다.

## 2026-08-09 transcript — Jupyter/PYNQ model.6 overlay

환경: KV260 Jupyter Notebook  
근거: 현재 transcript의 셀 코드와 출력. 실제 `.ipynb` 파일은 로컬에서 발견되지 않음.

### 파일과 HWH parse

`[C][VERIFIED_MANUAL_ACTION]`

```python
from pathlib import Path
BIT="/home/ubuntu/work/model6_overlay/ppe_model6_icuf8_20260809.bit"
HWH="/home/ubuntu/work/model6_overlay/ppe_model6_icuf8_20260809.hwh"
print(Path(BIT).exists())
print(Path(HWH).exists())
```

출력: 모두 `True`.

```python
from pynq import Overlay
overlay=Overlay(BIT,download=False)
print(list(overlay.ip_dict.keys()))
```

출력에는 `conv1x1_cv1_0`, `conv1x1_cv2_0`, `bn128_router_0`, `bottleneck_router_0`, `bn_silu_128_0`, `bn_silu_64_0`, `concat_channel_0`, `conv3x3_0`, `model6_dma`, `residual_add_0`, `zynq_ultra_ps_e_0`가 포함됐다.

### bitstream download

`[C][VERIFIED_MANUAL_ACTION]`

```python
overlay.download()
print(overlay.is_loaded())
```

출력: `True`, `MODEL6_BITSTREAM_LOADED`.

IP 주소와 register 목록도 출력됐고 `model6_dma` base address는 `0xA00A0000`, range는 `0x10000`이었다.

### DMA 객체/MMIO hang

`[C][VERIFIED_MANUAL_ACTION]`

```python
dma=overlay.model6_dma
print(dma)
print("SEND:",dma.sendchannel)
print("RECV:",dma.recvchannel)
```

그리고 새 kernel에서:

```python
dma_mmio=MMIO(0xA00A0000,0x10000)
print(hex(dma_mmio.read(0x00)))
```

두 흐름 모두 Jupyter 셀이 `[*]`에서 끝나지 않는 현상으로 보고됐고 kernel interrupt/restart를 수행했다. 정확한 kernel stack trace는 없으므로 AXI 접근 hang의 근본 원인은 미확정이다.

## 2026-08-09 transcript — PYNQ-DPU overlay 오류

`[C][VERIFIED_MANUAL_ACTION]`

실패 순서:

1. 일반 사용자 Python: `DpuOverlay(...)`에서 `OSError: Root permissions required.`
2. `sudo -E python3`: `ModuleNotFoundError: No module named 'pynq_dpu'`
3. PYNQ venv 절대경로 사용: 한 시도에서 `No Devices Found`
4. `sudo -E ... -c 'from pynq import Device; print(Device.devices)'`: EmbeddedDevice 1개 확인
5. 다시 `DpuOverlay`: 임시 `t.xclbin`이 생성되지 않아 `FileNotFoundError`
6. PATH에서 `/usr/bin/xclbinutil`을 앞세웠으나 동일 계열 문제 지속

이는 “bitstream 생성 성공”과 “PYNQ-DPU가 해당 bit/hwh를 곧바로 사용할 수 있음”이 별개임을 실제 오류로 확인한 과정이다.

## 기존 MASTER_HANDOFF에서 새로 확인된 항목

- DMA passthrough 최종 synthesized design의 blackbox count: `0`으로 확인. 전체 model.6에는 적용 불가.
- DMA passthrough 최종 route: failed/unrouted/partial/overlap 모두 0.
- DMA passthrough routed timing: WNS `+5.904 ns`, WHS `+0.010 ns`, timing met.
- DMA passthrough bitstream: write_bitstream 성공과 run Complete 확인.
- Vitis `dma_loopback_v2`: build 및 FPGA/FSBL/application download 성공. UART 기능 결과는 미확인.
- model.6 Jupyter: HWH parse, `overlay.download()`, `is_loaded=True`, IP dictionary와 DMA base address 확인.
- `dma_mmio.read(0x00)` 및 DMA object 접근 시 Jupyter hang과 restart 수행 확인.
- KV260 `.253`: Logitech C270과 `/dev/video0`, `/dev/video1` 확인.

## 아직 확인하지 못한 핵심 항목

- `66,590 node overlaps`, WNS `-9.210 ns`, `LUTLP-1`, full model.6 router failure의 원문은 로컬에 없음.
- BN64/BN128의 `off_stp`, `in_reverse_stp`, `register_mode` HLS interactive 실험 명령과 결과.
- SGP1 `/DATA/home/edu004/workspace/ppe_fpga_ho` 원격 로그. 비대화형 SSH 인증이 거부돼 조사하지 못함.
- 다른 Codex 세션의 transcript.
- Jupyter 원본 `.ipynb`와 IPython `history.sqlite`.
- DMA application의 UART PASS/FAIL 출력과 실시간 YOLO 최종 실행 화면/FPS.

