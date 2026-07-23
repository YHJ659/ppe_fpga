# 3x3 Convolution Accelerator (RTL)

PPE 안전 모니터링 프로젝트의 CNN 가속 파트 중, **3x3 컨볼루션 연산기를 SystemVerilog로 직접 설계**한 모듈입니다.

- **Target Board**: Kria KV260 (xck26-sfvc784-2LV-c)
- **Tool**: Vivado 2022.2
- **Target Clock**: 150 MHz (6.667 ns)
- **Dataflow**: Weight-Stationary Direct Convolution
- **Data Type**: INT8 signed 입력 / INT32 signed 누적

---

## 1. 설계 개요
| 모듈 | 역할 |
|---|---|
| `input_buffer.sv` | 입력 피처맵 저장 (BRAM 스타일, 읽기 latency 1클럭) |
| `window_gen.sv` | 라인버퍼 2줄로 3x3 윈도우 9픽셀 동시 출력 |
| `mac_array.sv` | INT8 곱셈 9개 병렬 + Adder Tree 4단 파이프라인 |
| `output_buffer.sv` | INT32 누적 결과 저장 |
| `controller.sv` | 주소 발행, 파이프라인 지연 보정, 완료 판정 FSM |
| `conv_top.sv` | 위 5개 모듈 통합 |

---

## 2. 설계 포인트

### 2.1 MAC Array 파이프라인 분할 (150MHz 확보의 핵심)

곱셈 결과 9개를 한 번에 더하면 조합논리 경로가 길어져 150MHz를 만족할 수 없습니다.
Adder Tree를 4단으로 분할하고 각 단 사이에 레지스터를 삽입했습니다.
총 latency 5클럭. valid 신호를 shift register로 동일하게 지연시켜 데이터와 동기화했습니다.

### 2.2 BRAM 읽기 지연 보정

BRAM은 주소 인가 후 **다음 클럭**에 데이터가 출력됩니다.
Controller에서 ib_rd_en을 1클럭 지연시킨 신호를 window_gen의 in_valid로 사용해
데이터 유효 타이밍을 정확히 맞췄습니다.

### 2.3 파이프라인 Drain 상태

마지막 주소를 발행한 뒤에도 파이프라인에 남은 데이터가 출력되기까지 7클럭이 필요합니다.
FSM에 S_DRAIN 상태를 두어 모든 결과가 저장된 후 done을 발생시킵니다.
---

## 3. 검증 결과

### 3.1 모듈별 단위 검증

| 모듈 | 테스트 내용 | 결과 |
|---|---|---|
| input_buffer | 쓰기/읽기 8개, 1클럭 latency 확인 | PASS 8/8 |
| output_buffer | 32비트 대용량 값 + 음수 처리 | PASS 8/8 |
| window_gen | 8x8 입력에서 유효 윈도우 생성 | 36개 정확 생성 |
| mac_array | 최대/최소/음수/Sobel 등 6종 | PASS 6/6 |
| controller | FSM 상태 전이, drain 타이밍 | PASS |

**mac_array 경계값 검증**

| 테스트 | 계산 | 결과 |
|---|---|---|
| 최대값 | 127 x 127 x 9 | 145,161 |
| 최소값 | (-128) x (-128) x 9 | 147,456 |
| Sobel 필터 | 실제 엣지 검출 커널 | 80 |

### 3.2 통합 검증 (Golden Model 대조)

테스트벤치 내 소프트웨어 컨볼루션 모델과 RTL 출력을 전수 비교했습니다.

| 테스트 | 조건 | 결과 |
|---|---|---|
| TEST1 | 순번 이미지 + all-1 필터 | 36/36 일치 |
| TEST2 | 순번 이미지 + Sobel 필터 | 36/36 일치 |
| TEST3 | 랜덤 이미지 + 랜덤 필터 | 36/36 일치 |

**총 108/108 bit-exact 일치**

### 3.3 타이밍 검증 (Implementation)
목표 주기 6.667 ns 대비 **3.789 ns 여유**.
실제 최소 동작 주기 약 2.878 ns (**최대 약 347 MHz**)로, 목표 대비 2.3배 마진을 확보했습니다.

---

## 4. 재현 방법

### 4.1 시뮬레이션

1. Vivado에서 RTL Project 생성 (Board: Kria KV260)
2. rtl/ 파일을 Design Sources로 추가
3. tb/ 파일을 Simulation Sources로 추가
4. 검증할 테스트벤치를 Set as Top
5. Run Behavioral Simulation
6. **tb_conv_top은 실행 시간을 50us로 설정** (Tcl: `run 50us`)

### 4.2 합성 및 타이밍 확인

1. constraints/timing.xdc를 Constraints로 추가
2. conv_top을 Set as Top
3. Settings -> Synthesis -> More Options에 `-mode out_of_context` 추가
   - 이유: 현재 최상위 모듈이지만 실제로는 AXI로 PS에 연결될 IP이므로,
     물리 핀 배치를 생략하고 내부 타이밍만 검증
4. Run Synthesis -> Run Implementation
5. Reports -> Timing -> Report Timing Summary

---

## 5. 파라미터

| 파라미터 | 기본값 | 설명 |
|---|---|---|
| IMG_SIZE | 8 | 입력 피처맵 한 변 |
| DATA_W | 8 | 입력/가중치 비트폭 (INT8) |
| ACC_W | 32 | 누적 결과 비트폭 (INT32) |
| OUT_SIZE | 6 | 출력 크기 (IMG_SIZE - 2, padding 미적용) |

현재 8x8 기준으로 메모리가 작아 분산 RAM(LUTRAM)으로 합성됩니다.
크기를 키우면 Block RAM으로 매핑됩니다.

---

## 6. 진행 상황

- [x] RTL 5개 모듈 설계
- [x] 모듈별 단위 검증
- [x] 통합 검증 (Golden Model 대조)
- [x] 합성 및 150MHz 타이밍 검증
- [ ] AXI-Lite 인터페이스 추가
- [ ] IP 패키징
- [ ] Block Design 통합
- [ ] Bitstream 생성 및 보드 검증

---

## 7. 한계 및 개선 예정

- **Padding 미지원**: 현재 valid 영역만 출력 (8x8 -> 6x6)
- **단일 채널**: 다채널 입력 시 PSUM 누적 로직 추가 필요
- **Requantization 미포함**: INT32 결과를 INT8로 되돌리는 단계 미구현
- **출력 주소 범위 체크 없음**: Controller에 wr_cnt 상한 조건 추가 권장
