# model.6 (C2f 블록) FPGA 구현 정리

> 목적: model.6을 하드웨어(FPGA)로, 나머지 레이어를 소프트웨어(PS)로 처리하는
> 하이브리드 구조에서, model.6 내부 **10개 IP**(계산 8개 + 라우터 2개)를
> 어떻게 설계·검증했고 Vivado에서 어떻게 연결해야 하는지 정리한 문서입니다.

> **[진행 상황 안내]** 아래 0~11절은 IP 설계·검증 단계까지의 기록입니다.
> 그 이후(layer_id 동기화 재해결, 시스템 통합 SW 1~3단계, 실제 Vivado 배선,
> 자원 디버깅, **cv2 SW 이전을 통한 최종 해결 및 Bitstream 생성 완료**)는
> **12절부터** 이어서 정리했습니다. 특히 3.1/7/8/9/11/14절 일부 내용은 이후
> 변경됐으니, 해당 위치에 표시해둔 정정 노트를 참고하세요.
>
> **현재 상태: 하드웨어 구현 완료** (Synthesis / Implementation / Timing /
> Bitstream 전부 통과 — 최종 자원 LUT 56%, BRAM 84%, URAM 87%, DSP 38%).
> 자세한 내용은 **17절** 참고.

---

## 0. 전체 시스템 아키텍처

**YOLOv8n 중 model.6(C2f 블록)만 하드웨어로 구현하고, 나머지(model.0~5,
model.7 이후)는 전부 소프트웨어(PS)로 처리하는 하이브리드 구조입니다.**

```
[SW] model.0~5  →  feature map  →  [HW] model.6 (이 문서의 대상)  →  feature map  →  [SW] model.7~
```

- model.5까지 PS에서 계산한 feature map을 하드웨어 model.6에 전달
- model.6(FPGA)의 출력 feature map을 다시 소프트웨어 model.7로 전달
- **하드웨어로 재설계해야 하는 범위는 model.6 하나뿐입니다** — model.0~5의
  구조 변경(예: 입력 해상도 축소)은 소프트웨어 쪽 재실행만으로 충분하고,
  하드웨어 재설계는 필요 없습니다.

---

## 1. 배경 스펙

| 항목 | 값 |
|---|---|
| 대상 | YOLOv8n의 model.6 (C2f 블록, 128채널, Bottleneck 2개) |
| 입력 해상도 | 640×640 (특징맵 기준 40×40) |
| 클럭 | 100MHz |
| 목표 프레임레이트 | 10~15fps |
| 양자화 | INT8 (DSP 패킹 없이 기본 INT8 MAC) |
| 타겟 보드 | KV260/XCK26 (LUT 117,120 / **BRAM18 144** / URAM 64 / DSP 1,248, Vivado Parts로 확인) |

> **정정**: 이전에 BRAM 예산을 288개로 잘못 가정하고 계산해왔습니다. Vivado
> Parts에서 확인한 실제 값은 **144개**입니다. LUT(117,120)와 DSP(1,248)는
> 원래 맞았습니다. 8절의 자원 현황은 이 정정된 값 기준입니다.

---

## 2. C2f 구조

```
입력(128ch)
   │
   ▼
 Conv (cv1, 1x1, 128→128)
   │
   ▼
 Split ──────────────┬─────────────────┐
   │ y0(64ch)         │ y1(64ch)        │
   │ (그대로 보관)      ▼                 │
   │            Bottleneck 1            │
   │         (Conv3x3→Conv3x3→덧셈)      │
   │                  │ y2(64ch)        │
   │                  ▼                 │
   │            Bottleneck 2            │
   │         (Conv3x3→Conv3x3→덧셈)      │
   │                  │ y3(64ch)        │
   ▼                  ▼                 │
 ┌─────────────────────────────────────┐
 │     Concat(y0, y1, y2, y3) → 256ch  │
 └─────────────────────────────────────┘
   │
   ▼
 Conv (cv2, 1x1, 256→128)
   │
   ▼
 출력(128ch)
```

**핵심 포인트**
- `y0`, `y1`은 Split 직후 값 그대로 Concat에 들어갑니다 (Bottleneck을 거치지 않음).
- `y2`는 Bottleneck1의 출력이며, 동시에 Bottleneck2의 입력입니다.
- `y3`는 Bottleneck2의 출력으로, 4개 branch 중 **가장 늦게 도착**합니다.
- 각 Bottleneck 내부: `Conv2d → BatchNorm2d → SiLU`가 두 번 반복된 뒤,
  입력(shortcut)과 결과를 더합니다.

---

## 3. IP 목록 (10종 — conv1x1 cv1/cv2 각각 별도 IP + 라우터 2종)

| IP | 역할 | 채널 (in→out) | 프레임당 호출 횟수 |
|---|---|---|---|
| `conv1x1_stream` | cv1 (확장) | 128→128 | 1 |
| `split_channel_stream` | 채널 분리 (y1을 라우터용/concat용 2벌로 복제) | 128→64+64+64 | 1 |
| `conv3x3_stream` | Bottleneck 내부 conv | 64→64 | **4** (Bottleneck 2개 × 2) |
| `bn_silu_64_stream` | conv3x3 뒤 BN+SiLU | 64→64 | **4** |
| `residual_add_stream` | Bottleneck 덧셈 | 64+64→64 | **2** |
| **`bottleneck_router`** | **conv3x3/bn_silu_64/residual_add 재사용 배선 담당** | 64ch, 계산 없음 | 1 (내부에서 10단계 처리) |
| `bn_silu_128_stream` | cv1/cv2 뒤 BN+SiLU | 128→128 | **2** (cv1 뒤, cv2 뒤) |
| **`bn128_router`** | **bn_silu_128 재사용 배선 담당 (신규)** | 128ch, 계산 없음 | 1 (내부에서 4단계 처리) |
| `concat_channel_stream` | 4-branch 병합 | 64×4→256 | 1 |
| `conv1x1_cv2_stream` | cv2 (축소) | 256→128 | 1 |

**주의**: `conv1x1_cv1`과 `conv1x1_cv2`는 입력 채널 수(128 vs 256)가 달라
**재사용이 불가능한 완전히 별개의 물리적 IP**입니다 — "conv1x1"이라는 이름
하나로 묶어 세면 개수를 잘못 셉니다(9개로 착각하기 쉬움). 정확히는 10개입니다.

**"4벌 재사용"이 의미하는 것**: `conv3x3_stream`을 Vivado에 4개 따로 배치하는 게
아니라, **IP 인스턴스는 1개만 두고 Bottleneck 1의 conv1 → conv2 → Bottleneck 2의
conv1 → conv2 순서로 같은 회로를 순차 재사용**합니다. 물리적으로 4벌을 두면
LUT가 4배로 필요해 KV260 예산을 넘습니다. `bn_silu_64`, `residual_add`도 동일한
이유로 각각 1개 IP만 배치하고 재사용합니다.

### 3.1 왜 `bottleneck_router`가 필요한가

conv3x3/bn_silu_64/residual_add를 1벌씩만 두고 재사용하면, **이 IP들의 입력이
매번 다른 곳에서 와야 합니다** (예: conv3x3의 입력이 어떤 때는 split.y1, 어떤
때는 자기 자신의 이전 출력의 루프백, 어떤 때는 Bottleneck1의 결과). AXI-Stream은
고정 배선이라 이 동적 라우팅을 스트림 자체로는 표현할 수 없습니다.

검토했던 대안과 결과:
- **Bottleneck 전체를 하나의 큰 HLS IP로 통합** → 배선 문제는 풀리지만 내부
  DATAFLOW가 conv3x3을 2벌(conv1/conv2)로 중복 생성해 LUT 168K/BRAM 438로 폭증 (기각)
- **conv3x3/bn_silu_64/residual_add의 스트림 포트를 `m_axi`(DDR)로 바꿔 PS가
  중계** → latency가 21배(262ms) 폭증 (기각)
- **`bottleneck_router` IP로 배선을 라우팅** → 계산 없이 10단계 순서로 스트림을
  중계·버퍼링만 하는 전용 IP. 채택.

`bottleneck_router`는 계산이 전혀 없고, y1/y2(shortcut 값)을 나중 단계까지
붙잡아두는 프레임 버퍼 + 스트림 중계가 전부입니다. Latency 15.86ms는 병목인
conv3x3 4회 재사용(약 50ms)에 비해 무시할 수준입니다.

### 3.2 split의 y1 복제 — 설계 검토 중 발견한 누락

split의 `y1`(가공되지 않은 원본)은 **두 곳**에 필요합니다.

1. `bottleneck_router.y1_s` — Bottleneck1의 conv1 입력이자 residual_add의 shortcut
2. `concat.y1_s` — 가공되지 않은 원본 그대로

`y2`(Bottleneck1 결과), `y3`(Bottleneck2 결과)는 라우터가 `residual_add`로부터
결과를 한 번만 받아서 **내부적으로** concat용/버퍼용으로 나눠주니 문제가
없었지만, `y1`은 split에서 나오는 순간 **라우터 바깥(concat)과 라우터 안
(Bottleneck1) 양쪽으로 동시에 가야** 하고 라우터는 concat과 직접 연결돼 있지
않으므로, **split 단계에서 미리 갈라놔야** 합니다.

`split_channel_stream`의 출력 포트를 `y0_s`, `y1_router_s`, `y1_concat_s`
3개로 만들고, `y1` 계산 결과를 두 스트림에 그대로 복제해 씁니다. 계산이 없는
IP라 자원 부담은 거의 없습니다(LUT 110→119).

### 3.3 `bn128_router` — bn_silu_128의 재사용 배선 (신규)

bn_silu_128도 프레임당 2번 재사용됩니다(cv1 뒤, cv2 뒤). `bottleneck_router`와
똑같은 이유로 라우팅이 필요한데, **성격은 훨씬 단순**합니다 — 나중에 다시
꺼내 쓸 shortcut 값이 없고, 그냥 "1번째는 A쪽, 2번째는 B쪽"으로 순서대로
전환하기만 하면 됩니다.

```
1번째: conv1x1(cv1).out_s → bn_silu_128.in_s → bn_silu_128.out_s → split.in_s
2번째: conv1x1(cv2).out_s → bn_silu_128.in_s → bn_silu_128.out_s → DMA(쓰기)
```

`bn128_router`는 버퍼링 없이 4단계 순수 전달(pass-through)만 합니다. 그래서
자원이 매우 가볍습니다(LUT 463, BRAM/DSP/URAM 0) — `bottleneck_router`
(LUT 6,388)와 비교하면, "재사용마다 라우터가 필요하다"는 게 맞지만 그
**라우터의 복잡도는 재사용 패턴에 따라 크게 다르다**는 걸 보여주는 사례입니다.

**재사용 IP가 항상 이런 라우터를 필요로 하는 건 아닙니다** — conv1x1(cv1)과
conv1x1(cv2)는 채널 수가 달라(128 vs 256) 아예 재사용이 불가능한 별개의
물리적 IP라서, 이런 라우팅 문제 자체가 발생하지 않습니다.

---

## 4. IP 연결 방식 — AXI-Stream + DMA

### 4.1 데이터 경로: 전부 AXI-Stream

IP끼리는 배열이 아니라 **AXI-Stream(`ready`/`valid` 핸드셰이크)**으로 직결합니다.
Block Design에서 한 IP의 출력 스트림 포트를 다음 IP의 입력 스트림 포트에
선으로 연결하면 됩니다.

```
DMA(읽기) → conv1x1(cv1) → bn128_router.cv1_out_s
                                   │
                          bn128_router.bn_in_s → bn_silu_128 → bn128_router.bn_out_s
                                   │                                      │
                          (1번째: split.in_s로) ←─────────────────────────┘
                                   ▼
                                 split ─┬→ y0 (concat으로 직행)
                                        ├→ y1_concat_s → concat으로 직행
                                        └→ y1_router_s → bottleneck_router ←→ conv3x3
                                                                            ←→ bn_silu_64
                                                                            ←→ residual_add
                                                    │
                                          (y2_out_s, y3_out_s) → concat
                                                                → conv1x1(cv2) → bn128_router.cv2_out_s
                                                                                       │
                                                              bn128_router.bn_in_s → bn_silu_128 → bn128_router.bn_out_s
                                                                                       │
                                                              (2번째: final_out_s로) → DMA(쓰기)
```

**`bn128_router`의 포트 6개와 연결 대상:**

| 라우터 포트 | 방향 | Vivado에서 연결할 곳 |
|---|---|---|
| `cv1_out_s` | 입력 | ← `conv1x1(cv1).out_s` |
| `cv2_out_s` | 입력 | ← `conv1x1(cv2).out_s` |
| `bn_out_s` | 입력 | ← `bn_silu_128.out_s` |
| `bn_in_s` | 출력 | → `bn_silu_128.in_s` |
| `split_in_s` | 출력 | → `split.in_s` |
| `final_out_s` | 출력 | → DMA(쓰기) |

**`bottleneck_router`의 포트 8개와 연결 대상** (2절 참고):

| 라우터 포트 | 방향 | Vivado에서 연결할 곳 |
|---|---|---|
| `y1_s` | 입력 | ← `split.y1_s` |
| `bn_out_s` | 입력 | ← `bn_silu_64.out_s` |
| `res_out_s` | 입력 | ← `residual_add.out_s` |
| `conv_in_s` | 출력 | → `conv3x3.in_s` |
| `res_x_s` | 출력 | → `residual_add.x_s` |
| `res_fx_s` | 출력 | → `residual_add.fx_s` |
| `y2_out_s` | 출력 | → `concat.y2_s` |
| `y3_out_s` | 출력 | → `concat.y3_s` |

**단, `conv3x3.out_s → bn_silu_64.in_s`는 라우터를 거치지 않고 직결**합니다.
conv3x3 뒤에는 항상 bn_silu_64가 오는 고정 관계라 라우팅이 필요 없는 유일한 구간입니다.

### 4.2 DMA는 양 끝단에만

DMA(AXI-DMA 또는 유사 IP)는 **DDR ↔ 첫 IP**, **마지막 IP ↔ DDR** 두 곳에만
필요합니다. IP들 사이(예: conv1x1 → bn_silu_128)는 둘 다 스트림 인터페이스라
DMA 없이 직결됩니다.

### 4.3 픽셀 데이터 형식 (모든 스트림 공통)

모든 IP는 **픽셀 우선(pixel-major), 채널이 안쪽**인 구조체를 스트림 원소로
씁니다.

```c
typedef struct { ap_int<8>  ch[CH]; } pix_t_int8;   // 대부분의 IP 입출력
typedef struct { ap_int<32> ch[CH]; } pix_t_int32;  // conv 계열 출력(재양자화 전)
```

한 원소 = 한 픽셀의 전 채널. `(0,0)`의 채널 64개 → `(0,1)`의 채널 64개 →
... 래스터 순서로 흐릅니다.

### 4.4 concat의 스킵 버퍼 (예외 구조)

`y0`, `y1`, `y2`는 `y3`보다 훨씬 먼저 도착하므로, concat IP 내부에
**프레임 전체를 담는 버퍼(BRAM)**를 만들어 `y3` 도착 시점까지 보관합니다.
이건 concat IP 내부에서 자체적으로 처리하므로, Block Design에서는
일반 스트림 포트 4개(y0_s~y3_s)로만 보이면 됩니다.

---

## 5. 파라미터 공급 방식 — 이게 이 문서의 핵심입니다

IP가 픽셀 데이터 외에 필요로 하는 값은 두 종류입니다. **종류에 따라
Vivado에서 다르게 연결**해야 합니다.

### 5.1 스칼라 값 → `s_axilite` (추가 IP 불필요)

`layer_id`, `input_scale`, `output_scale`처럼 값 하나짜리 파라미터는
HLS 코드에 `#pragma HLS INTERFACE s_axilite`로 지정돼 있습니다.
**Vivado가 이 IP에 AXI4-Lite 레지스터를 자동 생성**하므로, PS가
해당 IP의 메모리 주소에 값을 쓰기만 하면 됩니다. 별도 IP 없이 PS ↔ 대상
IP 사이에 AXI4-Lite 배선만 연결하면 됩니다.

### 5.2 배열 값 → `bram` 인터페이스 + `AXI BRAM Controller` 필요

가중치(`weight[][][][]`), BatchNorm 파라미터(`bn_scale[]`, `bn_shift[]`)처럼
배열 전체를 넘겨야 하는 파라미터는 `#pragma HLS INTERFACE bram`으로
지정돼 있습니다. AXI4-Lite로는 원소 하나씩 밖에 못 보내 비효율적이므로,
**실제 BRAM 메모리를 하나 두고 PS와 IP 양쪽이 접근**하게 만들어야 합니다.

```
PS ── AXI 버스 ── AXI BRAM Controller ── BRAM ── (bram 포트) ── 대상 IP
```

이 조합(`AXI BRAM Controller` + `BRAM`)을 **파라미터 배열마다 하나씩**
Block Design에 추가해야 합니다.

> **참고**: `m_axi`로 전환하면 이 BRAM Controller 배선을 생략하고 IP가
> DDR을 직접 읽게 만들 수 있습니다. 아직 적용 안 했고, 추후 검토 예정입니다.

### 5.3 파라미터 세트 전체 목록 (총 15세트)

아래는 **PS가 프레임 처리 순서에 맞춰 언제 무슨 값을 써넣어야 하는지**의
전체 목록입니다. `golden_reference.py`류 스크립트로 전부 미리 뽑아둔 값입니다.

| # | IP | 세트 위치 | 필요한 값 | 갱신 방식 |
|---|---|---|---|---|
| 1 | conv1x1 (cv1) | cv1 | weight[128][128] | 1회 로드 (재사용 없음) |
| 2 | bn_silu_128 | cv1 뒤 | bn_scale[128], bn_shift[128], input/weight/output_scale | **매번 PS가 갱신** (캐싱 없음) |
| 3 | conv3x3 | Bottleneck1-conv1 | weight[64][64][3][3] | `layer_id=0`으로 최초 로드 |
| 4 | bn_silu_64 | Bottleneck1-conv1 뒤 | bn_scale[64], bn_shift[64], scale들 | **매번 PS가 갱신** |
| 5 | conv3x3 | Bottleneck1-conv2 | weight[64][64][3][3] | `layer_id=1`로 전환 시 재로드 |
| 6 | bn_silu_64 | Bottleneck1-conv2 뒤 | bn_scale[64], bn_shift[64], scale들 | **매번 PS가 갱신** |
| 7 | residual_add | Bottleneck1 덧셈 | x_scale, fx_scale, output_scale | 매번 PS가 갱신 |
| 8 | conv3x3 | Bottleneck2-conv1 | weight[64][64][3][3] | `layer_id=2`로 전환 시 재로드 |
| 9 | bn_silu_64 | Bottleneck2-conv1 뒤 | bn_scale[64], bn_shift[64], scale들 | 매번 PS가 갱신 |
| 10 | conv3x3 | Bottleneck2-conv2 | weight[64][64][3][3] | `layer_id=3`으로 전환 시 재로드 |
| 11 | bn_silu_64 | Bottleneck2-conv2 뒤 | bn_scale[64], bn_shift[64], scale들 | 매번 PS가 갱신 |
| 12 | residual_add | Bottleneck2 덧셈 | x_scale, fx_scale, output_scale | 매번 PS가 갱신 |
| 13 | concat | 4-branch 병합 | scale0~3, output_scale | 1회 (재사용 없음) |
| 14 | conv1x1 (cv2) | cv2 | weight[128][256] | 1회 로드 (재사용 없음) |
| 15 | bn_silu_128 | cv2 뒤 | bn_scale[128], bn_shift[128], scale들 | **매번 PS가 갱신** (2번째 세트로 교체) |

### 5.4 conv3x3의 `layer_id` 캐싱 동작

conv3x3은 내부에 `local_weight`를 캐싱해두고, `layer_id`가 이전 호출과
다를 때만 재로드합니다.

```c
static int last_loaded_id = -1;
if (last_loaded_id != layer_id) {
    // weight를 BRAM에서 다시 읽어옴 (약 20,480사이클, 1회성 비용)
    last_loaded_id = layer_id;
}
```

**PS가 지켜야 할 순서** (Bottleneck 1개 처리 예시):

```
1) weight를 BRAM에 씀 (Bottleneck1-conv1용)
2) conv3x3 트리거 (layer_id=0)
3) bn_scale/bn_shift를 BRAM에 씀 (Bottleneck1-conv1 뒤 세트)
4) bn_silu_64 트리거
5) weight를 BRAM에 씀 (Bottleneck1-conv2용)
6) conv3x3 트리거 (layer_id=1)
7) bn_scale/bn_shift를 BRAM에 씀 (Bottleneck1-conv2 뒤 세트)
8) bn_silu_64 트리거
9) x_scale/fx_scale/output_scale을 씀
10) residual_add 트리거
   ... Bottleneck2도 동일 순서(layer_id=2,3) 반복 ...
```

**주의**: `bn_silu`는 애초에 캐싱이 없으므로(`bn_scale[c]`를 매 사이클
BRAM에서 직접 읽음) **conv3x3처럼 "값이 같으면 건너뛰기"가 안 됩니다.
매번 PS가 새 값을 써준 뒤 트리거해야 합니다.** 순서가 뒤바뀌면(트리거를
먼저 하고 값을 나중에 쓰면) 이전 레이어의 값으로 계산해버리는 조용한
버그가 생기니 주의가 필요합니다.

---

## 6. 각 IP의 스트림 포트 요약 (Vivado 연결용)

| IP | 입력 스트림 | 출력 스트림 | 비고 |
|---|---|---|---|
| conv1x1 (cv1) | in_s | out_s | |
| **bn128_router** | cv1_out_s, cv2_out_s, bn_out_s | bn_in_s, split_in_s, final_out_s | 포트 6개, bn_silu_128 재사용 배선. 버퍼링 없음 |
| bn_silu_128 | in_s(라우터의 bn_in_s) | out_s(라우터의 bn_out_s) | cv1 뒤/cv2 뒤 2번 재사용, 라우터 경유 |
| split | in_s(라우터의 split_in_s) | y0_s, y1_router_s, y1_concat_s | y1을 라우터용/concat용 2벌로 복제, 출력 3개 |
| conv3x3 | in_s | out_s | 4번 재사용 |
| bn_silu_64 | in_s | out_s | 4번 재사용, conv3x3와 직결(라우터 안 거침) |
| residual_add | x_s, fx_s | out_s | 입력 2개, 전부 라우터 경유 |
| **bottleneck_router** | y1_s(split의 y1_router_s), bn_out_s, res_out_s | conv_in_s, res_x_s, res_fx_s, y2_out_s, y3_out_s | 포트 8개, 4.1절 표 참고 |
| concat | y0_s(split), y1_s(split의 y1_concat_s), y2_s(라우터), y3_s(라우터) | out_s | 입력 4개, 내부 스킵버퍼 보유 |
| conv1x1 (cv2) | in_s | out_s(bn128_router의 cv2_out_s) | |

---

## 7. 최종 확정 버전 (IP별)

여러 최적화 시도(성공/실패 포함) 끝에 각 IP별로 아래 버전이 **최종 채택**됐습니다.
Vivado에 올릴 IP는 이 표의 파일들입니다. 전부 C Simulation + Co-simulation
Pass까지 완료됐습니다.

| IP | 확정 파일 | 핵심 설정 | Latency | LUT | BRAM | URAM | DSP |
|---|---|---|---|---|---|---|---|
| conv1x1 (cv1) | `conv1x1_stream.cpp` | 완전 언롤(128-way), local_weight LUTRAM | 213,004 | 18,304 | 0 | 0 | 64 |
| conv1x1 (cv2) | `conv1x1_cv2_stream.cpp` | 완전 언롤(256-way), local_weight LUTRAM | 221,192 | 35,740 | 0 | 0 | 128 |
| bn_silu_128 | `bn_silu_128_stream_bindop.cpp` | 더블버퍼, exp 유닛 1개, 캐싱 없음, **BIND_OP(float 덧셈→fadd/fulldsp)** | 204,862 | **13,795** | 0 | 0 | **22** |
| bn_silu_64 | `bn_silu_64_stream.cpp` | 위와 동일(64채널), BIND_OP 미적용 | 102,460 | 8,807 | 0 | 0 | 25 |
| split | `split_channel_stream_dup.cpp` | 계산 없음, y1을 라우터용/concat용 2벌로 복제 | 1,602 | 119 | 0 | 0 | 0 |
| residual_add | `residual_add_stream.cpp` | 더블버퍼, 채널 직렬 처리 | 102,433 | 5,907 | 0 | 0 | 13 |
| concat | `concat_channel_stream_uram_reshape8.cpp` | DATAFLOW 제거(순차 실행), 3버퍼 **URAM+ARRAY_RESHAPE(cyclic factor=8)** | 512,037 | 13,171 | **0** | **12** | 8 |
| conv3x3 | `conv3x3_stream_icuf16_v2_weightbram.cpp` | IC_UF=16(acc_partial 재귀 제거), BIND_OP(acc/sum→DSP), local_weight를 BRAM으로 전환, win_s/linebuf LUTRAM, ~~layer_id 캐싱~~ **[정정 → 12절] layer_id 방식은 폐기되어 call_counter 자체 카운팅으로 대체됨** | 1,249,310 | 31,776 | **144** | 0 | 335 |
| **bottleneck_router** | `bottleneck_router_uram.cpp` | conv3x3/bn_silu_64/residual_add를 10단계 순서로 배선. 채널 직렬 처리 + y1/y2_buf **URAM+ARRAY_RESHAPE(cyclic factor=8)** | 1,585,641 | 6,388 | **0** | **8** | 1 |
| **bn128_router** | `bn128_router.cpp` | bn_silu_128을 4단계 순서로 배선. 버퍼링 없는 순수 pass-through | 6,420 | **463** | 0 | 0 | 0 |

**concat/router의 URAM 전환 경위**: 애초에 BRAM 예산을 288로 잘못 알고 있어서
(실제 144), concat(150 BRAM)과 라우터(104 BRAM)를 합치면 그 자체로 예산을
초과하는 상태였습니다. 팀원의 제안으로 URAM(64개, 블록당 288Kb)을 검토 →
두 IP의 스킵버퍼/프레임버퍼가 **파티션 없는 큰 배열**이라 URAM에 잘 맞는
형태였습니다. `BIND_STORAGE impl=uram`만 걸었을 때 URAM이 예상(9~12개)보다
훨씬 많이(75개) 나온 원인은 **URAM 블록의 깊이가 4,096으로 고정**되어 있어
파티션 없는 8bit 폭 배열이 블록을 25개씩(102,400÷4,096) 이어붙였기 때문—
`ARRAY_RESHAPE cyclic factor=8`(인접 8개를 64bit 워드로 압축, URAM 폭 72bit
안에 들어감)로 깊이를 1/8로 줄여 필요 블록도 1/6 수준(75→12, 8)으로 줄였습니다.

> **cyclic vs block 참고**: `ARRAY_RESHAPE`/`ARRAY_PARTITION`에 `cyclic`이
> 아니라 `block`을 쓰면 안 됩니다. `cyclic`은 인접 원소들을 인터리브해서 넓은
> 워드로 압축하는 방식이라 우리 목적(BRAM/URAM 폭을 채워 블록 수를 줄이는 것)에
> 맞지만, `block`은 배열을 순서대로 잘라 별도 뱅크로 분리하는 방식이라 이
> 목적에는 효과가 없거나(뱅크만 늘어 오히려 역효과) 맞지 않습니다.

**conv3x3 최적화 이력(참고)**: IC_UF=64 완전언롤(LUT 80,928) → IC_UF=16 부분언롤
+ acc_partial 재귀제거(LUT 47,043) → BIND_OP로 acc/sum을 DSP로 유도(LUT 40,992,
-6,197) → local_weight를 LUTRAM에서 BRAM으로 전환(LUT 31,776, -9,216). 총 4단계
최적화로 LUT 80,928 → 31,776 (61% 감소).

**bottleneck_router 관련 특이사항**: 이 IP는 conv3x3/bn_silu_64/residual_add의
스트림을 순서대로 중계·버퍼링만 하므로 latency 여유가 매우 큽니다(병목인
conv3x3 4회 재사용 대비 실제 파이프라인 시간의 극히 일부). 이 여유를 이용해
64-way 병렬 접근을 채널 직렬 접근으로 바꿔 LUT를 39,085 → 5,453(86% 감소)까지
줄였습니다 — 라우터처럼 latency 여유가 큰 IP에서는 "직렬화로 LUT 절감"이
효과적인 카드입니다.

**bn_silu_128 BIND_OP 결과(참고)**: float 덧셈(`op=fadd impl=fulldsp`)을 DSP로
유도한 결과 LUT 14,312→13,795(-517), DSP 25→22(오히려 감소). conv1x1처럼
역효과는 아니었지만 conv3x3만큼 큰 효과도 아님 — 채널당 덧셈이 1번뿐이라
효과가 제한적이었음. 그래도 순이득이라 채택.

**기각된 실험들** (참고용, 채택 안 함):
- conv3x3/conv1x1의 IC_UF 부분 언롤·BIND_OP 조합 중 위 표에 없는 것들
  (conv1x1 cv1/cv2는 두 기법 모두 4번 시도해서 전부 역효과였음)
- **conv3x3 IC_UF=8** — LUT는 31,776→24,341(-23%)로 더 줄었지만, latency가
  약 2배(12.49ms→24.78ms)로 늘어 4회 재사용 시 conv3x3만으로 약 99ms 소요,
  전체 파이프라인 fps가 목표 하한선(10fps) 밑(약 7.2fps)으로 떨어져 기각
- concat을 `m_axi`로 DDR에 연결한 버전 — BRAM은 여유가 있었으므로 LUT 손해(+4,705)만 발생
- concat/router의 BRAM `ARRAY_RESHAPE` (factor=4/8) — URAM 전환으로 대체됨(BRAM 자체를 0으로 만드는 게 더 나음)
- conv1x1 cv2의 local_weight를 BRAM으로 옮긴 버전 — 파티션 방식(complete dim=2)
  때문에 BRAM 256개로 손해가 너무 큼 (conv3x3은 cyclic 파티션이라 144개로 효율적).
  같은 이유로 이 배열은 URAM으로도 부적합(이미 여러 조각으로 파티션돼 있어 URAM
  블록을 조각마다 낭비함) — URAM 후보에서 제외
- Bottleneck 전체를 하나의 HLS IP로 통합하는 방향(방향 B) — DATAFLOW가 conv3x3을
  2벌 중복 생성해 LUT 168K/BRAM 438로 폭증
- conv3x3/bn_silu_64/residual_add를 `m_axi`로 바꿔 PS가 직접 중계하는 방향 —
  DDR 접근 오버헤드로 latency 21배(262ms) 폭증

## 8. 현재 자원 사용 현황 (최신 — BRAM 예산 정정 + bn128_router 반영)

물리적으로 1벌씩 배치되는 IP 기준 (시분할 재사용 IP도 1벌로만 계산):

| IP | LUT | BRAM | URAM |
|---|---|---|---|
| conv3x3 | 31,776 | 144 | 0 |
| bn_silu_64 | 8,807 | 0 | 0 |
| bn_silu_128 | 13,795 | 0 | 0 |
| residual_add | 5,907 | 0 | 0 |
| conv1x1 cv1 | 18,304 | 0 | 0 |
| conv1x1 cv2 | 35,740 | 0 | 0 |
| split | 119 | 0 | 0 |
| concat | 13,171 | 0 | 12 |
| bottleneck_router | 6,388 | 0 | 8 |
| bn128_router | 463 | 0 | 0 |
| **합계** | **134,470** | **144** | **20** |
| **KV260 예산** | 117,120 | 144 | 64 |
| **상태** | **초과 17,350 (14.8%)** | **정확히 일치 (여유 0)** | **여유 44 (69% 남음)** |

**BRAM 문제는 사실상 해결됐습니다.** concat과 라우터의 스킵버퍼/프레임버퍼를
URAM으로 옮긴 결과, 남은 BRAM 사용처는 conv3x3의 `local_weight` 하나뿐이고
이게 정확히 예산(144)과 일치합니다 — 여유는 0이라 다른 IP가 BRAM을 조금이라도
더 쓰면 바로 초과되는 빠듯한 상태지만, 초과는 아닙니다.

**남은 문제는 LUT 초과(14.8%)뿐입니다.**

> **[해결 → 17절]** 이 LUT 초과는 아래 후보 3번(cv2를 소프트웨어로 이전)을
> 채택해 최종 해결됐습니다. 최종 실측 LUT는 65,659(예산 대비 **56%**)이며,
> Implementation·Timing·Bitstream까지 전부 통과했습니다.

**남은 후보**:
1. 실제 Vivado 구현(P&R) 결과로 재확인 — HLS 추정치가 보수적으로 나오는
   경우가 흔해 실측에서 격차가 줄어들 가능성
2. (검토 중) 입력 해상도 축소 — 10절 참고
3. **(검토 중) cv2를 소프트웨어로 이전** — 11절 참고, 가장 효과가 큰 후보

**시도했으나 더 이상 진전이 없는 방향**:
- conv1x1 계열은 BIND_OP/부분언롤/BRAM전환/URAM(파티션 구조상 부적합) 모두 역효과라 추가 시도 보류
- conv3x3 IC_UF=8은 LUT는 더 줄지만 fps가 목표 밑으로 떨어져 기각 — IC_UF=16이
  LUT·fps 균형점

## 9. Vivado 연결 시 체크리스트

- [ ] 10개 IP(conv1x1×2, bn_silu×2 재사용, conv3x3, bn_silu_64, residual_add, split, concat, **bottleneck_router**, **bn128_router**) Block Design에 추가
- [ ] 데이터 경로: DMA(읽기) → conv1x1(cv1) → bn128_router → bn_silu_128 → bn128_router → split(y0, y1_router_s, y1_concat_s) → bottleneck_router ↔ [conv3x3, bn_silu_64, residual_add] → concat(y0, y1_concat_s, y2, y3) → conv1x1(cv2) → bn128_router → bn_silu_128 → bn128_router → DMA(쓰기), 전부 AXI-Stream으로 직결 (4.1절 라우터 포트표 참고)
- [ ] `conv3x3.out_s → bn_silu_64.in_s`는 bottleneck_router를 거치지 않고 직결
- [ ] `s_axilite` 파라미터(layer_id, scale류): PS ↔ 해당 IP 간 AXI4-Lite 배선
- [ ] `bram` 파라미터(weight, bn_scale/shift): ~~파라미터마다 `AXI BRAM Controller` + `BRAM` 추가, PS와 대상 IP 양쪽에서 접근 가능하도록 배선~~ **[정정 → 14.2절] 이 값들은 전부 실행 중 절대 안 바뀌는 상수(가중치=best.pt, 스케일=보정 데이터셋)임이 확인되어, AXI BRAM Controller 없이 `.coe` + Block Memory Generator(Stand-Alone)로 비트스트림에 미리 로드하는 방식으로 확정. concat의 scale류만 s_axilite라 예외**
- [ ] Address Editor에서 각 IP/BRAM의 메모리 주소 확인 및 헤더 export
- [ ] PS 펌웨어: 5.4절 순서대로 파라미터 로드 → 트리거를 코드로 구현 (라우터 자체는 파라미터 없음, 데이터만 중계)
- [ ] 실제 구현(합성+P&R) 후 Utilization Report로 BRAM/LUT/URAM 재확인 (현재 LUT 14.9% 초과, BRAM 정확히 일치(여유 0), URAM 여유 69%)

## 10. (검토 중) 입력 해상도 축소 640×640 → 320×320

자원 초과분을 더 줄이기 위한 선택지로 논의 중입니다. 0절의 하이브리드 구조
덕분에, **하드웨어 재설계 범위는 model.6 하나로 한정**됩니다 (model.0~5는
소프트웨어라 입력 크기만 바꿔 재실행하면 됨).

**얻는 것**: 특징맵이 40×40→20×20(픽셀 수 1/4)이 되며 전체 latency도 대략
1/4로 줄어 fps 여유가 크게 늘어남(현재 ~14.4fps → 예상 ~57fps). 이 여유를
IC_UF를 더 낮추는 등 추가 최적화에 재투자하면 LUT/BRAM을 더 줄일 수 있음
— 단, **해상도 축소 자체가 LUT/BRAM을 직접 줄이지는 않음** (MAC 폭, 배열
크기는 해상도와 무관).

**필요한 작업**: 10개 IP(라우터 2종 포함)의 H,W 파라미터 변경(40→20) 후 전체
재검증(C Sim/합성/Co-sim), 320 기준 golden reference 재확보.

**남은 리스크**: 학습 해상도(640)와 다른 해상도로 추론 시 정확도(특히
mAP_small)가 하락할 수 있음 — 재학습 없이 `model.val(imgsz=320)`로 사전
확인 필요. model.0~5 담당 팀원과 협의 필요.

## 11. **[채택·완료]** cv2를 소프트웨어로 이전 — 하드웨어 범위를 concat까지로 축소

> **[결과 → 17절]** 이 방안을 최종 채택해 실제로 적용했고, LUT 초과 문제가
> 완전히 해소되어 Implementation·Bitstream까지 통과했습니다. 아래는 결정
> 당시의 검토 내용이며, 실제 적용 결과는 17절을 참고하세요.

지금 LUT 초과(14.8%)를 해결할 가장 효과가 큰 후보입니다. 0절의 하이브리드
구조(model.6만 하드웨어, 나머지는 소프트웨어)를 한 단계 더 확장하는
아이디어입니다 — **하드웨어 범위를 model.6 전체가 아니라 concat까지로
줄이고, cv2(conv1x1 256→128) 이후를 소프트웨어로 넘깁니다.**

**얻는 것 — cv2 하나를 빼는 게 아니라 그 재사용 문제까지 같이 사라집니다**

| 제거되는 것 | LUT | 이유 |
|---|---|---|
| conv1x1 (cv2) | 35,740 | 그 자체가 사라짐 |
| **bn128_router** | 463 | bn_silu_128이 이제 cv1 뒤에서 1번만 쓰여, 재사용 배선(라우터) 자체가 불필요 |

| | 지금 (model.6 전체 HW) | cv2 제외 (concat까지 HW) |
|---|---|---|
| LUT 총합 | 134,470 | **98,267** |
| KV260 예산 | 117,120 | 117,120 |
| 상태 | 초과 17,350 (14.8%) | **여유 18,853 (16%)** |

LUT 문제가 완전히 해소되고 오히려 여유가 생깁니다 — IC_UF 조정이나 BIND_OP로
몇 %씩 깎아내던 것과 비교하면 한 번에 훨씬 큰 폭(32%p)을 이동시키는 결정입니다.
DSP도 128개 추가로 줄어듭니다(원래도 여유 있었음).

**대가 — 소프트웨어 쪽 부담이 늘어납니다**

| | 지금 | cv2 제외 시 |
|---|---|---|
| PS가 받는 데이터 | model.6의 최종 128채널 출력 | **concat의 256채널 출력** |
| PS가 해야 할 일 | 그대로 model.7에 전달 | **conv1x1(256→128) + BN + SiLU를 소프트웨어로 계산 후 model.7에 전달** |

개념적으로는 0절의 하이브리드 구조와 같은 종류의 결정(하드웨어/소프트웨어
경계를 어디에 둘지)이라 새로운 아키텍처는 아니지만, **경계가 model.6의
끝(cv2 뒤)에서 concat 뒤로 한 칸 당겨지는** 설계 변경이라 PS의 연산량이
늘어납니다.

**필요한 작업**: conv1x1(cv2)+BN+SiLU에 해당하는 연산을 소프트웨어로 구현
(가중치/BN 파라미터를 PS 쪽 코드로 이전), Vivado에서 conv1x1(cv2)/bn128_router
제거 및 concat의 출력을 DMA로 직결, model.7이 받는 입력 형식(스케일/양자화
포함) 재정의.

**남은 리스크**: 팀(특히 PS 소프트웨어 담당)과의 아키텍처 합의가 필요합니다
— 혼자 결정할 사안이 아니라 다음 팀 회의 안건으로 올리는 게 좋습니다.
정확도 리스크는 없습니다(순수 자원 재배치이므로 10절의 해상도 축소와 달리
연산 자체는 동일하게 수행됨).

---

## 12. layer_id 동기화 문제 재해결 — self-counting 전환

### 12.1 문제 발견

model.6 내부 전체(conv1x1(cv1)~bn_silu_128(cv2))가 실제 코드(구조체 타입
대조)로 확인한 결과 **처음부터 끝까지 AXI-Stream으로 직결**되어 있고, DDR을
거치는 지점은 HW 입력/출력 경계 두 곳뿐임이 확인됐습니다. 즉 PS는 프레임당
**"입력 1회 DMA + 출력 1회 DMA"**만 하면 되고, 그 사이는 PS 개입 없이
하드웨어 내부에서 자동으로 흘러갑니다.

이 발견은 좋은 소식(PS 코드가 훨씬 단순해짐)과 함께 새 문제를 드러냈습니다:
**conv3x3이 프레임당 4회 재사용되는데, PS가 프레임당 1번만 개입하니
`layer_id`를 정확한 타이밍에 써줄 방법이 없어졌습니다.** 같은 문제가
bn_silu_64(4회), residual_add(2회), bn_silu_128(2회)에도 있었습니다.

### 12.2 해결 — self-counting (call_counter)

PS가 외부에서 타이밍 맞춰 값을 넣어주는 방식을 버리고, **IP가 static
카운터로 자기 호출 순번을 스스로 셉니다.**

```cpp
static int call_counter = 0;
int my_set = call_counter % N_SET;
call_counter++;
```

`call_counter`는 static이라 `ap_start`될 때마다 값이 유지되며 자동으로
순환합니다. PS는 프레임 시작 전(또는 부팅 시) 모든 세트를 한 번에 로드해두면
그 뒤로 개입이 필요 없습니다.

**필요조건 — Auto Restart**: 이 구조가 성립하려면 IP가 `ap_done` 뒤에도 PS의
`ap_start` 없이 스스로 다시 시작해야 합니다. 이건 Vivado 배선이나 재합성이
필요한 게 아니라, 모든 HLS IP에 기본 내장된 `s_axi_control`의 CTRL 레지스터
7번 비트(`auto_restart`)를 **PS 코드에서 프로그램 시작 시 한 번 켜주는 것**만
필요합니다.

### 12.3 IP별 적용 — 2가지 강도

| IP | 재사용 | 가중치/파라미터 저장 방식 |
|---|---|---|
| conv3x3 | 4회 | `weight_bank[4][...]`(URAM, 파티션 없음) + `local_weight`(기존 BRAM+파티션 그대로, 자원 불변) 2단 구조. 세트가 바뀔 때만 복사 |
| bn_silu_64/128, residual_add | 4회/2회 | 배열이 작아(4벌 합쳐도 1KB 안팎) URAM 불필요 — `bn_scale`/`bn_shift`/`input_scale`/`weight_scale`/`output_scale` 전부 `[N_SET]` 차원만 추가 |

conv3x3만 자원 부담이 커서 2단 구조가 필요했고, 나머지는 배열 크기 자체가
작아 차원만 늘리면 충분했습니다.

**결과 (전부 C-sim 4회/2회 연속 호출 검증 + Co-sim PASS)**:

| IP | LUT (이전→이후) | BRAM (이전→이후) | URAM (이전→이후) | DSP |
|---|---|---|---|---|
| conv3x3 | 31,776→32,452 | 144→144(불변) | 0→**36**(신규) | 335(불변) |
| bn_silu_64 | 8,807→8,654 | 0→0 | 0→0 | 25→25 |
| bn_silu_128 | 13,795→13,795(불변) | 0→0 | 0→0 | 22→25 |
| residual_add | 5,907→5,754 | 0→0 | 0→0 | 13→13 |

라우터 2개는 포트가 전부 `hls::stream`뿐이라 코드 변경 불필요.

### 12.4 URAM 총합 재확인 필요

conv3x3에 36개가 새로 붙어 `concat(12) + bottleneck_router(8) + conv3x3(36)
= 56/64`. bn_silu_64/128, residual_add는 URAM을 안 쓰므로 추가 없음.
여유 8개 남았으나, 14절 자원 디버깅 참고.

---

## 13. 시스템 통합 SW 1~3단계 진행 상황

### 13.1 1단계 — 양자화 보정

`calibrate_model6.py`로 기존 10개 golden reference 스크립트의 스케일 계산을
통합했습니다.

- **bn_scale/bn_shift, 가중치**: 기존 golden 스크립트 그대로 재사용 가능 —
  전부 `best.pt`(BN 파라미터/가중치)에서만 나오는 값이라 순수 BN 항
  (`γ/√(var+ε)`)이라 HW 규약과 이미 일치했음
- **활성화 스케일(input_scale/weight_scale/output_scale 등)**: 기존
  10개 스크립트 전부 `torch.randn` 기반이라 무효(일부는 `manual_seed`도
  없어 재현조차 안 됨) + 스크립트마다 독립 계산해 체인 정합성이 깨져 있었음
  (예: split 이전/이후 스케일이 서로 다르게 계산됨 — 물리적으로 불가능)
- **재보정**: valid_dataset 114장으로 MSE모드(`calib_out/`, 채택) vs
  percentile모드(`calib_out_pct/`, 5단계 mAP 비교 때까지 보류) 확보

**HW 파라미터 규약** (bn_silu 계열 실제 코드로 확정):
```
bn_out = acc * (input_scale * weight_scale) * bn_scale[c] + bn_shift[c]
out    = round(SiLU(bn_out) / output_scale)
```
`bn_scale`에는 순수 BN 항만 들어가야 하며, `input_scale`/`weight_scale`을
거기 미리 곱하면 이중 곱셈 오류가 됩니다.

### 13.2 2단계 — model.0~5 SW 구현

`sw_model0to5.py`: 전체 모델을 float로 forward하고 model.5 출력을 hook으로
캡처(A안 — model.6~22도 계산되지만 model.5까지 결과는 동일해 검증엔 무방,
fps 측정 시엔 진짜로 잘라 도는 B안으로 교체 가능)한 뒤 `S_in`으로 int8
양자화 → `hw_input.bin`(128×40×40, CHW).

검증(실제 이미지 1장): shape 정상, 포화율 0%.

### 13.3 3단계 — model.7~ SW 구현

`sw_model7up.py`: model.6에 forward hook을 걸어 원래 계산값을 대체값(HW
출력 또는 그 흉내값)으로 바꿔치기하는 방식 — skip connection을 손으로
재구현할 필요 없이 PyTorch의 forward가 이미 아는 skip 인덱스 관리를 그대로
활용. 3모드:
- `float_ref` — 순수 SW 전체, 5단계 기준값
- `hw_emulate` — model.6을 float로 계산 후 int8 양자화→역양자화만 흉내,
  실제 HW 없이 오차 사전 확인
- `hw_readback` — 실제 HW DMA 출력 `.bin`을 그대로 주입 (4단계에서 사용)

검증: `mean|err|=0.00902`(양자화 스텝의 1/4 근처, 정상적인 반올림 오차),
`max|err|=0.80786`(model.6 |max|=5.7161이 int8 한계 127을 초과해 클리핑된
것으로, MSE 보정이 의도한 정상 동작).

---

## 14. Vivado 실제 배선 진행 및 자원 디버깅

### 14.1 AXI-Stream 직결 (19개 연결)

10개 IP를 실제 코드(구조체 타입 대조)로 검증한 결과, 데이터 경로 전체가
타입 폭까지 정확히 일치함을 확인. HW 입력/출력 경계 두 곳(1024bit)만
AXI DMA와 연결하고 나머지는 IP끼리 직결.

**FIFO 필수 삽입 지점**: `bottleneck_router`가 fx→x 순서로 쓰는데
`residual_add`는 x→fx 순서로 읽어, 직결 시 데드락 위험(C-sim은 무한 FIFO라
안 드러났던 부분). `res_x_s`/`res_fx_s` 경로에 AXI4-Stream Data FIFO(depth
16, **Distributed RAM** 명시 — Auto/Block/Ultra RAM은 자원 예산 위험하므로
배제) 삽입.

### 14.2 bram/s_axilite 13개 포트 → 전부 `.coe` 고정값 방식 (9절 정정)

**핵심 통찰**: weight/bn_scale/bn_shift/각종 scale 전부 **웹캠 프레임과
무관하게 실행 중 절대 안 바뀌는 상수**(가중치는 `best.pt`, 스케일은
114장 보정에서 1회 계산)임이 확인되어, PS 런타임 AXI 쓰기 자체가
불필요해짐. 처음 계획(9절)이었던 AXI BRAM Controller 방식은 폐기.

- **처리 방식**: Block Memory Generator(**Stand-Alone** 모드 — AXI4
  모드는 폭/Load Init File이 잠김), Interface 탭에서 포트 개수(1개/2개)
  확인 후 Single/Dual Port 결정, Load Init File로 `.coe` 로드
- **예외 — concat의 `scale0~3`/`output_scale`**: `s_axilite`로 선언되어
  다른 12개와 다름 — 이미 있는 s_axi_control↔M_AXI_HPM0_FPD 경로로 처리,
  BMG 배선 불필요. 값은 4단계 PS 부팅 코드에서 레지스터에 1회 write
- **`.coe` 생성 스크립트**: `bin_to_coe.py`(conv1x1 weight, int8),
  `bin_to_coe_multiset.py`(conv3x3 4벌 가중치 이어붙임),
  `bin_to_coe_float.py`(float32, IEEE754 비트 그대로 기록 — 2의 보수
  변환 아님, 왕복 검증 완료), `extract_scale_bins.py`(calib_params.json
  안의 스칼라들을 call_counter 순서로 `.bin` 추출)
- **반복된 dtype 함정**: `calibrate_model6.py`가 weight를 값은 int8
  범위지만 **타입은 int32**로 저장 — 이 프로젝트에서 여러 번 반복된 실수.
  스크립트에서 값 범위 자동 검증 추가해 재발 방지
- **call_counter 순서 정렬 필수**: `.coe` 안에 이어붙이는 순서가 곧
  메모리 주소 순서이자 call_counter 실제 호출 순서(m0.cv1→m0.cv2→
  m1.cv1→m1.cv2 등)와 정확히 일치해야 함 — 틀리면 조용히 잘못된 세트가
  선택되는 찾기 어려운 버그가 됨
- **conv1x1 weight의 PORTA/PORTB 이슈**: HLS 로드 루프 구조상 포트가
  2개로 나온 경우(Interface 탭 확인 필요) → BMG도 True/Single Dual Port
  로 맞춰야 함

### 14.3 제어 설정

- **Auto Restart**: 4개 재사용 IP(conv3x3/bn_silu_64/bn_silu_128/
  residual_add), Vivado에서 할 일 없음 — 12.2절 참고, 4단계 PS 코드에서 처리
- **ap_start 핀 상수 처리**: conv1x1×2/split은 `s_axi_control` 자체가
  없어(코드에 `s_axilite port=return` 없음) `ap_start` 핀에 Constant
  IP(값 1)를 직결
- **인터럽트 핀**: 전부 미사용(폴링 방식으로 PS가 `ap_done` 직접 확인)

### 14.4 자원 디버깅 — BRAM 초과 → 해결됨

1차 Implementation 시도에서 DRC 실패: RAMB18/36 291 필요/288 가능(RAMB36
144개=RAMB18 288개와 정확히 일치, 초과는 약 1.5 RAMB36 수준).

**원인**: AXI DMA의 Stream/Memory Map Data Width를 우리 IP 스트림 폭에
맞춰 1024bit로 설정한 것 자체가 DMA 내부 엘라스틱 버퍼를 32배 키움
(`axi_dma_0` 단독 BRAM 33개, Max Burst Size는 무관함을 실험으로 배제).

**해결**: DMA를 32bit(기본값)로 되돌리고, HW 경계 2곳에 **AXI4-Stream
Data Width Converter**(32↔1024bit) 추가. Converter는 BRAM을 전혀 안 씀
(LUT/FF만 사용). 전체 129.5/144로 여유(14.5개) 확보 — 확인 완료.

### 14.5 자원 디버깅 — LUT/Control Set 초과 (해결 진행 중)

BRAM 해결 후 Implementation에서 Placer 실패: **Control sets 2,518종**이
CLB당 4종 제한에 걸려 LUT total이 combined(예산 안, 106,785)보다 훨씬
크게(149,953 > 117,120) 부풀려짐.

**시도 1** — `opt_design`에 `-control_set_merge -merge_equivalent_drivers`:
소폭 개선(부족분 1,007→758 CLB)이나 부족.

**시도 2** — `-directive ExploreArea`: 개별 옵션과 동시 사용 불가(택일),
오히려 악화(LUT 자체가 118,368>117,120로 초과) — **폐기, 시도 1로
원상복구**.

**`report_qor_suggestions` 확인**: LUT 91%/BRAM 89%/URAM 87%/FF 82% **전부
권장 최대치 초과** — 설계가 디바이스 용량에 거의 꽉 차 있는 근본적
상태임이 드러남. control set 파편화는 이를 악화시키는 요인일 뿐 근본
원인은 아니었음.

**핵심 발견 — `bn128_router` 단독 자원 재확인**: 정확한 인스턴스 경로로
확인(`report_utilization -cells [get_cells design_1_i/bn128_router_0]
-hierarchical`, 앞선 와일드카드 필터 시도는 설계 전체를 잘못 포함해
무효했음) 결과, **실제로 LUT 24,264 / FF 41,110을 단독으로 사용**함이
확인됨. 7절 표의 "LUT 463"은 HLS 단독 합성 시(C-sim/Co-sim 단계)의 값일
뿐, 실제 시스템에 물린 뒤의 Vivado 합성 결과는 전혀 다릅니다 — 이 차이가
지금까지 문서에 없던 새로운 사실입니다.

**원인 분석**:
- `regslice_both` (스트림 완충 버퍼, HLS가 stream 포트마다 자동 삽입):
  `bn_in_s`/`cv1_out_s`/`cv2_out_s`(4096bit=int32×128) 각 8,196 FF,
  `bn_out_s`/`split_in_s`/`final_out_s`(1024bit=int8×128) 각 ~2,052 FF —
  4096bit짜리 광폭 버스 6개를 2단 버퍼링하는 순수 물리적 비용. 합계
  FF 약 30,744
- `frp_fifoout` (STEP1/STEP3 안): `bn_in_s`를 두 곳(STEP1, STEP3)에서
  나눠 쓰는 코드 구조 때문에 HLS가 내부 중재 FIFO를 만듦. 4096bit 폭이라
  각 ~6,164 LUT, 합계 약 12,300

**처방 (검토했으나 미실행 → 17절의 cv2 제거로 대체됨)**: `bn128_router`의
6개 stream 포트에 `#pragma HLS INTERFACE axis register_mode=off`를 추가해
자동 완충 버퍼를 제거하는 방안. 다만 이 조치는 `bn128_router`를 **고쳐서**
재합성(코드 수정 → 합성 → Co-sim → 전체 재합성)해야 하는 반면, 11절의
cv2 제거는 `bn128_router` 자체가 **불필요해져** HLS 작업이 아예 사라지므로
— 더 적은 작업으로 훨씬 큰 효과를 봅니다. **17절에서 이 방향을 채택했습니다.**

---

## 15. 자원 사용 현황 변경 이력

8절 표(초기 IP 설계 완료 시점) 이후 다음이 추가/변경됐습니다:

| 변경 사항 | 영향 |
|---|---|
| conv3x3 self-counting 전환 | LUT +676, **URAM +36**(신규) |
| bn_silu_64/128, residual_add self-counting | LUT 소폭 변화(±수백 이내), 무시 가능 |
| AXI DMA Width 1024→32 + Width Converter 추가 | BRAM -31(33→2), LUT/FF 소폭 증가 |
| `bn128_router` 실측(Vivado 합성) | LUT 463(HLS 단독)이 아니라 **24,264**로 확인 |
| **cv2 SW 이전 (17절)** | **LUT -41,126, DSP -256, BRAM -8** — 최종 해결 |

**8절 표의 "합계 134,470"은 유효하지 않습니다.** HLS 단독 합성치와 실제
Vivado 통합 후 실측치가 크게 다를 수 있다는 것(특히 `bn128_router`가
463 → 24,264)이 이번에 확인된 중요한 교훈입니다. **최종 실측 자원 현황은
17.3절 참고.**

---

## 16. 남은 작업

1. `.xsa` Export → KV260에 비트스트림 로드
2. **4단계 PS 제어 흐름 코드** 작성: 부팅 시 1회(Auto Restart 비트 설정
   + concat의 s_axilite scale 5개 write), 프레임마다(입력 1회 DMA →
   하드웨어 자동 처리 → 출력 1회 DMA). 기존 "16단계 DMA 왕복" 가정 기반
   설계는 12.1절의 연속 스트림 발견으로 폐기됨
   - **Auto Restart 대상이 4개 → 3개로 감소**: conv3x3, bn_silu_64,
     residual_add만 해당. `bn_silu_128`은 cv2 제거로 프레임당 1회만
     쓰이므로 더 이상 불필요
3. `sw_model7up.py` 수정: **256채널**을 받아 `conv1x1(cv2) + BN + SiLU`를
   소프트웨어로 계산한 뒤 model.7로 전달하도록 변경 (5단계 전 필수)
4. 5단계 SW 전체 vs SW+HW 하이브리드 대조 테스트, fps 실측

---

## 17. **[완료]** cv2 SW 이전 적용 → Bitstream 생성까지 성공

### 17.1 결정 배경

14.5절에서 `bn128_router`의 실측 자원이 HLS 단독값(LUT 463)과 달리
**LUT 24,264 / FF 41,110**임이 확인되면서, 11절에 검토만 해뒀던 cv2 제거
방안의 기대 효과가 **당초 계산보다 훨씬 커졌습니다.**

11절 당시 계산은 `bn128_router`를 463으로 잡고 있었으나, 실제로는 52배인
24,264였기 때문입니다. cv2를 SW로 옮기면 `conv1x1(cv2)`가 사라지는 동시에
**`bn128_router`도 존재 이유 자체가 없어집니다** — `bn_silu_128`이 cv1 뒤에서
1번만 쓰이게 되어 "재사용 순서 전환"이라는 라우터의 역할이 불필요해지기
때문입니다. 즉 지우는 게 아니라 애초에 **안 만들면 됩니다.**

SW 부담 증가 우려에 대해서는, `conv1x1(cv2, 256→128)`의 연산량이 40×40
기준 약 5,200만 MAC으로, 이미 SW로 처리하기로 한 model.0~5(640×640 고해상도
구간) 및 model.7~22(SPPF, 여러 C2f 블록 포함) 전체 규모에 비하면 미미하다고
판단했습니다. (정밀 실측은 생략하고 진행 — 5단계 fps 측정 때 확인 예정)

### 17.2 실제 수정 내역 — 재합성한 IP 없음

**HLS 재합성이 필요한 IP는 하나도 없었습니다.** IP 내부 로직을 바꾸는 게
아니라 쓰던 IP를 안 쓰는 것이므로, 남은 IP들은 기존 것을 그대로 재사용.

| 구분 | 내용 |
|---|---|
| **삭제 (4개)** | `conv1x1_cv2_stream_0`, `bn128_router_0`, `blk_mem_gen_1`(cv2 weight용), cv2의 `ap_start`에 물렸던 Constant 연결 |
| **재연결 (2군데)** | `conv1x1_stream_0.out_s` → **직접** `bn_silu_128_stream_0.in_s` / `bn_silu_128_stream_0.out_s` → **직접** `split_channel_stream_0.in_s` (기존엔 둘 다 bn128_router 경유) |
| **출력 경계 변경** | `concat_channel_stream_0.out_s`(**2048bit, 256ch int8**) → Width Converter → DMA. Converter의 Slave TDATA Width를 128byte → **256byte**로 수정 |
| **`.coe` 재생성** | `bn128_*.coe` 5개를 **cv1측 값만으로** 재생성. `bn_silu_128`이 1회만 호출되지만 `N_SET=2` 배열은 그대로 두고, 두 슬롯에 같은 값을 넣어 `call_counter`가 0이든 1이든 동일한 결과가 나오게 함 → **HLS 재합성 불필요**. `cv2_weight.coe`와 그 BMG는 삭제 |

Validate Design 결과 새로운 에러 없음 (기존의 MASTER_TYPE 불일치 17개 +
DMA TLAST 경고 1개만 남았고, 둘 다 앞서 확인한 무해 항목).

### 17.3 최종 자원 실측 결과 (Synthesis)

| 자원 | cv2 제거 전 | **제거 후** | 예산 | 여유 |
|---|---|---|---|---|
| **LUT** | 106,785 (91%) | **65,659 (56%)** | 117,120 | **44%** |
| CLB Registers | 192,797 (82%) | **130,945 (56%)** | 234,240 | 44% |
| **BRAM** | 129.5 (90%) | **121.5 (84%)** | 144 | 16% |
| URAM | 56 (87%) | 56 (87%) | 64 | 12% |
| DSP | 728 | **472 (38%)** | 1,248 | 62% |

**LUT 41,126개 감소** (91% → 56%). `opt_design` 옵션으로 몇 천 개씩 깎던
것과는 차원이 다른 효과였고, DSP도 conv1x1(cv2) 몫 256개가 함께 감소.

주요 IP별 실측 LUT: conv3x3 19,476(BRAM 72/URAM 36) · bn_silu_128 8,832 ·
concat 7,771(URAM 12) · conv1x1(cv1) 7,635(DSP 128) · bn_silu_64 5,949 ·
bottleneck_router 5,246(URAM 8) · residual_add 3,818 · split 1,325

### 17.4 Implementation & Bitstream — 전부 통과

LUT 여유가 44%로 늘면서, 그동안 Placer를 막던 **Control Set 파편화 문제도
자연스럽게 해소**됐습니다(애초에 담을 공간이 없던 게 근본 원인이었음).

**Timing Summary — 모든 제약 충족 (All user specified timing constraints are met)**

| 항목 | 값 | 판정 |
|---|---|---|
| WNS (Setup) | **+0.850 ns** | 통과 (100MHz/10ns 대비 8.5% 여유) |
| WHS (Hold) | **+0.009 ns** | 통과 (양수, Failing Endpoint 0) |
| WPWS | +3.500 ns | 통과 |
| Failing Endpoints | **0** (전 항목, 총 367,780 endpoint) | 문제 없음 |

**Generate Bitstream 성공** — 하드웨어 구현 완료.

### 17.5 이번 과정에서 얻은 교훈

- **HLS 단독 합성치를 최종 자원 추정치로 신뢰하면 안 됨**: `bn128_router`가
  463 → 24,264(52배)로 나온 것처럼, 실제 시스템에 통합된 뒤 자동 삽입되는
  인터페이스 로직(`regslice_both` 등)이 원본 로직보다 훨씬 클 수 있음.
  특히 **광폭 스트림 포트(4096bit 등)를 여러 개 가진 IP**에서 두드러짐
- **자원 문제는 미세 최적화보다 아키텍처 결정이 훨씬 효과적**: `opt_design`
  옵션 조합으로 수천 개를 깎는 동안 부족분이 758 CLB에서 줄지 않았으나,
  HW/SW 경계를 한 칸 옮기는 결정 하나로 41,126개가 한 번에 해소됨
- **자원 초과 시 Vivado 에러 메시지의 표면만 보면 오진하기 쉬움**: "Control
  set 2,518종" 에러는 원인처럼 보였지만 실제로는 증상이었고, 근본 원인은
  `report_qor_suggestions`가 보여준 "모든 자원이 권장치 초과"라는 전반적
  포화 상태였음
