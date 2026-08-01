# 팀원 브랜치 검증 분류

감사일: 2026-08-01  
저장소: `YHJ659/ppe_fpga`  
원칙: 실행 가능한 DUT, 고정된 인터페이스 계약, 독립적인 golden 세 가지가 모두 있어야 기능 TB를 승인합니다.

## 1. 최종 분류

| 담당자/브랜치 | 지금 검증해야 하는 것 | 지금 판정 | 아직 만들지 않을 것 |
|---|---|---|---|
| 성기호 / `Giho_Sung` | 기본 8×8 단일채널 conv RTL과 controller/window/MAC의 strict 회귀 | **즉시 진행, sign-off 전 수정 필요** | AXI, DMA, 다채널, 전체 YOLO, KV260 bitstream |
| 유현준 / `HyunJun_Yoo` | 7개 개별 HLS C++ 커널 C-sim과 vector 무결성 | **개별 IP는 진행 가능, C2f 전체는 BLOCKED** | model.6 chain, 최종 cv2, 성능 sign-off, KV260 통합 |
| 오상헌 / `Sangheon_Oh` | 검증 scaffold 자체의 MAC/control/comparator 정확성 | **검증 도구 보강 대상** | 실제 PPE/Conv sign-off. 현재 실제 DUT와 golden이 없음 |
| 김완민 / `Wanmin_Kim` | 구현 완료 여부와 계약 확인만 | **BLOCKED — 기능 TB 작성 금지** | C2f 기능/성능/보드 TB 전부 |
| 박정원 / `Jungwon_Park` | Python syntax와 판정 정책 설계 검토 | **하드웨어 TB 대상 아님** | RTL TB, webcam 정확도 승인, 보드 가속기 검증 |

여기서 `BLOCKED`는 “나중에 귀찮아서 한다”가 아니라, 현재 TB를 만들면 검증되지 않은 가정을 정답으로 고정하게 된다는 뜻입니다.

## 2. 성기호 — `Giho_Sung`

### 현재 DUT

- INT8 signed 입력/weight, INT32 누산
- `8×8` 단일채널 입력과 `3×3` valid convolution
- `6×6`, 즉 36개 출력
- `input_buffer → window_gen → mac_array → output_buffer`, 별도 controller
- padding, bias, activation, requantization, multi-channel, AXI 없음

### 재현된 정상 동작

- 원본 `tb_conv_top`: 3개 케이스, 108/108 golden 일치
- 새 `tb_window_gen_scoreboard`: `IMG_SIZE=8`, bubble 포함 연속 2프레임, 72개 window 전수 일치
- 새 `tb_mac_array_scoreboard`: signed 경계, bubble, 연속 입력, Sobel 포함 통과
- 새 `tb_controller_contract`: legal traffic에서 read 64개, write 36개, 주소 순서와 valid 정렬 통과

### 즉시 수정/검증할 결함

1. controller가 `mac_out_valid`를 37번 받으면 주소 36에 씁니다. 실제 output memory 깊이는 36이므로 out-of-bounds입니다.
2. `window_gen`의 row counter는 `IMG_SIZE-1`에서 명시적으로 0이 되지 않습니다. 기본값 8에서는 비트 overflow가 우연히 맞지만, `IMG_SIZE=7` 연속 두 번째 프레임에서 실제 window 불일치를 재현했습니다.
3. 완료 조건이 실제 출력 개수가 아니라 고정 drain 시간입니다. pipeline latency/bubble 변경 시 조기 `done` 위험이 있습니다.
4. 원본 TB의 FAIL/timeout 다수가 `$fatal`이 아니므로 CI가 실패를 성공 종료로 오판할 수 있습니다.
5. 원본 `tb_window_gen`은 signed/unsigned unpacked-array port가 달라 Icarus와 Verilator strict elaboration에 실패합니다.

### 보고서와 구현의 차이

- README는 DSP48 mapping을 주장하지만 제출 utilization은 DSP 0입니다.
- 기본 buffer도 BRAM 0이고 distributed RAM입니다.
- WNS `+3.789 ns`는 OOC 내부 경로 결과이며 input/output delay 누락 경고가 130개입니다.
- `dma_passthrough.xsa`에는 `conv_top`이 아니라 별도 `axis_passthrough`가 들어 있어 conv 보드 통합 증거가 아닙니다.

### 성기호에게 요청할 것

- output write guard와 결과 개수 기반 완료 계약
- 명시적 frame start 또는 임의 `IMG_SIZE`에서 정확한 row wrap
- signed/full-range deterministic vectors와 Python/NumPy golden
- Vivado 2022.2 재생 Tcl, XSIM 로그, 실제 AXI wrapper 이후 timing/resource 보고서

## 3. 유현준 — `HyunJun_Yoo`

### 지금 검증 가능한 개별 IP

| IP | 계약 | host C-sim |
|---|---|---:|
| conv3x3 | INT8 `[64,40,40]` × `[64,64,3,3]` → INT32 `[64,40,40]`, pad 1 | PASS exact |
| conv1x1 | INT8 `[128,40,40]` × `[128,128]` → INT32 `[128,40,40]` | PASS exact |
| BN+SiLU 64 | INT32/float BN/scale → INT8 | PASS ±1 |
| BN+SiLU 128 | INT32/float BN/scale → INT8 | PASS ±1 |
| split | INT8 128채널 → 64채널 2개 | PASS exact |
| residual_add | scale이 다른 INT8 두 입력 → INT8 | PASS ±1 |
| concat | scale이 다른 64채널 4개 → 256채널 INT8 | PASS ±1 |

7개 제출 TB와 binary 크기는 모두 실행/검사됐습니다. 이 결과는 host 기능 C-sim이며 Vitis HLS Co-sim이나 RTL timing 증거는 아닙니다.

### model.6 전체가 BLOCKED인 근본 이유

1. concat 출력은 256채널인데 제출 `conv1x1`은 입력 128채널 고정입니다. 최종 cv2 `256→128` 구현이 없습니다.
2. `split.y1`과 `concat.y1`이 같은 연결 신호여야 하지만 102,400개 중 8,260개만 exact입니다. 평균 절대차 4.149, 최대차 42입니다.
3. split은 공통 scale `0.047591...`을 유지하지만 m0 입력은 `0.0317828...`로 별도 재양자화했습니다. 그 사이 requantizer가 없습니다.
4. m0.cv2, m1.cv1/cv2, m1 residual, 최종 cv2의 weight/BN/golden이 없습니다.
5. 문서 latency와 export metadata가 다릅니다. conv3x3은 문서 819,784 대 export 922,198 cycles, conv1x1은 204,802 대 1,024,011 cycles입니다.
6. `csynth.rpt`, `cosim.rpt`, 재생 Tcl이 없어 자원/성능 주장을 독립 재현할 수 없습니다.

### 유현준에게 요청할 것

- 최종 cv2 256→128 구현과 TB
- 모든 producer/consumer 경계의 shape, dtype, CHW layout, scale, zero-point 표
- split→m0 requantization 정책 결정
- 같은 한 입력에서 연속 추출한 m0/m1/final golden과 weight
- deterministic seed, 파일 read-count 검사, directed quantization 경계 vector
- Vitis HLS 2022.2 C-sim/C-synth/Co-sim Tcl과 보고서

## 4. 오상헌 — `Sangheon_Oh`

이 브랜치는 실제 팀원 Conv/PPE RTL이 아니라 검증 starter와 KV260 공식 YOLOv3 COCO 기준선입니다. 따라서 “플랫폼이 카메라와 DPU를 구동한다”는 기준선과 “팀 PPE 하드웨어가 맞다”는 기능 검증을 분리해야 합니다.

### 새로 검증한 것

- 교육용 4-lane `mac_core`: accumulator, INT32 wrap, requantization, saturation, done pulse strict TB 통과
- `ppe_control_mock`: 정확한 latency, busy 중 start, 1-cycle done, async reset strict TB 통과
- 기존 Python 15 tests와 mock pass/fail 흐름은 감사 중 통과

### 즉시 고칠 검증 도구 결함

1. detection comparator가 greedy matching이라 가능한 완전 매칭을 놓치는 false FAIL 반례가 있습니다.
2. class ID만 비교해 같은 ID의 `helmet → no_helmet` 이름 변경도 false PASS합니다.
3. Python MAC golden은 int64로 누산하고 RTL INT32 wrap을 모델링하지 않습니다.
4. 기존 MAC vector는 최종 `y`만 검사하고 accumulator를 정답 자산에 저장하지 않습니다.
5. `verification.yaml`은 실행 코드가 읽지 않는 dead config입니다.
6. 실제 `best.pt`, 실제 이미지 annotation, DUT tensor dump, class-map hash가 없습니다.

KV260 YOLOv3 COCO 기준선은 일반 80-class 객체 검출이며 하이바/조끼 미착용 판정 모델이 아닙니다.

## 5. 김완민 — `Wanmin_Kim`

현재 extension 없는 `c2f` HLS 초안과 구조 문서만 있습니다. 기능 TB를 만들 수 없는 이유:

- AXI stream input unpack와 output pack 본문이 생략됨
- weight/bias load 경로가 없고 static 배열은 0으로 초기화됨
- SiLU LUT가 `/* ... 256개 ... */` placeholder로 대부분 0
- shortcut/residual 의미가 불명확하고 코드가 원본 대신 중간 buffer를 더함
- 문서의 AXI master/AXI-Lite 구상과 코드의 AXI stream 포트가 불일치
- padding, stride, quantization, rounding, saturation, scale 계약과 golden 없음

김완민에게는 먼저 compilable `.cpp`, 완전한 I/O pack/unpack, weight/bias 계약, 전체 LUT 또는 activation 규칙, residual 정의, 작은 deterministic vector를 요청해야 합니다. 그 전의 TB는 placeholder를 정답으로 승인하므로 작성하지 않습니다.

## 6. 박정원 — `Jungwon_Park`

브랜치는 `webcam.py`, `webcam2.py`, README뿐이며 Python syntax는 통과했습니다. 하지만 `models/best.pt`가 없습니다.

하드웨어 TB보다 먼저 고칠 기능 문제:

- helmet/vest/mask 존재 여부를 프레임 전체 boolean으로 합쳐 서로 다른 사람의 장비로 PASS할 수 있음
- `NO-Hardhat`, `NO-Safety Vest`, `NO-Mask` negative class를 명시적으로 처리하지 않음
- person box와 PPE box의 공간적 연결 규칙이 없음
- `webcam2.py`는 3프레임마다 추론하고 이전 detection을 재사용하므로 시간 계약이 불명확

먼저 판정 로직을 카메라/UI에서 분리한 pure function으로 만들고, 사람별 association, negative class 우선순위, class-map, 고정 detection fixture를 확정해야 합니다. 그 다음 Python unit test를 만들면 됩니다. RTL TB는 현재 필요하지 않습니다.

## 7. 다음 작업 순서

1. 성기호의 두 재현 결함 수정 후 strict regression 재실행
2. 유현준의 최종 cv2와 quantization 계약 수령
3. 유현준 전체 `model6_chain_tb`를 동일 입력/동일 intermediate tensor로 작성
4. 오상헌 comparator와 Python/RTL overflow 정책 통일
5. 김완민은 완성 조건 충족 후 작은 C-sim부터 시작
6. 박정원은 per-person software policy unit test부터 시작
7. 마지막에만 AXI/Co-sim/bitstream/KV260 board 검증으로 올라가기

이 순서는 관습이 아니라 실패 원인을 격리하기 위한 의존 순서입니다. leaf IP가 bit-exact하지 않은 상태에서 보드까지 올라가면 카메라, DMA, 인터페이스, 계산 오류를 구분할 수 없습니다.
