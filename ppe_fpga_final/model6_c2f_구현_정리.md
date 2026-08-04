# model.6 (C2f 블록) FPGA 구현 정리

> 목적: model.6을 하드웨어(FPGA)로, 나머지 레이어를 소프트웨어(PS)로 처리하는
> 하이브리드 구조에서, model.6 내부 **10개 IP**(계산 8개 + 라우터 2개)를
> 어떻게 설계·검증했고 Vivado에서 어떻게 연결해야 하는지 정리한 문서입니다.

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
| conv3x3 | `conv3x3_stream_icuf16_v2_weightbram.cpp` | IC_UF=16(acc_partial 재귀 제거), BIND_OP(acc/sum→DSP), local_weight를 BRAM으로 전환, win_s/linebuf LUTRAM, layer_id 캐싱 | 1,249,310 | 31,776 | **144** | 0 | 335 |
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

**남은 후보**:
1. 실제 Vivado 구현(P&R) 결과로 재확인 — HLS 추정치가 보수적으로 나오는
   경우가 흔해 실측에서 격차가 줄어들 가능성
2. (검토 중) 입력 해상도 축소 — 10절 참고

**시도했으나 더 이상 진전이 없는 방향**:
- conv1x1 계열은 BIND_OP/부분언롤/BRAM전환/URAM(파티션 구조상 부적합) 모두 역효과라 추가 시도 보류
- conv3x3 IC_UF=8은 LUT는 더 줄지만 fps가 목표 밑으로 떨어져 기각 — IC_UF=16이
  LUT·fps 균형점

## 9. Vivado 연결 시 체크리스트

- [ ] 10개 IP(conv1x1×2, bn_silu×2 재사용, conv3x3, bn_silu_64, residual_add, split, concat, **bottleneck_router**, **bn128_router**) Block Design에 추가
- [ ] 데이터 경로: DMA(읽기) → conv1x1(cv1) → bn128_router → bn_silu_128 → bn128_router → split(y0, y1_router_s, y1_concat_s) → bottleneck_router ↔ [conv3x3, bn_silu_64, residual_add] → concat(y0, y1_concat_s, y2, y3) → conv1x1(cv2) → bn128_router → bn_silu_128 → bn128_router → DMA(쓰기), 전부 AXI-Stream으로 직결 (4.1절 라우터 포트표 참고)
- [ ] `conv3x3.out_s → bn_silu_64.in_s`는 bottleneck_router를 거치지 않고 직결
- [ ] `s_axilite` 파라미터(layer_id, scale류): PS ↔ 해당 IP 간 AXI4-Lite 배선
- [ ] `bram` 파라미터(weight, bn_scale/shift): 파라미터마다 `AXI BRAM Controller` + `BRAM` 추가, PS와 대상 IP 양쪽에서 접근 가능하도록 배선
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