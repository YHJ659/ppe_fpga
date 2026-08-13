# PPE Monitoring AI Hardware Accelerator — 프로젝트 인수인계 데이터

작성일: 2026-08-12 (KST)  
조사 기준 작업공간: `/home/sogang/ppe_fpga_ho`  
사용자가 지정한 최종 서버 경로: `/DATA/home/edu004/workspace/ppe_fpga_ho/CODEX_FPGA_MASTER_HANDOFF_20260812.md`

> 중요: 현재 호스트에는 `/DATA`가 없고 SGP1 무인증 SSH도 실패했으므로 이 파일은 우선 로컬 프로젝트 루트에 작성했다. 서버 복사는 확인 필요하다. 이 문서는 기존 설계·소스·자동생성물을 수정하거나 synthesis/implementation을 재실행하지 않고 작성했다. 현재 세션에서 직접 확인할 수 없는 과거 Codex 대화는 본 것으로 취급하지 않았다.

## 조사 범위와 신뢰도 표기

- **확인 완료**: 현재 파일, 로그, report, 현재 대화의 실제 출력으로 확인.
- **팀 저장소 근거**: `/tmp/ppe_fpga_main_20260812`, `/tmp/ppe_fpga_jungwon_20260812`에 읽기 전용으로 조사한 팀 GitHub 작업본 근거. 사용자의 개인 수행 여부와 팀 결과를 구분한다.
- **현재 세션 근거**: 이 대화에 붙여 넣은 터미널/Jupyter/Vivado 출력.
- **추정**: 정황상 가능하지만 원본 로그가 부족함.
- **확인 필요**: 원본 SGP1 또는 다른 Codex 세션을 확인해야 함.

==================================================
## 1. 프로젝트 기본정보
==================================================

- 프로젝트명: **PPE Monitoring AI Hardware Accelerator**.
- 목표: YOLOv8n PPE 탐지의 일부를 Kria KV260 PL에서 가속하고 CPU/FPGA 혼합 추론을 검증.
- Target: Kria KV260 Vision AI Starter Kit, XCK26 계열 Zynq UltraScale+ MPSoC.
- 도구: Ubuntu 22.04, Vivado/Vitis/Vitis HLS **2022.2**, PYNQ, Python/C/C++/HLS C++, Verilog/SystemVerilog 자동생성 RTL.
- AI 모델: YOLOv8n. 로컬에 `models/best.pt`, `models/yolov8n.pt` 존재.
- FPGA 범위: model.6 C2f. 초기 목표는 cv1→bottleneck 2개→concat→cv2였으나, 팀의 최종 검증본 `model6_hw_fix`는 자원 문제로 **cv1부터 concat 출력까지** FPGA에 두고 cv2는 소프트웨어로 이동했다.
- 수치 형식: feature/weight INT8, accumulator INT32, FPGA 입출력 INT8. 최종 팀 런타임 scale은 `S_IN=0.0389917693`, `S_CAT=0.0553356526`.
- CPU/FPGA 분담:
  - CPU: 카메라, letterbox/RGB/NCHW, model.0–5 PRE, 양자화, DMA 제어, FPGA 출력 역양자화, model.7 이후 POST, NMS, 화면 표시.
  - FPGA: model.6의 cv1~concat 구간(팀 최종 검증본). 사용자의 2026-08-09 custom build에는 `conv1x1_cv2_0`와 `bn_silu_128_0`도 BD에 존재하므로 범위가 다르다.

==================================================
## 2. 전체 시스템 구조
==================================================

확인된 팀 최종 실행 경로:

```text
USB Camera/OpenCV
→ letterbox 640×640, BGR→RGB, float32 NCHW
→ CPU PRE (YOLO model.0~5)
→ feature [1,128,40,40] float32
→ q=clip(round(feature/S_IN),-128,127), int8 CHW
→ driver boundary CHW; DMA payload에서 FPGA 요구 HWC로 취급/변환
→ AXI DMA MM2S
→ FPGA model.6 cv1→BN/SiLU→split→2 bottleneck→concat
→ AXI DMA S2MM, raw HWC [40,40,256], 409,600 byte
→ HWC→CHW, float32 = int8×S_CAT
→ CPU POST (cv2 및 model.7~22)
→ prediction [1,14,8400]
→ NMS
→ bounding boxes / PPE 화면
```

| 단계 | 위치 | framework/파일 | shape/type |
|---|---|---|---|
| Camera/letterbox | CPU | OpenCV, `sw/hybrid_pipeline.py` | 640×640 BGR→RGB float32 |
| PRE | CPU | 기존 PyTorch 또는 변경 ORT `pre_model6.onnx` | FPGA 입력 `[1,128,40,40]` float32 |
| Quantize | CPU | `MixedPipelinedPipeline.fpga_stage` | INT8, `S_IN` |
| FPGA | PL | `Model6Fpga`, AXI DMA, HLS IP | 입력 204,800 B; 출력 409,600 B |
| Dequantize | CPU | HWC→CHW, `S_CAT` | `[256,40,40]` float32 |
| POST | CPU | 기존 PyTorch 또는 NCNN | `[1,14,8400]` |
| NMS/display | CPU | Ultralytics Torch NMS/OpenCV | box/class/confidence |

레이아웃 주의: 공개 Python→driver 경계는 CHW라고 코드가 명시하며, DMA에서 받은 raw 출력은 HWC `40×40×256`로 reshape 후 CHW로 transpose한다. 이 계약을 사용자 custom `.bit`에 그대로 적용 가능한지는 확인 필요하다.

==================================================
## 3. 날짜별 작업 타임라인
==================================================

### 2026-07-28

- 요청 기간 시작일이나 현재 로컬 타임스탬프에는 해당 날짜 파일이 없음. **다른 Codex 세션/SGP1 확인 필요**.

### 2026-07-30

- 로컬에서 확인되는 파일 1개. 정확한 작업 의미는 파일별 timestamp 추가 확인 필요.

### 2026-07-31

- 로컬 `ppe_dma_passthrough` Vivado 프로젝트와 Vitis workspace에 대량 생성 흔적(9,626 파일).
- DMA passthrough BD, AXI DMA, SmartConnect, reset, XSA 및 `dma_loopback`, `dma_loopback_v2` 애플리케이션이 존재.
- 이것은 full model.6 이전 DMA 경로 실습/검증 흔적으로 판단되나, 정확한 성공 단계와 콘솔 출력은 확인 필요.

### 2026-08-01 ~ 2026-08-03

- HLS export IP, Vivado/Vitis 파생 파일의 타임스탬프가 이어짐.
- 7종 기능의 IP export `component.xml` 및 ZIP이 로컬에 존재: bn64, bn128, split, concat, residual, conv1x1 cv1/cv2, conv3x3.
- 실제 HLS `csynth.rpt` 원본이 로컬에서 모두 확인된 것은 아니므로 IP별 latency/II 숫자는 확인 필요.

### 2026-08-05

- 로컬 파일 1개 변경 흔적. 구체 내용 확인 필요.

### 2026-08-06 ~ 2026-08-09 — SGP1 full build

- 현재 세션의 Vivado 출력에 따르면 full model.6 BD에서 implementation 및 bitstream 성공.
- 최종 routing: WNS **+0.220 ns**, TNS **0**, WHS **+0.010 ns**, THS **0**; failed/unrouted/partially-routed nets 0, node overlaps 0, DRC error 0.
- `write_bitstream completed successfully`, run status `write_bitstream Complete!`, progress 100%.
- bit size 7,797,812 B. XSA export return 0. 세부 artifact는 9절 참조.
- AVAL-155/156 DSP 미사용 포트 power advisory가 다수 있었지만 bitgen error/critical warning은 0.
- 요청에 언급된 이전 실패값 `66,590 node overlaps`, `WNS -9.210 ns`, LUTLP-1, off_stp/reverse/register_mode의 정확한 날짜별 원본은 현재 로컬에 없어 **SGP1 및 다른 Codex 세션 확인 필요**.

### 2026-08-09 — artifact 이동과 첫 KV260 시도

- SGP1에서 `.bit/.hwh`를 KV260 `192.168.1.56`로 SCP.
- SHA256: bit `17af5790130fa8efd083e9c400f39fb93b585faaa2b43f689f0275b9d41f6085`; hwh `87d74de297dd29277695a2e1aa93c78a46bd86570ccbb2f43cf4f431abbde4f6`.
- PYNQ `Overlay(BIT,download=False)` parse 성공, `overlay.download()` 및 `is_loaded()==True` 확인.
- DMA object/MMIO 접근에서 Jupyter 셀이 `[*]` 상태로 멈춤. kernel restart 수행; 읽기 성공값은 없음.
- 잘못 선택한 보드 `.56`에는 USB webcam이 열거되지 않았다.

### 2026-08-09 이후 — 보드 식별과 webcam

- `arp-scan`으로 여러 Xilinx 보드 중 `.253` 선택. `hostname=kria`, `hostname -I=192.168.1.253`.
- `.253`에서 Logitech C270 (`046d:0825`)와 `/dev/video0`, `/dev/video1` 확인; Jupyter 9090 LISTEN 확인.
- 그러나 `.253`에는 처음에 model6 artifact 및 `.pt/.xmodel`이 없었고 `ultralytics`, `torch`, `onnxruntime`도 없었다.
- `pip install ultralytics` 과정에서 ARM64용 NVIDIA CUDA 관련 대형 wheel 다운로드가 시작되어 복잡도가 커짐. 설치 최종 성공은 확인되지 않음.

### 2026-08-12 — 인수인계 조사

- 설계/코드 변경 없이 로컬 1,496개 디렉터리와 주요 파일, component.xml, Vivado/Vitis 흔적 조사.
- 로컬 `.git`은 정상 저장소가 아니어서 status/log/diff 복원 실패.
- 팀 main/Jungwon 작업본을 `/tmp`에서 읽기 전용 조사해 final verification 및 Hybrid Runtime 구조를 교차 확인.

==================================================
## 4. 내가 실제로 수정하거나 생성한 파일
==================================================

| 경로 | 역할 | 상태 | 주요 내용/현재 사용 | 근거 |
|---|---|---|---|---|
| `Concat/concat_channel.cpp` | concat HLS source | 수정 여부 확인 필요 | 로컬에 존재 | E005 |
| `Concat/tb_concat_channel.cpp` | concat TB | 신규/수정 확인 필요 | local golden binary와 함께 존재 | E005 |
| `Concat/concat_golden_reference.py` | Python golden | 신규/수정 확인 필요 | concat 비교용 | E005 |
| `export/export_*` 및 ZIP 8개 | HLS exported IP | 생성 확인 | Vivado IP catalog 입력 | E003 |
| `ppe_dma_passthrough/` | DMA 최소 Vivado project | 생성 확인 | full model6와 별도 | E006 |
| `vitis_workspace/dma_loopback*` | Vitis DMA test | 생성 확인 | 과거 DMA 실습 | E006 |
| `model6_hardware_summary.md`, `model6_review_request.md` | 설계 검토 문서 | 생성 확인 | 내용/작성 주체 확인 필요 | E005 |
| SGP1 `artifacts/model6_icuf8_20260809/*` | 최종 custom build artifacts | 생성 확인 | bit/hwh/xsa/report/Tcl | E010 |
| `CODEX_FPGA_MASTER_HANDOFF_20260812.md` | 본 인수인계 | 신규 | 현재 사용 | E001 |
| `CODEX_FPGA_EVIDENCE_INDEX_20260812.txt` | 증거 목록 | 신규 | 현재 사용 | E001 |

Git metadata 부재 때문에 “내가 직접 수정”과 “팀원이 만든 파일을 복사”한 것을 파일만으로 완전히 분리할 수 없다. 위 표는 존재/생성 흔적을 기록하며 개인 기여 확정은 별도 인터뷰 또는 SGP1 shell history가 필요하다.

==================================================
## 5. 실제로 사용한 명령어
==================================================

### Linux/네트워크

```bash
ip -br address
ip neigh
ping -c 2 kria.local
ssh ubuntu@kria.local
ssh ubuntu@192.168.1.253
sudo arp-scan --interface=enp3s0 192.168.0.0/23 | grep -Ei '00:0a:35|Xilinx'
hostname
hostname -I
lsusb
lsusb -t
ls -l /dev/video*
sudo dmesg -w
sudo ss -lntp | grep 9090
find /home/ubuntu -type f \( -iname '*.pt' -o -iname '*.xmodel' \)
```

### 파일/검증

```bash
find . -maxdepth 2 -type d | sort
find . -maxdepth 4 -type f | sort
sha256sum /home/ubuntu/work/model6_overlay/ppe_model6_icuf8_20260809.{bit,hwh}
grep -nE 'Overlay|DpuOverlay|bit|xmodel|VideoCapture|imshow' *.py
```

### Artifact 전송

```bash
scp /DATA/home/edu004/workspace/ppe_fpga_ho/artifacts/model6_icuf8_20260809/ppe_model6_icuf8_20260809.bit ubuntu@192.168.1.56:/home/ubuntu/work/model6_overlay/
scp /DATA/home/edu004/workspace/ppe_fpga_ho/artifacts/model6_icuf8_20260809/ppe_model6_icuf8_20260809.hwh ubuntu@192.168.1.56:/home/ubuntu/work/model6_overlay/
```

### PYNQ/Python/MMIO

```python
from pynq import Overlay, MMIO
overlay = Overlay(BIT, download=False)
overlay.download()
overlay.is_loaded()
list(overlay.ip_dict.keys())
dma_mmio = MMIO(0xA00A0000, 0x10000)
dma_mmio.read(0x00)  # 실행 시 Jupyter hang; 성공값 없음
```

### DPU 환경 진단

```bash
sudo -E /usr/local/share/pynq-venv/bin/python3 -c 'from pynq import Device; print(Device.devices)'
command -v xclbinutil
xclbinutil --version
export PATH=/usr/bin:/usr/local/share/pynq-venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/bin
```

Vivado Tcl의 실제 명령은 현재 세션에서 `wait_on_runs`, `get_property STATUS/PROGRESS`, `write_hw_platform -fixed -include_bit`, `write_bd_tcl`, `report_*`, `write_bitstream` 결과가 확인된다. 전체 스크립트 원문은 SGP1 확인 필요.

==================================================
## 6. HLS IP별 작업 이력
==================================================

| IP | 예상/확인 I/O | 인터페이스 근거 | 이력/문제 | 정량 HLS 결과 |
|---|---|---|---|---|
| conv1x1 cv1 | 128×40×40→128×40×40 | AXI-Lite+AXIS+BRAM weight | cv1 전용 export | csynth 확인 필요 |
| conv1x1 cv2 | 256×40×40→128×40×40 | AXI-Lite+AXIS+BRAM | custom build에는 존재; 팀 fix4에서는 SW로 이동 | 확인 필요 |
| conv3x3 | 64×40×40→64×40×40, 3×3 | AXI-Lite+AXIS+BRAM | 동일 IP 재사용/layer_id 구조 | 팀 문서 IP별 LUT 19,476, BRAM72, URAM36; build 버전 확인 필요 |
| bn_silu_64 | INT32 stream→INT8, 64ch | AXI-Lite+AXIS, parameter BRAM | float/DSP와 배치·routing 병목 대상 | csynth 확인 필요 |
| bn_silu_128 | 128ch | AXI-Lite+AXIS, parameter BRAM | slot/call counter 문제 수정 이력(팀 fix4) | 팀 문서 LUT 8,832; 나머지 확인 필요 |
| split_channel | 128→64+64 | AXIS | stream 분기 | 확인 필요 |
| residual_add | 두 64ch input→64ch | AXI-Lite+AXIS | runtime scale | 확인 필요 |
| concat_channel | 4×64→256 | AXI-Lite+5 AXIS | URAM/reshape 및 scale | 팀 개발 문서: latency 512,037, LUT 13,171, DSP0, URAM12, II8인 특정 버전; 현재 custom 버전과 동일 여부 확인 필요 |
| bn128_router | stream routing | custom BD IP | 사용자 custom build에 존재 | HLS report 확인 필요 |
| bottleneck_router | stream routing | custom BD IP | 순차 구조 82 pixel deadlock→DATAFLOW→1600 pixel | E014 |

모든 IP의 top function/VLNV는 `component.xml`에서 복원 가능하지만, 현재 문서에는 임의 수치를 채우지 않았다. OOC XDC와 floating_point 7.1 종속성은 export metadata에서 확인된다.

==================================================
## 7. Vivado Block Design 구성
==================================================

### 사용자 2026-08-09 custom build

Jupyter `ip_dict` 실측 주소:

| IP | Base | Range |
|---|---:|---:|
| conv1x1_cv1_0 | 0xA0000000 | 0x10000 |
| conv1x1_cv2_0 | 0xA0010000 | 0x10000 |
| bn128_router_0 | 0xA0020000 | 0x10000 |
| bottleneck_router_0 | 0xA0030000 | 0x10000 |
| bn_silu_128_0 | 0xA0050000 | 0x10000 |
| bn_silu_64_0 | 0xA0060000 | 0x10000 |
| concat_channel_0 | 0xA0070000 | 0x10000 |
| conv3x3_0 | 0xA0090000 | 0x10000 |
| model6_dma | 0xA00A0000 | 0x10000 |
| residual_add_0 | 0xA00B0000 | 0x10000 |

AXI-Lite register 목록에는 각 HLS CTRL/GIER/IP_IER/IP_ISR와 weight/scale/layer_id가 확인됐다. DMA는 MM2S/S2MM register set을 가졌다. 실제 AXIS net별 연결은 final BD Tcl 원본을 SGP1에서 확인해야 한다.

### 팀 final fix4

주소맵은 concat A0000000, conv3x3 A0010000, bn64 A0020000, residual A0030000, bottleneck_router A0040000, DMA A0050000, bn128 A0070000. 이 주소맵은 위 custom build와 다르므로 driver/bitstream을 혼용하면 안 된다.

공통 구조: Zynq PS, AXI SmartConnect/AXI-Lite control, AXI DMA MM2S/S2MM, AXI4-Stream HLS pipeline, parameter BRAM/BMG, 100 MHz clock/reset. 상세 net은 확인 필요.

==================================================
## 8. Implementation 실패와 해결 과정
==================================================

확인된 수정 전→문제→수정→결과:

1. parameter BRAM byte-address HLS와 BMG word-address 불일치 → depth×4 및 COE stride 4 → parameter mapping 정합.
2. bn128 slot1 stale/call counter와 cv2 제거 후 순서 불일치 → slot0 duplicate → 정상 실행.
3. AXI DMA `c_sg_length_width=14`는 최대 16,383 B로 409,600 B 출력 수신 불가, TLAST 부재로 분할 시 DMAIntErr → width 26 → 409,600 B 일괄 수신.
4. bottleneck router 순차 producer/consumer → 82 pixel에서 교착 → DATAFLOW → 1600 pixel 전량 통과.
5. PS↔PL AFI 폭 설정 불일치 → width correction.
6. DMA driver가 length probe 중 transfer를 시작 → fixed constant와 IOC completion 기반 처리.
7. cv2 포함 시 자원/배치 문제 → 팀 final fix4에서 cv2를 CPU로 이동 → final timing/resource 통과.

다음은 사용자 요청에 등장하지만 현재 원본 근거 부족:

- `66,590 node overlaps`: 확인 필요.
- 최초 WNS `-9.210 ns`: 확인 필요.
- `Failed Timing & Nets`, Blackbox count, LUTLP-1 정확한 값: 확인 필요.
- `off_stp`, `reverse`, `register_mode`, high fanout/congestion 각 실험의 명령·수치·순서: SGP1 및 다른 Codex 세션 확인 필요.

최종 custom build에서는 node overlaps 0, failed/unrouted nets 0, WNS +0.220 ns, DRC error 0로 수렴했다. 이 결과를 위 미확인 중간 실험의 직접 결과로 단정하지 않는다.

==================================================
## 9. 최종 Hardware Build 결과
==================================================

현재 세션에서 확인된 SGP1 custom build:

- Status: `write_bitstream Complete!`, progress 100%.
- Bitgen: `Bitgen Completed Successfully`, `write_bitstream completed successfully`.
- Errors: bitgen 0 Errors, 0 Critical Warnings; DRC 0 Errors, 667 Warnings, 85 Advisories.
- Source bit: `/DATA/home/edu004/workspace/ppe_fpga_ho/ppe_model6_team_latest/ppe_model6_team_latest.runs/impl_1/design_1_wrapper.bit`.
- Artifact dir: `/DATA/home/edu004/workspace/ppe_fpga_ho/artifacts/model6_icuf8_20260809`.
- `ppe_model6_icuf8_20260809.bit`: 7,797,812 B.
- `.hwh`: 1,080,620 B.
- `.xsa`: 6,603,783 B; `XSA_RETURN=0`.
- reports: opt utilization 10,849 B; route status 651 B; timing 25,114 B; DRC 627,071 B.
- BD Tcl backup: `design_1_model6_icuf8_bitstream_success_20260809.tcl`, 63,387 B.
- Timing: WNS +0.220 ns, TNS 0, WHS +0.010 ns, THS 0.

팀 final fix4의 별도 결과: LUT 69,502(59.3%), FF 135,086(57.7%), BRAM 124.5(86.5%), URAM 60(93.8%), DSP 476(38.1%), WNS +0.462 ns, TNS 0. 개발 문서에는 cv2 제거 직후 합성 수치 LUT65,659/FF130,945/BRAM121.5/URAM56/DSP472 및 다른 WNS가 있어 build 버전별 차이로 유지한다.

==================================================
## 10. KV260 보드 검증 및 DMA 문제
==================================================

1. `.bit/.hwh` 복사와 hash 일치 확인.
2. PYNQ parse 및 download 성공; custom `ip_dict`/address 확인.
3. `dma=overlay.model6_dma` 또는 `MMIO(0xA00A0000,0x10000).read(0)` 단계에서 Jupyter `[*]`가 사라지지 않음.
4. kernel restart, ipykernel process 진단 제안. MMIO read 결과값은 얻지 못함.
5. board가 네트워크에서 사라지는 현상과 `.56`/`.253` 보드 혼동을 arp-scan으로 분리.
6. 올바른 `.253`에서 webcam/video device 확인.
7. STEP1/STEP2/STEP3라는 명시적 스크립트 및 각 결과는 현재 자료에서 찾을 수 없음.

해결 상태: bitstream load는 확인, custom DMA/MMIO transfer는 **미해결/검증 미완료**. 팀 fix4에는 `/dev/mem`/PYNQ allocate 방식과 `/dev/model6_dma` kernel driver 방식의 별도 성공 코드가 있으나, 주소맵이 custom bit와 다르므로 그대로 적용하지 않았다.

==================================================
## 11. YOLOv8n Hybrid Runtime
==================================================

### 기존 구조

`sw/hybrid_pipeline.py` 계열: PyTorch PRE → FPGA model.6 → PyTorch POST/NMS. 팀 final `ppe_live.py`는 bitstream을 한 번 로드하고 `/dev/mem`/PYNQ buffer로 DMA를 제어하며 MJPEG browser 또는 OpenCV 경로를 제공한다.

### 변경 구조

`MixedPipelinedPipeline`:

- `pre_stage`: letterbox, RGB/NCHW float32, ORT `pre_model6.onnx` 실행, `feature`와 `skip4` 반환.
- `fpga_stage`: `feature/S_IN` round/clip INT8, `Model6Fpga.run`, raw HWC `[40,40,256]`→CHW, `×S_CAT`.
- `post_stage`: NCNN `post_model6.ncnn.param/bin`, output `(1,14,8400)` 정규화, Ultralytics `non_max_suppression`, letterbox 좌표 복원.
- `Model6Fpga`: Jungwon branch에서는 `/dev/model6_dma` kernel module boundary.
- pipeline worker: FPGA(frame N)를 thread pool에 submit하는 동안 PRE(frame N+1)를 실행. FPGA 완료 후 POST(N). 주석상 POST+FPGA overlap은 benchmark에서 더 느려 의도적으로 겹치지 않음.

확인 필요:

- branch의 NCNN param/bin 실제 배포 완결성.
- `webcam_infer_pipelined_bf16_fp32pre.py`의 import 경로와 파일 배치 정합.
- 실제 `.253` 보드에서 ORT/NCNN/torch 의존성 설치 및 end-to-end 실행 여부.
- 이 runtime은 DMA A0050000 fix4 주소맵을 전제로 하므로 custom DMA A00A0000 bit와 호환되지 않음.

==================================================
## 12. 실패/수정 전후 비교
==================================================

| 수정 전 | 문제 | 수정 | 수정 후 |
|---|---|---|---|
| DMA width 14 | 16KB 부근 부분 수신/DMAIntErr | width 26 | 409,600B 일괄 수신 |
| router 순차 실행 | 82 pixels deadlock | DATAFLOW | 1600 pixels |
| cv2까지 FPGA | 자원/배치 부담 | cv2 SW 이동(팀 fix4) | timing/resource 통과 |
| PYNQ normal user | root permission required | sudo PYNQ venv/-E | Device 인식, 이후 xclbin 문제 |
| sudo system python | `pynq_dpu` 없음 | PYNQ venv 사용 | import 가능 |
| venv xclbinutil PATH 우선 | `t.xclbin` 없음 | `/usr/bin` 우선 | 같은 오류 지속; 미해결 |
| `.56` 보드 | webcam 없음 | arp-scan 후 `.253` 선택 | C270와 video0/1 확인 |
| Jupyter MMIO read | kernel `[*]` hang | kernel restart | hang 해제, read는 재검증 안 함 |
| 단순 pip ultralytics | ARM NVIDIA 대형 wheel | 설치 중단/재검토 | 최종 설치 확인 필요 |

==================================================
## 13. 현재 최종 상태
==================================================

### 완료

- 7종+라우터 HLS IP export 흔적 및 full custom BD integration.
- Validate/synthesis/implementation/route/DRC/bitstream/XSA까지 SGP1 custom build 성공.
- bit/hwh hash와 PYNQ parse/download 확인.
- 팀 final fix4의 model.6 기능/정확도/성능 검증 자료 존재.

### 부분 완료

- 올바른 KV260 `.253`와 webcam 인식.
- Hybrid runtime 코드와 ORT/NCNN pipeline 구조.

### 미해결

- 사용자 custom bit의 DMA/MMIO hang 및 실제 feature round trip.
- custom bit로 실시간 YOLO webcam end-to-end 실행.
- `.253`에 정확한 bit/hwh/runtime/model/dependency 세트 배포.
- 이전 implementation 실패들의 원본 수치/로그 복원.
- 정상 Git history 복원.

### 다음 작업(실행하지 않음)

1. SGP1 로그/리포트와 과거 Codex transcript 확보.
2. custom bit 주소맵에 맞춘 DMA driver 계약 검증.
3. known-good 팀 fix4 전체 artifact/runtime을 동일 보드에 한 세트로 배포.
4. camera→runtime→display 단일 명령 end-to-end 재현 및 FPS 기록.

==================================================
## 14. 포트폴리오용 실제 경험 원자료
==================================================

- Vitis HLS custom IP를 export하고 Vivado IP Integrator에서 AXIS/AXI-Lite/BRAM/DMA 기반 model.6 가속 블록을 통합한 작업 흔적.
- placement/routing 실패와 timing/congestion을 반복 분석하고 최종 custom build WNS +0.220 ns, DRC error 0, bitstream/XSA 생성까지 확인.
- 7.8MB bitstream과 1.08MB HWH, 6.60MB XSA를 artifact로 패키징하고 hash로 보드 전송 무결성 확인.
- PYNQ에서 HWH address map을 읽고 overlay load를 검증했으며 MMIO hang을 kernel/Jupyter/board/network 층으로 분리해 진단.
- 여러 KV260가 같은 LAN에 있는 환경에서 arp-scan/MAC/USB 장치로 올바른 보드를 식별.
- 팀 검증에서 router deadlock 82→1600 pixel, DMA length 14→26 bit, detection 90건 중 88건(97.8%), feature correlation 0.999를 근거로 HW/SW 정합을 확인.
- 성능 측정에서 전체 1.265s(0.79FPS), FPGA model.6 0.055s, SW model.6 0.077s로 model.6 단독 가속의 Amdahl 한계를 분석.
- PyTorch 중심 Hybrid에서 ORT PRE + FPGA + NCNN POST 및 PRE/FPGA overlap 구조를 조사하고 tensor layout/scale/address-map 호환 위험을 구분.

개인 수행과 팀 공통 결과는 면접 자료 작성 시 반드시 구분해야 한다. 팀 저장소 수치를 개인이 단독 달성했다고 표현할 근거는 현재 없음.

==================================================
## 15. 증거 인덱스
==================================================

상세 목록은 `CODEX_FPGA_EVIDENCE_INDEX_20260812.txt` 참조.

- E001: 현재 조사 명령과 생성 문서.
- E002: `AGENTS.md` 프로젝트 요구와 환경.
- E003: `export/*/component.xml` 실제 IP interface/VLNV metadata.
- E004: `ppe_dma_passthrough` Vivado logs/reports/XSA.
- E005: local HLS/TB/golden/model files.
- E006: Vitis workspace DMA applications/platforms.
- E007: current-session Vivado final output.
- E008: current-session KV260/PYNQ/Jupyter output.
- E009: current-session network/webcam output.
- E010: SGP1 artifact paths/sizes/hash output.
- E011: team `model6_hw_fix/README.md`.
- E012: team `results/verification.md`.
- E013: team `docs/성능_분석.md`.
- E014: team `docs/일일보고_3일.md`.
- E015: team `ppe_fpga_final/model6_c2f_구현_정리.md`.
- E016: Jungwon Hybrid runtime Python/driver.

## 복원 한계

현재 Codex 세션만으로 과거 작업 전부를 복원하지 못했다. 특히 `/DATA` SGP1 원본, 정상 Git history, 과거 Codex 대화, 66,590 overlaps/-9.210ns/off_stp/reverse/register_mode 실험 원본은 **다른 Codex 세션 및 SGP1 확인 필요**다.
