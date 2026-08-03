# 2026-08-03 프로젝트 진행 리포트

![2026년 8월 3일 YOLOv8n model.6 C2f 통합·검증 성과](visuals/2026-08-03-progress-onepager.png)

[성과 보드 SVG 크게 보기](visuals/2026-08-03-progress-onepager.svg)

## 1. 프로젝트 개요

| 항목 | 내용 |
|---|---|
| 프로젝트 | PPE FPGA 기반 YOLO 가속기 팀 프로젝트 |
| 오늘 작업 범위 | 김완민 담당 `YOLOv8n model.6 C2f` 분석·검증·3×3 MAC 연계 기반 구현 |ㄴ
| 작업 환경 | Apple Silicon macOS, C++17, Python 3, Icarus Verilog 13.0 |
| 결과 상태 | 구조 파악·제출본 blocker 재현·기능 기준 모델·3×3 MAC micro-integration 완료. 전체 C2f IP와 KV260 검증은 미완료 |

## 2. 오늘의 작업 목적

김완민 브랜치에 제출된 산출물이 무엇을 구현하려는지 먼저 정확히 파악하고, 단순 테스트벤치 통과 여부를 넘어 다음을 수행하는 것이 목적이었다.

1. `model.6 C2f`가 YOLO 전체에서 담당하는 계산 구조 확인
2. 현재 제출된 HLS source, testbench, export IP의 기능 신뢰성 확인
3. 올바른 C2f 동작을 비교할 수 있는 독립 기능 기준 마련
4. 성기호 팀원의 3×3 MAC을 김완민 C2f dense convolution에 재사용할 수 있는 최소 연결부 구현
5. 팀원이 이어서 작업할 수 있도록 계약·검증 결과·재현 절차 문서화

## 3. 제1원칙에 따른 판정 기준

### 드러낸 가정

- `export.zip`이 존재하면 convolution이 구현됐을 것이라는 가정
- 기존 testbench가 PASS하면 출력값도 맞을 것이라는 가정
- 성기호의 완성 `conv_top`을 김완민 C2f에 그대로 연결할 수 있을 것이라는 가정
- `model.6`이 완성된 YOLO 또는 검출 Head일 것이라는 가정

### 남긴 근본 사실

- YOLOv8n `model.6`은 검출 결과를 만드는 전체 YOLO가 아니라 `40×40×128` 중간 feature map을 입력·출력으로 갖는 C2f 블록이다.
- 정상 C2f `n=2`에는 `1×1 → split → 네 dense 3×3 + 두 residual → concat → 1×1` 계산이 필요하다.
- dense 3×3의 출력 하나는 64개 input channel 각각의 3×3 dot product를 모두 누적해야 한다.
- PASS의 의미는 testbench가 실제로 비교한 항목을 넘을 수 없다.

### 연역한 결론

- 현재 제출본의 packet 흐름 PASS만으로 C2f 기능을 신뢰할 수 없다.
- 성기호의 전체 8×8 valid-convolution top은 shape·padding·protocol이 달라 직접 연결할 수 없다.
- 재사용 가능한 단위는 9개 곱을 계산하는 `mac_array.sv`이며, 이를 dense convolution에 사용하려면 input-channel 누산 어댑터가 필요하다.

## 4. 감사 기준 소스 고정

작업 중 브랜치 변경으로 판정 대상이 섞이지 않도록 원격 branch와 파일 hash를 고정했다.

| 대상 | 기준 |
|---|---|
| `Wanmin_Kim` | `e550f959f88854772b7b9ab428bdf3198193b316` |
| `Giho_Sung` | `f7bc21dd145ed3e03896c73219c756d94c95c85a` |
| `model6_c2f_5.cpp` SHA-256 | `efe826378e2f04da9e2c07e2ebf92cb331ba08fdaf19f6deca7d5bdd3abe8723` |
| `tb.cpp` SHA-256 | `0f477053538a4bd4a9690a5799516f0f2edef54810ec51e8820e998e30e1764e` |
| `export.zip` SHA-256 | `7b05a52d42ecff401f3995f6a75974e75efb7a7c6a0d493b1bd1d1c37ef09f83` |

8월 3일 작업 종료 시점에 원격 branch SHA가 위 값과 동일함을 다시 확인했다.

## 5. model.6 C2f 구조 분석

표준 640×640 YOLOv8n 입력에서 model.5가 `40×40×128` feature map을 만들고, model.6 C2f는 공간·채널 크기를 유지하며 특징을 재가공한다.

```text
X: 40×40×128
  └─ cv1 1×1: 128→128
       ├─ y0: 40×40×64
       └─ y1: 40×40×64
            ├─ 3×3 → 3×3 → residual(y1) = m0
            └─ m0 → 3×3 → 3×3 → residual(m0) = m1
       concat(y0, y1, m0, m1): 40×40×256
  └─ cv2 1×1: 256→128
Y: 40×40×128
```

필요한 3×3 네 개는 모두 `64 output × 64 input × 3 × 3` dense convolution이다. 네 convolution의 weight만 총 147,456바이트이며, cv1/cv2를 포함한 model.6 전체 INT8 weight는 196,608바이트다.

## 6. 최신 김완민 제출본 감사 결과

### 핵심 판정

현재 제출본은 AXI-Stream packet을 입력받아 같은 크기의 packet을 내보내는 smoke artifact이지만, 기능적으로 올바른 model.6 C2f IP는 아니다.

### 확인된 주요 blocker

| 항목 | 정상 요구사항 | 현재 제출본 | 영향 |
|---|---|---|---|
| 3×3 호출 수 | 4회 | 2회 | 두 번째 bottleneck 누락 |
| residual add | 2회 | 1회 | C2f `n=2` topology 불일치 |
| 3×3 weight | `64×64×3×3` dense | `64×3×3` 형태 | input-channel mixing이 없는 depthwise 형태 |
| weight/bias 공급 | ROM 초기값 또는 load interface | 초기값·load port 없음 | 정적 배열이 0으로 초기화됨 |
| 양자화 | layer/channel별 requant, rounding, saturation | 공통 `mac >> 8`, INT8 wrap | 실제 모델 정수 연산과 불일치 |
| SiLU | signed scale-aware activation | signed LUT index 반전 | `+1→0`, `-1→+127` 형태의 잘못된 매핑 |
| testbench | golden output 값 비교 | packet 수와 TLAST 존재 확인 | all-zero 출력도 PASS |

생성 RTL 감사에서는 적어도 네 개의 내부 datapath 출력이 `8'd0`으로 고정됐고, HLS metadata의 DSP 사용량도 0이었다.

기존 `tb.cpp`를 그대로 실행했을 때 첫 packet이 모두 0인데도 다음과 같이 성공이 출력됐다.

```text
First Packet Output Sample: 0 0 0 0 0 0 0 0
[SUCCESS] HLS C-Simulation Passed! (Stream IN/OUT match)
```

강화한 probe에서는 nonzero 입력을 넣었음에도 출력 204,800바이트 전체가 0임을 재현했다.

```text
PASS submitted AXIS packet count/TLAST/TKEEP/TSTRB smoke contract
REPRODUCED functional blocker: nonzero input produced 204800/204800 zero output bytes
This is not a C2f functional PASS.
```

자동 감사 도구는 topology, weight, TB, LUT, constant-zero RTL과 관련된 총 11개 blocker를 검출했다.

## 7. 오늘 구현한 내용

### 7.1 Portable C2f functional oracle/prototype

올바른 C2f `n=2` 그래프를 실행하는 C++ 기준 구현을 작성했다.

- tensor layout: HWC
- weight layout: OIHW
- stride 1, 3×3 same zero padding
- 네 dense 3×3 convolution
- 두 scale-aware residual 연산을 표현할 수 있는 계약
- per-output-channel multiplier/shift
- 반올림과 INT8 saturation
- signed LUT index `q+128`
- AXIS64 frame payload pack/unpack 계약

이 구현은 zero-point가 0인 자체 정의 symmetric INT8 계약의 functional oracle/prototype이다. 실제 trained YOLO model.6의 정확도 검증물은 아니다.

### 7.2 독립 golden 및 강화된 테스트

후보 구현과 다른 NCHW loop 순서를 사용하는 독립 reference를 작성해 고정 난수 입력을 bit-exact 비교했다. 이외에도 다음 directed test를 추가했다.

- identity topology로 두 bottleneck과 branch 순서 확인
- cross-channel impulse로 dense/depthwise 구분
- corner와 center에서 zero padding 확인
- signed LUT indexing, rounding, INT8 saturation
- AXIS64 known-literal byte order
- TKEEP/TSTRB, packet count, 최종 위치의 단일 TLAST
- 실제 `40×40×128`, 204,800바이트, 25,600 beat shape
- 제출본 all-zero 출력 검출

### 7.3 성기호 3×3 MAC 재사용 어댑터

성기호의 실제 `mac_array.sv`를 인스턴스화하고 input-channel 부분합을 INT32로 누적하는 RTL을 작성했다.

```text
output(oh,ow,oc)
  = bias(oc)
  + Σic Σ9-lane input(ih,iw,ic) × weight(oc,ic,ky,kx)
```

어댑터의 역할은 다음과 같다.

1. 한 transaction의 9-product MAC 결과를 입력 채널 방향으로 누적
2. `first_channel`에서 bias를 포함해 누적 시작
3. `last_channel`에서 최종 INT32 결과와 `out_valid` 출력
4. 성기호 MAC의 5-stage latency에 맞춰 first/last/bias metadata 정렬
5. 연속 transaction과 중간 bubble 모두 처리

이는 한 3×3 원자 연산의 재사용 가능성을 입증한 micro-integration이다. 전체 C2f 또는 두 팀원 완제품의 연결 완료를 의미하지 않는다.

## 8. 검증 결과

| 검증 항목 | 결과 | 판정 범위 |
|---|---|---|
| C2f identity topology | PASS | cv1, split, m0, m1, concat, cv2 순서 |
| dense 3×3 cross-channel/padding | PASS | input-channel mixing 및 zero padding |
| signed LUT/rounding/saturation | PASS | 자체 정의 symmetric INT8 계약 |
| 고정 난수 C2f vs 독립 NCHW golden | PASS | 180 output byte bit-exact |
| AXIS64 frame payload | PASS | byte order, count, keep/strb, TLAST |
| 실제 model.6 tensor 크기 | PASS | 204,800 byte, 25,600 beat |
| 제출본 강화 probe | blocker 재현 | nonzero 입력에도 all-zero 출력 |
| Giho MAC + channel accumulator RTL | PASS | 4채널 반복, 중간 bubble, 1채널 first=last, INT8 극값, drain |
| Vitis C/RTL co-sim | 미실행 | Vitis HLS 환경 필요 |
| 합성·timing·resource | 미실행 | Vivado/Vitis 환경 필요 |
| 실제 trained model vector | 미실행 | weight/bias/quant parameter 필요 |
| KV260 board | 미실행 | corrected full IP와 DMA integration 필요 |

RTL 재실행 결과는 다음과 같다.

```text
PASS pixel 0: accumulated INT32 sum=55
PASS pixel 1: accumulated INT32 sum=95
PASS pixel 2: accumulated INT32 sum=-318
PASS pixel 3: accumulated INT32 sum=81
PASS pixel 4: accumulated INT32 sum=231
PASS pixel 5: accumulated INT32 sum=-146136
PASS channel-middle bubble, first==last, INT8 extremes, and drain
RESULT: PASS dense cross-channel 3x3 MAC integration
```

## 9. 성능 관점에서 확인한 하한

정상 model.6의 연산량은 약 314,572,800 scalar MAC이다. 100 MHz에서 15 fps의 frame budget은 약 6,666,667 cycle이므로 memory/control overhead를 제외해도 평균 47.2 MAC/cycle 이상의 병렬성이 필요하다.

현재 export의 latency 628,818 cycle, 약 6.29 ms는 실제 convolution 성능으로 사용할 수 없다. DSP가 0이고 datapath가 상수 0으로 최적화된 결과이기 때문이다.

이번 어댑터가 사용하는 9-lane MAC 한 개는 기능 연결 검증에는 유효하지만, 전체 model.6의 15 fps 구조로는 병렬성이 부족하다.

## 10. 생성 산출물

| 파일 | 역할 |
|---|---|
| [README.md](README.md) | 전체 작업 개요와 재현 방법 |
| [SUBMISSION_AUDIT.md](SUBMISSION_AUDIT.md) | 최신 제출본 판정 근거 |
| [INTEGRATION_CONTRACT.md](INTEGRATION_CONTRACT.md) | model.6·3×3 팀 연결 규격 |
| [RESULTS.md](RESULTS.md) | 실행 결과와 PASS 의미 |
| [include/c2f_candidate.hpp](include/c2f_candidate.hpp) | 기능·양자화·frame payload 계약 |
| [src/c2f_candidate.cpp](src/c2f_candidate.cpp) | portable C2f functional oracle/prototype |
| [rtl_adapter/dense_conv3x3_channel_accumulator.sv](rtl_adapter/dense_conv3x3_channel_accumulator.sv) | 성기호 MAC 채널 누산 어댑터 |
| [tests/tb_dense_channel_accumulator.sv](tests/tb_dense_channel_accumulator.sv) | 어댑터 독립 RTL testbench |
| [tests/tb_c2f_chain.cpp](tests/tb_c2f_chain.cpp) | C2f 독립 golden·directed test |
| [tests/tb_submitted_probe.cpp](tests/tb_submitted_probe.cpp) | 제출본 all-zero blocker 재현 |
| [tools/audit_submission.py](tools/audit_submission.py) | SHA 고정 source/export 자동 감사 |
| [run_all.sh](run_all.sh) | 전체 host/unit 검사 재현 |
| [SHOWCASE.md](SHOWCASE.md) | 5초 성과 요약과 핵심 산출물 링크 |
| [visuals/2026-08-03-progress-onepager.svg](visuals/2026-08-03-progress-onepager.svg) | GitHub용 벡터 성과 보드 |
| [visuals/2026-08-03-progress-onepager.png](visuals/2026-08-03-progress-onepager.png) | 문서·메신저 공유용 PNG 성과 보드 |

모든 신규 작업은 팀원 branch 밖의 별도 `wanmin_model6_help` 폴더에 작성했으며 `Wanmin_Kim`, `Giho_Sung` 원본 worktree는 수정하지 않았다.

## 11. 현재 완료 범위와 미완료 범위

### 완료

- 김완민 담당 model.6 C2f 구조 파악
- 최신 제출본 source/TB/export 고정 및 감사
- 기존 TB의 false-positive 성격 재현
- all-zero datapath blocker 재현
- 올바른 C2f 그래프의 portable functional oracle/prototype 구현
- 독립 golden과 directed test 구축
- 성기호 MAC 재사용 channel accumulator RTL 구현 및 unit simulation
- 팀 간 integration contract와 전체 재현 스크립트 작성

### 미완료

- 실제 64 input-channel 장시간 RTL test
- 40×40 same-padding line/window generator
- 64 input/64 output-channel scheduler와 weight banking
- 실제 model.6 weight/bias 로딩
- 실제 requantization, SiLU, residual scale alignment
- 네 3×3, 두 residual, cv1/cv2의 전체 synthesizable C2f top
- AXIS TVALID/TREADY backpressure 검증
- Vitis C/RTL co-sim, synthesis, timing closure
- KV260 DMA 및 board 검증
- 전체 YOLO backbone/neck/head 연결

## 12. 팀원에게 필요한 입력물

다음 자료를 받으면 synthetic 기능 검증에서 실제 model equivalence 검증으로 넘어갈 수 있다.

1. model.6 여섯 convolution의 BN-folded INT8 weight와 INT32 bias
2. 각 출력 채널의 requant multiplier/shift
3. 각 tensor의 scale과 zero-point
4. 두 residual 경계의 scale alignment 규칙
5. 실제 SiLU LUT 또는 정수 근사 규칙
6. canonical HLS source 하나와 재현 가능한 Vitis Tcl
7. exporter에서 추출한 실제 model.6 input/output golden vector

## 13. 다음 권장 작업

1. 어댑터 testbench를 실제 64 input-channel directed/random case로 확대
2. 한 output channel의 8×8 halo tile 또는 40×40 same-padding scheduler 구현
3. four-corner/edge/center impulse로 window 위치와 padding 검증
4. 실제 weight·quant parameter를 연결해 PyTorch/ONNX vector와 bit-exact 비교
5. 네 3×3와 두 residual을 C2f graph에 연결
6. Vitis HLS C-sim, synthesis, C/RTL co-sim 수행
7. AXI DMA와 연결해 KV260에서 frame 단위 검증

## 14. 재현 방법

```bash
cd /path/to/wanmin_model6_help
./run_all.sh
```

다른 branch 배치를 사용하는 경우:

```bash
WANMIN_SOURCE_DIR=/path/to/Wanmin_Kim \
GIHO_MAC_FILE=/path/to/Giho_Sung/conv_accelerator/rtl/mac_array.sv \
./run_all.sh
```

`tools/hls_shim`은 Mac host의 기능 테스트만 지원하며 Vitis HLS synthesis 또는 cycle-accurate 검증을 대체하지 않는다.

## 15. 종합 결론

8월 3일에는 김완민의 완성품을 단순히 연결한 것이 아니라, 먼저 model.6 C2f의 실제 수학적 구조와 제출본의 기능 상태를 확인했다. 그 결과 현재 export가 all-zero datapath임을 source·host 실행·생성 RTL에서 재현했고, 이를 대신해 올바른 그래프를 비교할 portable 기준 모델과 성기호 3×3 MAC을 dense convolution에 재사용할 channel accumulator RTL을 구축했다.

따라서 오늘 확보한 것은 “완성된 C2f/YOLO IP”가 아니라, 잘못된 PASS를 차단하고 다음 통합을 신뢰성 있게 진행할 수 있는 기능 기준·검증 체계·최소 계산 연결부다.

## 참고 자료

- Ultralytics YOLOv8 architecture: <https://github.com/ultralytics/ultralytics/blob/main/ultralytics/cfg/models/v8/yolov8.yaml>
- Ultralytics C2f/Bottleneck implementation: <https://github.com/ultralytics/ultralytics/blob/main/ultralytics/nn/modules/block.py>
- Audited Wanmin source: <https://github.com/YHJ659/ppe_fpga/blob/e550f959f88854772b7b9ab428bdf3198193b316/model6_c2f_5.cpp>
- Audited Wanmin testbench: <https://github.com/YHJ659/ppe_fpga/blob/e550f959f88854772b7b9ab428bdf3198193b316/tb.cpp>
