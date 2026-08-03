# model.6 (C2f 블록) FPGA 구현 정리

> 목적: 지금까지 HLS로 설계·검증한 7개 IP를 Vivado Block Design에서
> 실제로 연결하기 위해, C2f 구조·IP 연결 방식·파라미터 공급 방식을
> 정리한 문서입니다.

---

## 1. 배경 스펙

| 항목 | 값 |
|---|---|
| 대상 | YOLOv8n의 model.6 (C2f 블록, 128채널, Bottleneck 2개) |
| 입력 해상도 | 640×640 (특징맵 기준 40×40) |
| 클럭 | 100MHz |
| 목표 프레임레이트 | 10~15fps |
| 양자화 | INT8 (DSP 패킹 없이 기본 INT8 MAC) |
| 타겟 보드 | KV260 (LUT 117,120 / BRAM18 288 / DSP 1,248) |

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

## 3. IP 목록 (7종)

| IP | 역할 | 채널 (in→out) | 프레임당 호출 횟수 |
|---|---|---|---|
| `conv1x1_stream` | cv1 (확장) | 128→128 | 1 |
| `split_channel_stream` | 채널 분리 | 128→64+64 | 1 |
| `conv3x3_stream` | Bottleneck 내부 conv | 64→64 | **4** (Bottleneck 2개 × 2) |
| `bn_silu_64_stream` | conv3x3 뒤 BN+SiLU | 64→64 | **4** |
| `residual_add_stream` | Bottleneck 덧셈 | 64+64→64 | **2** |
| `concat_channel_stream` | 4-branch 병합 | 64×4→256 | 1 |
| `conv1x1_cv2_stream` | cv2 (축소) | 256→128 | 1 |
| `bn_silu_128_stream` | cv1/cv2 뒤 BN+SiLU | 128→128 | **2** (cv1 뒤, cv2 뒤) |

**"4벌 재사용"이 의미하는 것**: `conv3x3_stream`을 Vivado에 4개 따로 배치하는 게
아니라, **IP 인스턴스는 1개만 두고 Bottleneck 1의 conv1 → conv2 → Bottleneck 2의
conv1 → conv2 순서로 같은 회로를 순차 재사용**합니다. 물리적으로 4벌을 두면
LUT가 4배로 필요해 KV260 예산을 넘습니다. `bn_silu_64`, `residual_add`도 동일한
이유로 각각 1개 IP만 배치하고 재사용합니다.

---

## 4. IP 연결 방식 — AXI-Stream + DMA

### 4.1 데이터 경로: 전부 AXI-Stream

IP끼리는 배열이 아니라 **AXI-Stream(`ready`/`valid` 핸드셰이크)**으로 직결합니다.
Block Design에서 한 IP의 출력 스트림 포트를 다음 IP의 입력 스트림 포트에
선으로 연결하면 됩니다.

```
DMA(읽기) → conv1x1(cv1) → bn_silu_128 → split ─┬→ [스킵버퍼로]
                                                  └→ Bottleneck1 → Bottleneck2 → concat → conv1x1(cv2) → bn_silu_128 → DMA(쓰기)
```

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
| bn_silu_128 | in_s | out_s | cv1 뒤/cv2 뒤 2번 재사용 |
| split | in_s | y0_s, y1_s | 출력 2개 |
| conv3x3 | in_s | out_s | 4번 재사용 |
| bn_silu_64 | in_s | out_s | 4번 재사용 |
| residual_add | x_s, fx_s | out_s | 입력 2개 |
| concat | y0_s, y1_s, y2_s, y3_s | out_s | 입력 4개, 내부 스킵버퍼 보유 |
| conv1x1 (cv2) | in_s | out_s | |

---

## 7. 현재 자원 사용 현황 (최신)

물리적으로 1벌씩 배치되는 IP 기준 (시분할 재사용 IP는 1벌로만 계산):

| 자원 | 현재 합계 | KV260 예산 | 상태 |
|---|---|---|---|
| BRAM18 | 150 | 288 | 여유 138 |
| LUT | 136,882 | 117,120 | **초과 19,762** |
| DSP | 598~800대 (재확인 필요) | 1,248 | 여유 |

**LUT는 아직 예산 초과 상태**이며, 현재 conv3x3/conv1x1에 `BIND_OP`
(덧셈 연산을 LUT 대신 DSP로 유도) 최적화를 진행하며 줄여나가는 중입니다.
BRAM은 concat 스킵버퍼에 `ARRAY_RESHAPE`를 적용해 300→150으로 해결.

---

## 8. Vivado 연결 시 체크리스트

- [ ] 8개 IP(conv1x1×2, bn_silu×2 재사용, conv3x3, bn_silu_64, residual_add, split, concat) Block Design에 추가
- [ ] 데이터 경로: DMA(읽기) → conv1x1(cv1) → bn_silu_128 → split → [Bottleneck 경로] → concat → conv1x1(cv2) → bn_silu_128 → DMA(쓰기), 전부 AXI-Stream으로 직결
- [ ] `s_axilite` 파라미터(layer_id, scale류): PS ↔ 해당 IP 간 AXI4-Lite 배선
- [ ] `bram` 파라미터(weight, bn_scale/shift): 파라미터마다 `AXI BRAM Controller` + `BRAM` 추가, PS와 대상 IP 양쪽에서 접근 가능하도록 배선
- [ ] Address Editor에서 각 IP/BRAM의 메모리 주소 확인 및 헤더 export
- [ ] PS 펌웨어: 위 5.4절 순서대로 파라미터 로드 → 트리거를 코드로 구현
