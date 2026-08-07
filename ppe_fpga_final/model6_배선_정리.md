# model.6 Vivado 블록디자인 배선 정리 (8개 IP — cv2 SW 이전 후 최종 확정)

> **[최종 상태]** conv1x1_cv2_stream / bn128_router 는 cv2를 소프트웨어로
> 이전하면서 **삭제**됐습니다. 이 문서는 그 최종 배선 기준으로 갱신했습니다.
> Synthesis(LUT 56%/BRAM 84%/URAM 87%/DSP 38%) → Implementation → Timing
> (WNS +0.850ns, 전 제약 충족) → **Generate Bitstream까지 전부 성공**.

기준 파일: conv1x1_stream / conv3x3_stream_selfcount /
bn_silu_stream_selfcount(64) / bn_silu_128_stream_selfcount /
split_channel_stream_dup / residual_add_stream_selfcount /
concat_channel_stream_uram_reshape8 / bottleneck_router_uram

---

## 1. AXI-Stream 직결 표 (최종 15개 연결)

데이터가 흐르는 순서대로. 타입이 양쪽에서 비트 단위로 일치함을 코드로 확인 완료.
**cv1측 bn128_router 경유였던 부분이 직결로, cv2 이후 전체가 concat 출력
경계로 대체**됐습니다.

| # | 출발 (IP.포트) | 도착 (IP.포트) | 타입 (폭) | 비고 |
|---|---|---|---|---|
| 1 | **AXI DMA .M_AXIS_MM2S** | conv1x1_stream .in_s | int8×128 (1024b) | HW 입력 경계. hw_input.bin |
| 2 | conv1x1_stream .out_s | bn_silu_128_stream .in_s | int32×128 (4096b) | ~~bn128_router 경유~~ → **직결** (cv2 제거로 라우터 불필요) |
| 3 | bn_silu_128_stream .out_s | split_channel_stream .in_s | int8×128 (1024b) | ~~bn128_router 경유~~ → **직결** |
| 4 | split .y0_s | concat .y0_s | int8×64 (512b) | |
| 5 | split .y1_router_s | bottleneck_router .y1_s | int8×64 (512b) | |
| 6 | split .y1_concat_s | concat .y1_s | int8×64 (512b) | |
| 7 | bottleneck_router .conv_in_s | conv3x3_stream .in_s | int8×64 (512b) | 프레임당 4회 흐름 |
| 8 | conv3x3_stream .out_s | bn_silu_stream(64) .in_s | int32×64 (2048b) | **라우터 안 거침** — 직결 |
| 9 | bn_silu_stream(64) .out_s | bottleneck_router .bn_out_s | int8×64 (512b) | 4회 되돌림 경로 |
| 10 | bottleneck_router .res_x_s | residual_add .x_s | int8×64 (512b) | ★ FIFO 필요 (5절) |
| 11 | bottleneck_router .res_fx_s | residual_add .fx_s | int8×64 (512b) | ★ FIFO 필요 (5절) |
| 12 | residual_add .out_s | bottleneck_router .res_out_s | int8×64 (512b) | 2회 되돌림 경로 |
| 13 | bottleneck_router .y2_out_s | concat .y2_s | int8×64 (512b) | |
| 14 | bottleneck_router .y3_out_s | concat .y3_s | int8×64 (512b) | |
| 15 | concat .out_s | **AXI DMA .S_AXIS_S2MM** | int8×256 (2048b) | **HW 출력 경계 (변경됨).** hw_output.bin — 이제 256채널(concat 직후) |

**DMA 폭 참고**: DMA는 최종적으로 **32bit(기본값)로 되돌리고, 경계 두 곳
(#1, #15)에 AXI4-Stream Data Width Converter를 추가**해 IP 폭에 맞췄습니다
(자원 디버깅 이력 — 4절 참고). Converter 폭 설정: #1측 32↔1024bit, #15측
**32↔2048bit**(256byte — cv2 제거로 출력이 256채널이 됐으므로 128byte 아님에
주의). 내부의 2048/4096bit 연결은 IP끼리 직결이라 DMA 제한과 무관합니다.

**SW 쪽 영향**: HW 출력이 이제 128채널이 아니라 **256채널**입니다.
`sw_model7up.py`가 이 256채널을 받아 `conv1x1(cv2) + BN + SiLU`를 소프트웨어로
계산한 뒤 model.7로 넘기도록 수정이 필요합니다 (5단계 전 필수, 아직 미완료).

---

## 2. PS가 값을 써넣는 포트 → 사실은 전부 "빌드 시점 고정값"

처음엔 이 13개 포트를 "PS가 런타임에 AXI로 써야 하는 값"으로 잡았으나,
실제로는 전부 **웹캠 프레임이 뭐가 들어오든 절대 안 바뀌는 상수**임이
확인됐습니다 — 가중치는 `best.pt`에서, 스케일은 valid_dataset 114장
보정에서 딱 한 번 계산되고 끝. 그래서 PS가 AXI로 쓸 필요가 원천적으로
없고, **13개 전부 `.coe` + Block Memory Generator(Stand-Alone)로
비트스트림에 미리 박아넣습니다.** AXI Interconnect도, AXI BRAM
Controller도 이 13개 포트에는 등장하지 않습니다.

| IP | 포트 | 원소 타입/개수 | 만드는 스크립트 |
|---|---|---|---|
| conv1x1_stream | weight | int8 × 16,384 | bin_to_coe.py |
| conv3x3_stream | weight | int8 × 147,456 (4벌 합산) | bin_to_coe_multiset.py |
| bn_silu_stream(64) | bn_scale, bn_shift | float32 × 256 (4벌×64) | extract_scale_bins.py → bin_to_coe_float.py |
| | input_scale, weight_scale, output_scale | float32 × 4 | 〃 |
| bn_silu_128_stream | bn_scale, bn_shift | float32 × 256 (2벌×128, **단 두 슬롯 모두 cv1측 값**) | 〃 |
| | input_scale, weight_scale, output_scale | float32 × 2 (**두 슬롯 모두 cv1측 값**) | 〃 |
| residual_add | x_scale, fx_scale, output_scale | float32 × 2 | 〃 |

**[cv2 제거 후 정정]** `conv1x1_cv2_stream`의 weight 행은 IP 자체가 삭제되어
표에서 제거했습니다. `bn_silu_128_stream`은 이제 프레임당 **1회만** 호출되지만
(cv1측만 남음), `N_SET=2` 구조의 HLS 재합성 없이 그대로 쓰기 위해 **두 슬롯에
cv1측 값을 똑같이 채운 `.coe`로 재생성**했습니다 — `call_counter`가 0이든
1이든 항상 같은 (올바른) 값을 쓰게 되어 결과에 영향이 없습니다.

★ **concat은 위 표에서 예외입니다.** `scale0~3`, `output_scale` 다섯 개는
`#pragma HLS INTERFACE s_axilite`로 선언되어 **bram이 아니라
s_axi_control 레지스터**입니다. 즉 BMG/PORTA 배선이 전혀 필요 없고,
이미 ap_start 트리거용으로 연결해둔 M_AXI_HPM → s_axi_control 경로
그대로 값을 씁니다. **Vivado에서 할 배선 작업이 없습니다** — 4단계
PS 부팅 코드에서 해당 레지스터 오프셋에 5개 값을 한 번 write하면
끝입니다(Auto Restart 비트 쓰는 것과 같은 시점/방식).

**공통 절차** (13개 전부 동일):
1. IP Catalog에서 Block Memory Generator 추가 (핀에서 자동화 실행 X,
   빈 캔버스에 직접 추가)
2. Basic 탭 → **Stand-Alone** 모드 (AXI4 모드는 폭/Load Init File이 잠김)
3. Port A/B Options → Width를 원소 타입에 맞춤 (weight=8, 나머지=32),
   Depth를 원소 개수에 맞춤
4. Memory Type → True Dual Port RAM (또는 대상 IP 포트가 1개뿐이면
   Single Port로도 가능 — Interface 탭에서 포트 개수 먼저 확인)
5. Other Options → Load Init File 체크 → 해당 `.coe` 지정
6. PORTA(/PORTB)를 대상 IP의 `xxx_PORTA`(/`PORTB`)에 **직접 수동 드래그**
   연결

`s_axilite`(concat의 scale류는 s_axilite 스칼라로도 노출됨)는 이 경우도
값이 고정이라 s_axilite 레지스터에 부팅 시 1회만 쓰면 되고, 그마저도
Constant 값을 IP 외부 어딘가에서 미리 정해 넣거나 PS 부트코드 한 줄로
처리 가능 — AXI Interconnect가 꼭 필요하진 않음 (다만 s_axilite는
bram과 달리 이미 s_axi_control 레지스터 체계 안에 있어 별도 BMG가
필요 없음).

> **각주 — 이런 경우엔 AXI BRAM Controller + BMG 3단 구조가 필요합니다**:
> 만약 나중에 "프레임마다, 또는 실행 중에 값을 바꿔야 하는" bram
> 포트가 생기면(이 프로젝트에는 없음), 그때는 아래 구조로 갑니다.
> ```
> [PS, M_AXI_HPM] --AXI--> [AXI BRAM Controller] --BRAM_PORTA-->
> [Block Memory Generator, True Dual Port] --BRAM_PORTB--> [IP의 xxx_PORTA]
> ```
> Connection Automation이 이 3단 구조를 자동으로 만들어주며, 이 경우엔
> 자동 생성된 BMG를 지우면 안 됨 (실제 물리 메모리이자 PS/IP 공유 지점).

---

## 3. 제어(시작) 설정 — IP별로 3부류

### (a) Auto Restart 켜기 — s_axi_control CTRL 레지스터 bit7

**[정정] 대상이 4개 → 6개로 늘어남.** 처음엔 "프레임 안에서 여러 번
재사용되는 IP"만 대상으로 잡았으나, PS가 부팅 시 1회만 개입하고 그 뒤로
**프레임마다도** 다시 개입하지 않는 게 목표라면, "프레임마다 최소 1회는
반드시 실행돼야 하는" IP 전부가 대상이어야 합니다. PS 코드에서 프로그램
시작 시 1회:
```c
*ctrl = (1<<7) | (1<<0);   // auto_restart + ap_start
```
- conv3x3_stream (프레임당 4회 자동 재시작)
- bn_silu_stream(64) (4회)
- residual_add_stream (2회)
- bn_silu_128_stream (cv2 제거로 이제 **1회** — 그래도 프레임마다 필요하므로 대상)
- **concat_channel_stream** (프레임당 1회 — 추가)
- **bottleneck_router** (프레임당 1회, STEP1~10이 한 호출 안에 있음 — 추가)

### (b) 이제 해당 없음

~~"프레임당 1회 트리거"로 따로 분류했던 항목~~ — 위 (a)로 통합됨. 프레임당
1회든 여러 번이든, "PS 개입 없이 반복 실행돼야 한다"는 조건은 동일하므로
전부 Auto Restart 대상입니다.

### (c) ap_start 핀을 상수 1로 묶기 — s_axi_control이 아예 없는 IP
아래 2개는 코드에 `s_axilite port=return`이 없어 제어가 **핀으로** 나옴.
블록디자인에서 **Constant IP(값 1)** 를 만들어 ap_start 핀에 연결:
- conv1x1_stream
- split_channel_stream

(~~conv1x1_cv2_stream~~ — cv2 제거로 이 IP 자체가 삭제됨)

스트림이 비어 있으면 read에서 알아서 멈추므로 항상 켜둬도 안전함.
(원하면 나중에 s_axilite return을 추가해 (a)류로 통일해도 되지만 재합성 필요 —
지금은 Constant로 충분)

---

## 4. 공통 배선

- **클럭**: 전 IP + AXI DMA + Width Converter 2개 + Block Memory Generator(BMG)
  전부 동일 100MHz (PS FCLK)
- **리셋**: Processor System Reset의 peripheral_aresetn 공유
- **AXI Interconnect**: PS M_AXI_HPM0_FPD → (각 IP의 s_axi_control들 + AXI DMA의
  S_AXI_LITE). 12개 BMG는 위 2절대로 AXI와 무관하게 독립 배선되므로
  Interconnect에 안 걸림
- **AXI DMA 설정 [정정]**: 처음엔 Stream/Memory Map Data Width를 IP 폭(1024bit)
  에 맞췄으나, 이게 DMA 내부 엘라스틱 버퍼를 과도하게 키워 BRAM 33개를
  소모함이 밝혀짐(자원 디버깅 이력). **최종적으로 32bit(기본값)로 되돌리고,
  경계 두 곳에 AXI4-Stream Data Width Converter를 추가**하는 구조로 확정.
  Direct Register Mode(SG 끔), Control/Status Stream 끔, Read/Write 채널
  둘 다 활성, 버스트 최대(16)

---

## 5. ★ 주의 — FIFO를 넣어야 하는 곳

### 데드락 위험 (반드시 조치)
`bottleneck_router` STEP3_4/STEP8_9는 **fx를 먼저 쓰고 x를 나중에** 쓰는데,
`residual_add`는 **x를 먼저 읽고 fx를 나중에** 읽음. FIFO 없이 직결하면
서로 상대를 기다리며 멈출 수 있음 (C-sim에서는 무한 FIFO라 안 드러남).

→ **#10(res_x_s), #11(res_fx_s) 경로에 AXI4-Stream Data FIFO (depth 16,
Distributed RAM 명시 — Auto/Block/Ultra RAM은 자원 예산 위험하므로 배제) 삽입**

### 권장 (여유 버퍼)
도착 시점 차이가 큰 경로들 — 필수는 아니나 depth 16 정도 넣어두면 안전:
- #6 split.y1_concat_s → concat.y1_s (concat이 늦게 소비)
- #13, #14 라우터 → concat (y2/y3가 늦게 도착)
- #9, #12 되돌림 경로들 (라우터가 읽는 시점이 단계별로 다름)

---

## 6. 배선 후 체크리스트 — **전부 완료**

1. ✅ Validate Design 통과 (MASTER_TYPE 딱지 불일치 경고 다수 + DMA TLAST
   경고 1개는 무해로 확인, 에러 없음)
2. ✅ Address Editor에서 각 s_axi_control 주소 확인 완료 — 전부
   M_AXI_HPM0_FPD 하나에 충돌 없이 정상 배정
3. ✅ 전체 합성 자원 확인(최종): **LUT 65,659(56%)**, BRAM 121.5(84%),
   URAM 56(87%), DSP 472(38%) — cv2 SW 이전으로 LUT 41,126개 감소, 예산
   내 확보 (자원 디버깅 전체 이력은 model6_c2f_구현_정리.md 14~17절 참고)
4. ✅ Timing 확인: WNS +0.850ns, WHS +0.009ns, Failing Endpoints 0,
   "All user specified timing constraints are met."
5. ✅ **Generate Bitstream 성공** → Export Hardware(`.xsa`, include
   bitstream) 완료
6. ⬜ (다음 단계) KV260에 비트스트림 로드 → 4단계 PS 제어 코드 작성
   (Auto Restart 대상 6개 IP, concat s_axilite 5개 값 write) → 5단계
   SW/HW 대조 테스트
