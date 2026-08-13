# FPGA 프로젝트 문제해결 경험 전수조사

작성일: 2026-08-12  
목적: 자기소개서·면접용 실제 문제해결 원자료 발굴  
조사 방식: 기존 CODEX 문서와 Vivado/Vitis 원본 로그·report·source·현재 transcript를 읽기 전용 교차검증. Build는 재실행하지 않음.

## 증거·기여 구분

- **A**: 원본 log/report/source에서 명령과 결과 확인
- **B**: 명령/파일은 확인되나 결과 일부 미확인
- **C**: 현재 transcript에 사용자가 직접 붙여넣은 명령과 출력
- **E**: 팀 저장소 결과. 개인 단독 성과로 사용 금지
- **[확인 필요]**: 원본 SGP1/다른 Codex 세션 없이는 확정 불가

## 먼저 배제해야 할 과장

- `66,590 node overlaps`, WNS `-9.210 ns`, `Router completed with failures`, `Failed Timing & Nets`, `LUTLP-1`은 현재 로컬 원본이 없다. 개인 경험의 확정 수치로 쓰지 않는다.
- BN64/BN128의 `off_stp`, `in_reverse_stp`, `register_mode` 실험 순서와 HLS 수치도 원본이 없다.
- 팀 fix4의 정확도·FPS·router/DMA 개선은 강한 팀 자료지만, 사용자가 직접 구현한 범위는 현재 증거로 확정할 수 없다.

---

## EXPERIENCE 01 — AXI DMA 최소설계의 BD 검증 실패를 단계적으로 해소

### S — Situation

KV260에서 HLS AXIS passthrough를 DMA로 검증하기 위해 Zynq PS–AXI DMA–HLS IP Block Design을 만들었으나 `validate_bd_design`이 실패했다.

### T — Task

팀 IP를 full model.6에 넣기 전, DMA와 AXIS 연결을 최소 단위에서 Validate→Synthesis→Implementation→Bitstream까지 통과시키는 것이 사용자 담당 통합 작업이었다.

### A1 — 첫 분석

Vivado log에서 DMA control address 미할당, `axi_dma_0/m_axi_mm2s_aclk`, `smartconnect_0/aclk` 미연결을 확인했다. pin을 줄바꿈해 입력해 `output_stream`이 command로 해석된 오류, `get_bd_pinszynq...` 오타도 있었다.

### A2 — 첫 시도

clock net을 직접 연결하고 `validate_bd_design`을 다시 실행했다.

### Failure

`connect_bd_net`에 pin 하나만 주거나 이미 연결된 pin을 다시 연결해 추가 오류가 났고, DDR address segment도 남았다.

### A3 — 가설 수정

배선 자체보다 실제 BD pin/net과 address space 상태를 먼저 조회해야 한다고 판단했다. `set clk_src`, `set clk_dst`, `get_bd_nets`, `get_bd_addr_spaces`, `get_bd_addr_segs`로 범위를 나눴다.

### A4 — 최종 조치

누락 clock을 연결하고 `assign_bd_address`를 적용한 뒤 Validate/Generate Target/Wrapper/Synthesis/Implementation을 순차 수행했다. 최종 synthesized design에서 `IS_BLACKBOX == 1` 조회 결과가 0임도 확인했다.

### R — Result

- 최종 route: failed/unrouted/partially routed/node overlap 모두 0
- routed WNS `+5.904 ns`, WHS `+0.010 ns`
- placed LUT `4,717`(4.03%), FF `7,220`(3.08%), BRAM `2`(1.39%), DSP `0`
- `write_bitstream completed successfully`, 0 Critical Warnings, 0 Errors

### Learning

Tcl 오류가 발생할 때 연결을 반복하기보다 객체→net→address 순으로 관찰하고, Validate·blackbox·route·timing을 별도 기준으로 확인하는 습관을 얻었다.

### Evidence

- `vivado_6955.backup.log`: 334–413, 1039–1041, 1390–1393, 2749–2849, 3739–3743
- `ppe_dma_passthrough/.../impl_1/*route_status.rpt`, `*timing_summary_routed.rpt`, `*utilization_placed.rpt`

### Personal Contribution

Vivado Tcl/GUI에서 BD 생성, pin/net/address 진단, Validate와 build/report 확인을 직접 수행한 근거 A.

### Team Contribution

HLS `axis_passthrough` IP의 최초 작성 주체는 현재 자료에서 확인 필요.

### Confidence

**A**

### 자소서 적합성(5점)

| 도전 | 실패극복 | 창의성 | 예상밖 문제 | 끈기 | 협업 | 분석 | 전문성 | 장비/FSE | FPGA |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|4|5|3|4|5|3|5|5|4|5|

점수 이유: 실패 로그와 수정 iteration, 최종 timing/bitstream이 모두 남아 있어 분석적 문제해결과 FPGA 직무 연결성이 가장 강하다.

---

## EXPERIENCE 02 — Synthesis 성공 뒤 Hold 위반을 Implementation 결과로 재판정

### S — Situation

DMA 최소설계 synthesis의 setup WNS는 `+7.270 ns`였지만 `Timing constraints are not met`가 출력됐다.

### T — Task

단순히 WNS 양수만 보고 성공으로 결론내리지 않고 실제 실패 항목과 최종 routed timing을 확인해야 했다.

### A1 — 첫 분석

WHS `-0.082 ns`, THS `-353.106 ns`, hold failing endpoints `10,326`을 확인했다.

### A2 — 첫 시도 / Failure

Synthesis timing만으로는 실제 routing 이후 개선 여부를 알 수 없었다. 계층 synthesis 중 7 blackbox 표시도 최종 design blackbox와 혼동할 여지가 있었다.

### A3 — 가설 수정

setup/hold, synthesis/routed, 계층 중간/최종 design을 분리해 보았다.

### A4 — 최종 조치

`open_run impl_1`, `report_route_status`, routed `report_timing_summary`, 최종 `get_cells ... IS_BLACKBOX`를 각각 확인했다.

### R — Result

최종 routed WNS `+5.904 ns`, WHS `+0.010 ns`, TNS/THS 0, blackbox 0, timing met.

### Learning

하나의 대표 수치나 progress 100%보다 설계 단계와 violation 종류를 분리해야 한다는 것을 체득했다. 장비/공정 직무의 “측정 조건과 판정 기준 분리”로 연결 가능하다.

### Evidence

`vivado_6955.backup.log` 1039–1041, 1390–1393; routed timing report.

### Personal Contribution / Team Contribution / Confidence

- Personal: report를 직접 조회·판독(A)
- Team: 없음/확인 필요
- Confidence: **A**

### 자소서 적합성(5점)

| 도전 | 실패극복 | 창의성 | 예상밖 | 끈기 | 협업 | 분석 | 전문성 | 장비/FSE | FPGA |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|3|4|3|5|4|2|5|5|5|5|

---

## EXPERIENCE 03 — Vitis BSP 불일치 build 실패 후 v2 애플리케이션으로 보드 다운로드

### S — Situation

Vitis `dma_loopback` Debug build가 `fatal error: xparameters.h: No such file or directory`로 실패했다.

### T — Task

Vivado hardware platform과 맞는 BSP/application을 구성해 DMA 테스트 ELF를 보드에 올려야 했다.

### A1/A2 — 분석과 첫 시도

최초 application이 platform header를 찾지 못한다는 것을 build log로 확인했다.

### Failure

첫 build는 compile 단계에서 중단됐다.

### A3/A4 — 가설 수정과 최종 조치

`dma_loopback_v2`/`ppe_dma_platform_v2`로 재구성해 build했고, Vitis Run/Debugger가 FPGA program→XSA load→FSBL download→application ELF download→`con` 순으로 실행했다.

### R — Result

- v2 build 성공
- ELF: text `48,176`, data `4,232`, bss `22,820`, total `75,228`
- XCK26 target 인식, bit/XSA/FSBL/application download 성공
- UART 최종 DMA PASS는 발견되지 않아 기능 완료는 **[확인 필요]**

### Learning

컴파일 실패를 코드 오류로 단정하지 않고 hardware platform–BSP–application의 생성 관계를 확인해야 함을 배웠다.

### Evidence

`vitis_workspace/dma_loopback/Debug/build.ui.log`, `dma_loopback_v2/Debug/build.ui.log`, `.metadata/.log`.

### Personal/Team/Confidence

- Personal: IDE build 및 Run/Debug 시작, 실패·성공 결과 확인(A)
- Team: application source 최초 작성 주체 확인 필요
- Confidence: **A**(다운로드까지), 기능 PASS는 확인 필요

### 적합성

| 도전 | 실패극복 | 창의성 | 예상밖 | 끈기 | 협업 | 분석 | 전문성 | 장비/FSE | FPGA |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|4|4|3|4|4|3|4|4|5|5|

---

## EXPERIENCE 04 — Full model.6 bitstream 성공 후 보드 MMIO hang을 “빌드 성공과 실행 성공”으로 분리

### S — Situation

SGP1 custom full build는 bitstream/XSA까지 성공했고 PYNQ에서 `overlay.download()`와 `is_loaded()==True`도 확인됐지만, `overlay.model6_dma` 또는 `MMIO(0xA00A0000...).read(0)`에서 Jupyter가 `[*]`로 멈췄다.

### T — Task

비트스트림 생성 성공을 실제 DMA 실행 성공으로 착각하지 않고 런타임 경계를 검증해야 했다.

### A1 — 첫 분석

HWH parse로 `model6_dma` base `0xA00A0000`, range `0x10000`, MM2S/S2MM register가 노출됨을 확인했다.

### A2 — 첫 시도

PYNQ DMA object와 직접 MMIO read를 시도했다.

### Failure

셀 `[*]` hang. kernel restart로 UI는 복구했으나 register read 값은 얻지 못했다.

### A3 — 가설 수정

bit/hwh 파싱 문제보다는 bitstream–device tree/XRT–driver–AXI address/clock/reset 중 하나의 런타임 통합 문제로 범위를 좁혔다. 다만 stack trace가 없어 단일 원인은 확정하지 않았다.

### A4 — 최종 조치

kernel restart, ipykernel/Device/XRT/xclbinutil/Python 환경을 분리 확인했다. 동일 이름의 팀 fix4 driver 주소맵이 custom bit와 다름도 문서에서 구분했다.

### R — Result

- Overlay parse/download 성공
- IP dictionary/address map 확인
- MMIO/DMA 실제 transfer는 미해결
- “hardware build complete”와 “board runtime verified”를 명확히 분리

### Learning

미해결 문제도 재현 조건과 성공 경계를 명확히 남기는 것이 중요하다. FSE/CS 직무에서 설치 완료와 장비 기능 검증을 구분하는 경험으로 연결성이 높다.

### Evidence

현재 transcript의 Jupyter output; `CODEX_RAW_COMMAND_EVIDENCE_20260812.txt` V26–V30.

### Personal/Team/Confidence

- Personal: PYNQ cell 실행과 hang/restart, 환경 진단(C)
- Team: bitstream을 구성한 IP의 개별 작성은 팀 분담
- Confidence: **C**

### 적합성

| 도전 | 실패극복 | 창의성 | 예상밖 | 끈기 | 협업 | 분석 | 전문성 | 장비/FSE | FPGA |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|4|3|3|5|5|3|5|5|5|5|

---

## EXPERIENCE 05 — 여러 KV260 중 잘못된 보드를 데이터로 식별

### S/T

기존 `.56` 보드에서 webcam이 보이지 않고 이후 네트워크에서도 사라졌다. 실시간 카메라 검증을 위해 실제 연결된 KV260을 찾아야 했다.

### A1/A2

`ping`, `ip neigh`, `lsusb`, `/dev/video*`를 확인했으나 `.56`에는 keyboard/mouse만 있었고 video node가 없었다.

### Failure

IP를 고정 사실로 가정해 `.56`에 반복 접속하면서 카메라와 artifact 상태가 서로 모순됐다.

### A3/A4

`arp-scan`으로 Xilinx MAC들을 열거하고 `.253`을 선택해 `hostname`, `hostname -I`, `lsusb`, `/dev/video*`, Jupyter 9090 LISTEN을 교차 확인했다.

### R

`.253`에서 Logitech C270 `046d:0825`, `/dev/video0`, `/dev/video1`, hostname `kria`를 확인했다.

### Learning

환경을 추정하지 않고 장치 ID·MAC·device node·service port 등 독립 지표로 대상 장비를 식별하는 습관을 얻었다.

### Evidence / Contribution / Confidence

- 현재 transcript 네트워크·USB 출력
- Personal: 직접 명령 실행(C); Team: 없음
- Confidence: **C**

### 적합성

| 도전 | 실패극복 | 창의성 | 예상밖 | 끈기 | 협업 | 분석 | 전문성 | 장비/FSE | FPGA |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|3|4|4|5|5|2|5|3|5|3|

---

## EXPERIENCE 06 — PYNQ-DPU 실행환경의 root·venv·XRT 문제를 층별 분리

### S/T

YOLO `.xmodel`과 DPU overlay를 실행하려 했으나 Python 실행 방식마다 다른 오류가 발생했다.

### A1–A4

1. 일반 사용자 PYNQ Python: `Root permissions required.`
2. `sudo -E python3`: `pynq_dpu` module 없음.
3. PYNQ venv 절대경로: 한 시도에서 `No Devices Found`.
4. `sudo -E`+PYNQ venv: `Device.devices`에 EmbeddedDevice 1개 확인.
5. 다음 단계에서 임시 `t.xclbin` 미생성 `FileNotFoundError`.
6. `xclbinutil` 경로/버전/PATH를 확인했지만 load 완료는 못함.

### R

권한→Python environment→XRT device→xclbin metadata 단계로 실패 지점을 좁혔으나 DPU overlay 실행은 미해결.

### Learning

같은 Python 명령도 사용자 권한과 interpreter/venv에 따라 전혀 다른 시스템을 본다는 점, 환경 계층을 하나씩 고정해야 한다는 점을 배웠다.

### Evidence / Contribution / Confidence

현재 transcript; Personal C, Team 없음, Confidence **C**.

### 적합성

| 도전 | 실패극복 | 창의성 | 예상밖 | 끈기 | 협업 | 분석 | 전문성 | 장비/FSE | FPGA |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|4|3|3|5|5|2|5|4|5|4|

---

## EXPERIENCE 07 — 팀 IP 통합에서 interface·version·source 유무를 점검

### S/T

여러 팀원이 만든 conv/BN/split/concat/residual IP를 Vivado repository에 모아야 했으며, HLS source와 export IP, interface 이름·형식이 모두 같다고 가정할 수 없었다.

### A/F/A3/A4

- `find`, `unzip`, `component.xml`, VLNV와 source를 조사했다.
- placeholder 경로를 그대로 입력하거나 `vitis hls`라고 잘못 입력한 뒤 실제 경로와 `vitis_hls`로 수정했다.
- 8개 export의 AXIS/AXI-Lite/BRAM metadata를 확인하고 cv1(128→128)과 cv2(256→128)가 별도 물리 IP임을 구분했다.
- SGP1에 ZIP/`ip_repo_v2`를 전송하고 hash/경로를 확인한 흔적이 있다.

### R

custom full BD에서 conv1x1 cv1/cv2, BN64/128, concat, conv3x3, residual, routers, DMA가 `ip_dict`에 노출됐고 bitstream까지 생성됐다. 단, 개별 source 수정 주체와 repo 최종 version mapping은 일부 확인 필요.

### Learning

협업 IP는 이름보다 `component.xml`의 실제 interface/VLNV와 artifact hash를 기준으로 받아야 한다.

### Evidence / Contribution / Confidence

- Bash history, export `component.xml`, custom Jupyter `ip_dict`
- Personal: repository 조사·전송·Vivado 통합(B/C)
- Team: 각 HLS IP 구현
- Confidence: **B/C**

### 적합성

| 도전 | 실패극복 | 창의성 | 예상밖 | 끈기 | 협업 | 분석 | 전문성 | 장비/FSE | FPGA |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|4|4|3|4|5|5|5|5|4|5|

---

## EXPERIENCE 08 — 팀 사례: 순차 router deadlock을 DATAFLOW로 해결

### S/T/A/Failure

팀 fix4에서 input이 데이터 내용과 무관하게 82 pixel에서 반복 정지했다. C simulation은 stream 깊이가 사실상 무한이라 문제가 드러나지 않았다.

### 가설 수정/최종 조치

IP를 하나씩 켜며 정지 위치를 측정해 `bottleneck_router`의 producer 종료 후 consumer가 실행되는 순차 구조로 좁혔고 DATAFLOW로 재작성했다.

### R

82→1,600 pixel 전량 통과.

### Learning

단품 simulation 성공이 finite FIFO가 있는 시스템 성공을 보장하지 않는다.

### Evidence / Contribution / Confidence

- `/tmp/.../model6_hw_fix/README.md`, `docs/일일보고_3일.md`
- Personal: **[확인 필요]**
- Team: 진단 스크립트·router 재작성·재빌드
- Confidence: **E**

### 적합성

도전5/실패극복5/창의5/예상밖5/끈기5/협업4/분석5/전문5/장비5/FPGA5. 단, 개인 기여 확인 전 자소서 단독 사용 금지.

---

## EXPERIENCE 09 — 팀 사례: DMA length 14→26과 completion 판정 개선

### 문제→시도→수정→결과

- 출력 409,600 B인데 `c_sg_length_width=14`, 최대 16,383 B.
- TLAST 없는 stream을 분할 수신하면 첫 조각 뒤 `DMAIntErr`.
- width를 26으로 확장해 67 MB 범위에서 한 번에 수신.
- length 한도를 register에 써서 probe하던 driver가 그 쓰기로 transfer를 시작하는 부작용도 발견.
- fixed constant와 IOC completion으로 바꿔 completion wait `10.0 s→0.05 s`.

### 정량 결과

LUT `69,319→69,502`(+183), FF `134,885→135,086`(+201), BRAM/URAM/DSP 변화 0, WNS `+0.462 ns`.

### Evidence/Contribution/Confidence

팀 verification/README **E**. 사용자의 custom MMIO hang과 동일 원인이라고 단정할 수 없다. 개인 기여 확인 필요.

### 적합성

도전5/실패극복5/창의5/예상밖5/끈기5/협업4/분석5/전문5/장비5/FPGA5.

---

## EXPERIENCE 10 — 팀 사례: Parameter BRAM 주소 단위와 반복 frame slot 오류

### 문제와 iteration

1. HLS는 byte address, blk_mem_gen은 word address로 해석해 float channel `c`가 `4c` 위치를 읽고 8-bit address가 256에서 wrap.
2. 8-bit weight BRAM은 1 byte=1 cell이라 정상이라 문제 발견이 늦었다.
3. BMG depth를 4배, COE 값을 0·4·8…에 배치하는 `coe_stride4.py` 적용.
4. cv2를 제거한 뒤 static `call_counter`가 둘째 frame에서 stale slot1을 읽는 별도 문제 발견.
5. slot1을 slot0(cv1) 값으로 duplicate.

### 결과

bitstream 1회 load 상태에서 12 frame 연속 검증. y0/y1 불일치 0; 전체 feature correlation 0.999, ±1 이내 95.6%는 팀 자료.

### Evidence/Contribution/Confidence

팀 README/verification/daily report **E**, 개인 기여 확인 필요.

### 적합성

도전5/실패극복5/창의5/예상밖5/끈기5/협업4/분석5/전문5/장비4/FPGA5.

---

## EXPERIENCE 11 — 팀 사례: CHW/HWC 경계와 INT8 scale 계약

### 문제/조치

CPU PRE는 `[1,128,40,40]` NCHW/CHW, DMA stream은 pixel-major HWC `[40,40,128]`, 출력 raw는 `[40,40,256]` HWC였다. 공개 Python→driver boundary는 CHW로 유지하고 driver/DMA에서 배열 계약을 맞췄으며, output을 HWC reshape→CHW transpose했다. quantization은 `S_IN=0.0389917693`, dequantization은 `S_CAT=0.0553356526`.

### 결과

팀 final에서 y0/y1 exact match, 전체 correlation 0.999, 검출 90건 중 88건 재현(97.8%). “layout 오류로 실제로 깨진 최초 수치”는 문서에 없어 [확인 필요].

### Evidence/Contribution/Confidence

팀 README/runtime/verification **E**. 개인 기여 확인 필요.

### 적합성

도전4/실패극복4/창의4/예상밖5/끈기4/협업4/분석5/전문5/장비4/FPGA5.

---

## EXPERIENCE 12 — 팀 사례: 자원 한계로 cv2를 SW로 이동한 HW/SW co-design

### 문제/판단

초기 model.6 전체(cv1~cv2)를 FPGA에 넣으려 했으나 팀 문서는 cv2 포함 구조의 자원/placement 부담을 기록한다. 동일 conv3x3 등을 물리적으로 복제하면 LUT가 4배 수준으로 증가하므로 1개 IP 재사용+router 구조를 선택했고, 최종 fix4에서는 cv2를 CPU POST로 이동했다.

### 결과

최종 팀 fix4: LUT 69,502(59.3%), FF 135,086(57.7%), BRAM 124.5(86.5%), URAM 60(93.8%), DSP 476(38.1%), WNS +0.462 ns. cv2 제거 직후 별도 build 수치 LUT 65,659/FF 130,945/BRAM121.5/URAM56/DSP472가 있어 build 간 혼용 금지.

### Learning

연산을 많이 넣는 것보다 실제 route 가능성과 SW 경계 비용을 함께 판단해야 한다.

### Evidence/Contribution/Confidence

팀 `model6_c2f_구현_정리.md`, fix4 verification **E**. 사용자는 custom build에서 cv2 IP까지 통합했으므로 팀 fix4 결정의 개인 주도 여부 확인 필요.

### 적합성

도전5/실패극복5/창의4/예상밖4/끈기5/협업5/분석5/전문5/장비4/FPGA5.

---

## EXPERIENCE 13 — 팀 사례: FPGA 가속 후에도 FPS가 낮아 Amdahl 병목 재평가

### S/T/A/Result

FPGA model.6은 SW `0.077 s`를 전송·양자화 포함 `0.055 s`로 줄였지만 model.6은 전체 SW `1.194 s`의 6.5%뿐이었다. 전체 hybrid는 약 `1.265 s`, `0.79 FPS`; webcam 문서에는 `0.77 FPS`. 절감은 전체의 약 1.7%에 불과했다. PRE/POST가 병목이므로 ORT INT8 PRE + FPGA + NCNN POST와 PRE(frame N+1)/FPGA(frame N) overlap 구조를 검토했다. POST+FPGA overlap은 benchmark에서 더 느려 제외했다고 코드 주석이 명시한다.

### Learning

가속 블록 자체의 개선과 end-to-end 목표는 다르며, stage profile로 투자 우선순위를 결정해야 한다.

### Evidence/Contribution/Confidence

팀 성능분석 및 Jungwon runtime **E**. 사용자 개인 실행 FPS는 확인되지 않았다.

### 적합성

도전5/실패극복4/창의5/예상밖5/끈기4/협업5/분석5/전문5/장비4/FPGA5.

---

# 예상하지 못했던 문제만 추출

| 예상 밖 현상 | 실제 판정 | 근거/기여 |
|---|---|---|
| setup WNS 양수인데 synthesis timing fail | hold 위반 10,326 endpoints | 개인 A |
| Synthesis 통과 후 실제 route 상태를 별도 확인해야 함 | 초기 failed nets가 route finalize에서 0 | 개인 A |
| bitstream·Overlay load 성공인데 MMIO read hang | runtime 통합 미검증 | 개인 C |
| 같은 `kria` 이름의 여러 보드 | MAC/USB/video node로 `.253` 식별 | 개인 C |
| root로 실행하면 module이 사라짐 | system Python과 PYNQ venv가 다름 | 개인 C |
| C simulation에서 안 보인 stream deadlock | finite FIFO에서 82 pixel 정지 | 팀 E |
| 8-bit weight 정상인데 float parameter만 오염 | byte/word address 단위 차이 | 팀 E |
| 첫 frame 정상 후 둘째 frame 오류 | static call counter와 stale slot | 팀 E |
| FPGA 가속 성공인데 end-to-end FPS 개선 미미 | model.6 비중 6.5%, 순절감 약 1.7% | 팀 E |

# 나의 문제해결 방식 — 실제 패턴

1. **단계별 성공 기준 분리:** Validate, synthesis, blackbox, route, setup/hold, bitstream, Overlay, DMA를 별도 통과 기준으로 봤다.
2. **객체를 먼저 관찰:** pin 이름을 추정하다 실패한 뒤 `get_bd_pins/get_bd_nets/get_bd_addr_*`로 실제 객체를 확인했다.
3. **최종 산출물까지 검증:** bit/hwh/xsa 존재, byte size, SHA256, XSA return code까지 확인했다.
4. **환경 계층 분리:** 권한, interpreter, venv, XRT Device, xclbinutil, board IP를 한꺼번에 바꾸지 않고 분리했다.
5. **미해결 범위를 솔직히 고정:** MMIO hang과 UART PASS 부재를 성공으로 포장하지 않았다.
6. **협업 artifact는 metadata로 확인:** 이름만 믿지 않고 component.xml, VLNV, interface, hash, address map을 비교했다.
7. **팀 수치와 개인 수행 분리:** team fix4의 고급 개선은 E로 유지하고 개인 주장에는 A/B/C를 우선했다.

# 자소서 사용 시 안전한 표현

- 개인 경험: “제가 Vivado 통합과 report 판독, board bring-up을 수행했다.”
- 팀 경험: “팀은 router/DMA/parameter 문제를 해결했고, 저는 IP repository·Vivado 통합 및 결과 검증을 맡았다.” — 단, 해당 역할 합의의 추가 증거가 있으면 강화 가능.
- 금지: “제가 82→1600 pixel, DMA 14→26, 97.8%를 단독으로 달성했다.” 현재 개인 기여 근거 없음.

