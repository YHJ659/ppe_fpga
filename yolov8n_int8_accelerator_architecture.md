# YOLOv8n INT8 가속기 아키텍처 설계 정리

Vivado 블록 디자인으로 CPU(Zynq PS)와 AXI 인프라를 대체하고, 학습이 끝난 YOLOv8n을 추론하는 **INT8 Conv 가속기**를 직접 RTL로 설계하기 위한 아키텍처 정리 문서.

---

## 1. 전체 구조와 역할 분담

가속기는 **PS(ARM) + PL(가속기)** 구성을 전제로 하며, 연산의 무거운 부분만 PL로 내린다.

| 담당 | 처리 내용 |
|------|-----------|
| PS (ARM) | 전처리, Upsample / Concat, Detect head 디코딩, 후처리(NMS), 레이어 순서 제어 |
| PL (가속기) | Conv → BN(fold) → SiLU → (필요시 MaxPool) |

가속기는 두 개의 AXI 인터페이스를 가진다.

- **AXI4-Lite Slave** — 레지스터/제어용 (ARM이 마스터)
- **AXI4 Master** — DDR 데이터 접근용 (가속기가 마스터)

          ARM CPU (PS)
               │
     AXI4-Lite Master
               │
      ┌──────────────────┐
      │   Accelerator     │
      │                   │
      │ AXI4-Lite Slave   │◄── 제어 레지스터
      │                   │
      │ Controller FSM    │
      │ Buffer            │
      │ PE Array          │
      │                   │
      │ AXI4 Master       │──────► DDR(외부 메인 메모리(RAM))
      └──────────────────┘

---

## 2. 확정된 설계 결정

프로젝트 초반에 다음 두 가지를 확정하여 자원과 설계 범위를 고정했다.

### 데이터 정밀도: INT8 양자화

- 입력 activation: INT8, weight: INT8
- MAC 누산기: **INT32** (8b×8b를 채널 수만큼 더하므로 오버플로 방지 위해 필수)
- 출력: INT32 → requantize → INT8

INT8을 택하면서 두 가지 하드웨어 단순화가 따라온다.

1. **SiLU가 256-entry LUT로 완전 대체 가능** — INT8 입력이라 근사 계산 없이 룩업 하나로 끝난다.
1-1 Lut(look up table)란 FPGA 내부 메모리(BRAM 또는 Distributed ROM) 에 미리 계산해둔 값을 저정해두고 읽어 내기만 하는 방식을 뜻함 즉 활성함수의 값(INT8 입력이라면 입력값은 최대 256가지) 를 저장해놓고 필요할때 꺼내 읽는다는 의미    
2. **BatchNorm이 requantize 스케일에 흡수** — 별도 BN 하드웨어가 사라진다.

### 가속기 커버 범위: Conv 엔진

Conv + BN(fold) + SiLU + (필요시 MaxPool)까지만 PL(가속가)이 담당하고, 나머지 레이어(Upsample, Concat, Detect head)는 ARM이 처리한다. 가속기는 "config를 받으면 conv 한 판을 돌리는 기계"로 단순하게 유지한다.

### PE 배열 방식: Output Stationary (OS)

Weight Stationary와 비교한 결과 OS를 선택했다.

- **INT8 + requantize 궁합**: 누산기가 한 자리에 고정돼 "INT32로 다 누적 → requantize → INT8 배출" 흐름이 자연스럽다.
- **YOLOv8n의 1×1 conv 비중**: C2f 블록은 1×1 conv가 많고, 이는 순수 채널 방향 누산이라 OS(output을 고정하는 방식)가 명확히 유리하다.

### skew 생략 (1단계)
skew_network은 보통 순수 systolic array에서 skew는 타이밍을 맞추기 위한 장치이다 .Pe(MAC 연산을 수행하는 가장 작은 연산 단위) 사이에 레지스터를 하나씩 끼우면(파이프라인), 데이터가 한 칸 이동하는 데 1사이클이 걸립니다(latency가 생김). 그러면 PE[0][1]에 도착하는 동작이 PE[0][0]보다 1사이클 늦습니다. 이 지연을 상쇄하려고 입력을 미리 계단식으로 어긋나게(skew) 넣어주는 동작을 한다. 하지만 중소 배열(8×8, 16×16)에 목표 클럭 100~200MHz 수준이면 브로드캐스트 방식으로 충분하다고 함.

- 1단계: **skew 없이 브로드캐스트**로 구현 (컨트롤러 단순, 기능 검증 우선)
- 타이밍이 안 나오면 그때 PE 간 레지스터 + skew를 삽입해야 할수도 있음 (데이터패스 큰 변경 없이 추가 가능)

브로드 캐스트 방식: act(feature map 쪽 입력)을 한 행의 모든 PE에 동시에 뿌리고, weight를 한 열에 동시에 뿌립니다. 레지스터 없이 조합 논리로 전달. 설계가 훨씬 단순하고 컨트롤러도 간단해짐. 대신 배열이 커지면 타이밍이 나빠짐
---

## 3. 데이터패스 — PE와 배열

### PE 하나의 내부 (Output Stationary)

Output Stationary의 정의는 **누산기가 PE 안에 붙박이로 있다**는 것이다.

- activation(INT8)과 weight(INT8)가 매 사이클 입력으로 들어온다.
- 곱셈기(8b×8b)를 거친 값이 PE 내부의 **INT32 누산기**에 계속 쌓인다 (`acc += mult`).
- activation은 옆 PE로, weight는 아래 PE로 그대로 흘러나간다.
- 누산기는 움직이지 않는다 — 채널이 깊을수록 한 자리에서 오래 누적하니 유리하다.

### 배열로 확장

- **각 PE는 출력 feature map의 한 좌표를 전담**한다 (`acc[i,j]`가 그 위치의 부분합을 쥔다).
- activation은 왼쪽에서 **가로**로, weight는 위에서 **세로**로 흘러들어간다.
- 입력 채널을 하나씩 흘려보내며 사이클마다 누적한다.
- 입력 채널을 다 돌면 그 PE의 누산이 완성되고, 아래로 배출되어 requantize → SiLU를 거친다.

 Output Stationary는 결과를 저장하는 누산기를 PE 안에 고정해 두고, activation과 weight만 계속 흘려보내며 계산하는 방식임. 각 사이클마다 두 값을 곱한 결과를 같은 누산기에 계속 더해 최종 출력값을 완성함.PE 하나가 출력 Feature Map의 한 픽셀을 담당한다고 생각하면 됨. 입력 데이터와 가중치는 계속 지나가지만, 결과를 저장하는 누산기는 움직이지 않고 같은 자리에서 모든 곱셈 결과를 차례대로 더해 최종 출력값을 만듬.

 PE를 여러 개 배열하면 각 PE가 출력 Feature Map의 서로 다른 위치를 하나씩 계산함. Activation은 왼쪽에서 오른쪽으로, Weight는 위에서 아래로 전달되고, 각 PE는 자신의 출력값만 계속 누적하고 모든 입력 채널의 계산이 끝나면 누적된 값이 최종 결과가 되어 다음 단계(Activation, Quantization 등)로 전달됨.
---

## 4. 버퍼 구조 — 더블 버퍼링(핑퐁)


### 버퍼가 필요한 이유

가중치와 입력은 **DDR(외부 메인 메모리)**에 있다. DDR은 크지만 느리고 왕복 지연이 크다. 반면 PE 배열은 매 사이클 데이터를 먹어야 한다. 그래서 DDR ↔ 배열 사이에 빠른 on-chip 완충지대(BRAM)를 둔다.

### 타일링

전체 feature map과 weight를 BRAM에 다 올릴 수 없으므로, 한 번에 처리할 만큼만 잘라서(타일) 올린다. 배열이 한 타일을 처리하면 다음 타일을 올려 반복한다.

### 더블 버퍼링(핑퐁)

버퍼를 두 개 두어, 배열이 버퍼 A를 처리하는 동안 DMA가 버퍼 B를 채운다. 타일이 끝나면 역할을 맞바꾼다(ping-pong). 전송과 연산이 완전히 겹쳐 배열이 멈추지 않는다.

### RTL 구현 요소

- **BRAM 뱅크**: act용 2뱅크(`act_buf[0]`, `act_buf[1]`) + weight용 2뱅크(`w_buf[0]`, `w_buf[1]`). Simple dual-port로 한 포트는 DMA write, 다른 포트는 배열 read.
- **핑퐁 토글**: `cur_buf` 1비트. 배열은 `act_buf[cur_buf]` 읽기, DMA는 `act_buf[~cur_buf]` 쓰기. 타일 끝나면 `cur_buf <= ~cur_buf` — 이 한 줄이 핑퐁의 전부.
- **교대 조건(동기화)**: 역할을 바꾸려면 `compute_done`(배열 연산 완료)과 `dma_done`(다음 타일 적재 완료)이 **모두** 만족돼야 한다. 연산이 전송보다 오래 걸리도록 타일 크기를 잡으면(연산 bound) DMA가 항상 먼저 끝나 배열이 기다리지 않는다.

### 타일 크기 산정

- act 타일: `타일_H × 타일_W × 입력채널` × 1바이트(INT8)
- weight 타일: `커널 × 커널 × 입력채널 × 출력채널` × 1바이트

이것이 BRAM 한 뱅크에 들어가야 하고, 핑퐁이므로 실제 소비량은 **×2**다. FPGA의 BRAM 총량에서 역산해 타일 크기 상한을 정한다.

---

## 5. 컨트롤러 FSM

### FSM이 도는 루프의 정체

한 레이어 처리는 결국 다중 중첩 루프이며, FSM은 이를 **상태 + 카운터**로 편 것이다.


### 상태 전이

| 상태      |  내용 |
|----------|------|
| IDLE     | start 신호 대기 |
| LOAD_CFG | 채널·커널·스트라이드 등 config 읽기 |
| LOAD_TILE | act·weight 타일 DMA 적재 |
| COMPUTE   | 배열 MAC 누적 |
| REQUANT + SiLU | INT32 → INT8 변환, LUT 통과 |
| WRITE_BACK | 결과 타일 DMA out |
| DONE | 모든 타일 끝 → 인터럽트(irq) |

두 개의 되돌이 루프가 핵심이다.

LOAD_CFG: 가속기가 이번 컨볼루션을 어떻게 수행할지에 대한 설정값을 먼저 읽는 작업
인터럽트: 인터럽트는 CPU가 실행 중인 작업을 잠시 멈추고, 특정 이벤트를 처리하도록 알려주는 신호 

- **안쪽 루프(입력채널)**: `COMPUTE` 후 입력채널이 남으면 `LOAD_TILE`로 되돌아가 다음 입력채널 타일을 누적. 누산기는 이 루프 내내 비워지지 않는다. 다 돌아야 한 출력 지점의 conv가 완성된다.
- **바깥 루프(출력 타일)**: `WRITE_BACK` 후 출력 타일이 남으면 다시 `LOAD_TILE`로. 이때 누산기는 초기화된다.

### RTL 구현 포인트

- **상태 레지스터 + 카운터**가 전부다. `state`(enum), `ic_cnt`(입력채널 타일 카운터, 안쪽 루프), `oc_cnt`·`pos_cnt`(출력채널·위치 타일 카운터, 바깥 루프).
- **더블버퍼링과의 결합**: `COMPUTE`가 현재 버퍼로 연산하는 동안 `LOAD_TILE`의 DMA가 반대 버퍼를 미리 채운다. FSM 상으로는 순차지만 DMA 엔진이 독립적으로 돌아 시간적으로 겹친다.
- **레이어 순차 처리**: 이 FSM은 **한 레이어**를 처리한다. 레이어 간 순서는 ARM이 관장한다 (config 세팅 → start → DONE 인터럽트 → 다음 레이어 config → start ...).

---

## 6. AXI 인터페이스

### 두 인터페이스의 근본 차이

|             | AXI4-Lite Slave (제어)  | AXI4 Master (데이터) |
|------------|------------------------------|--------------------|
| 마스터      | ARM                     | 가속기              |
| 슬레이브    | 가속기                    | DDR 컨트롤러        |
| 데이터량    | 소량 (레지스터 몇 개)      | 대량 (버스트)       |
| 가속기 역할 | 수동적 (값을 받음)         | 능동적 (DDR을 긁어옴) |

제어는 가끔·소량, 데이터는 항상·대량이라 성격이 정반대여서 물리적으로 분리한다.

### 레지스터 맵 (AXI4-Lite Slave)

ARM과 가속기의 계약서. ARM은 이 주소들에 값을 써서 가속기를 조종한다.

| 오프셋 | 레지스터 | 방향    |            내용                 |
|--------|----------|------|--------------------------------|
| 0x00   | CTRL     | W    | bit0=start, bit1=soft_reset    |
| 0x04   | STATUS   | R    | bit0=busy, bit1=done           |
| 0x08   | IN_ADDR  | W    | 입력 feature map DDR 베이스 주소  |
| 0x0C   | WGT_ADDR | W    | weight DDR 베이스 주소           |
| 0x10   | OUT_ADDR | W    | 출력 DDR 베이스 주소              |
| 0x14   | CFG_DIM  | W    | 입력채널·출력채널 (16b씩 패킹)      |
| 0x18   | CFG_HW   | W     | feature map H·W                |
| 0x1C   | CFG_KSP  | W    | 커널·스트라이드·패딩                |
| 0x20   | REQ_SCALE | W   | requantize 스케일 M, shift        |

ARM 사용 흐름: 0x08~0x20에 레이어 파라미터를 다 써넣고 → 0x00에 start=1 → 0x04 폴링 또는 인터럽트로 done 대기 → 다음 레이어 반복.

### AXI의 5채널

AXI는 하나의 버스가 아니라 독립적으로 움직이는 5개 채널이다.

- **쓰기**: AW(주소) · W(데이터) · B(응답)
- **읽기**: AR(주소) · R(데이터)

### VALID/READY — AXI의 유일한 문법

모든 채널은 VALID/READY handshake 하나로만 동작한다.

- 보내는 쪽이 데이터를 준비하면 `VALID=1`
- 받는 쪽이 받을 준비가 되면 `READY=1`
- **둘 다 1인 그 클럭 엣지에** 데이터가 전달된다 (transfer 성립)

어느 한쪽이 안 준비됐으면 자동으로 기다린다. 이 악수 하나가 모든 흐름 제어를 대신한다.

### AXI4-Lite Slave 구현의 실체

사실상 **주소 디코더 + 레지스터 뱅크**다.

- 쓰기: AW에서 주소, W에서 데이터를 받으면 해당 레지스터에 값을 래치하고 B로 완료(BRESP=OKAY) 응답.
- 읽기: AR에서 주소를 받으면 해당 레지스터 값을 R에 실어 RVALID로 내보냄.
- Lite는 버스트가 없어 한 번에 32비트 하나씩만 주고받으므로 카운터가 필요 없다.

### AXI4 Master (Full) — 버스트

Master는 방향이 반대(가속기 주도)이고, 결정적으로 **버스트(burst)**가 있다. "이 주소부터 연속 N워드를 한 번에" 요청한다. 타일 수백 바이트를 1워드씩 왕복하면 지연이 폭발하므로 버스트로 한 방에 가져온다.

추가 신호: `AxLEN`(버스트 길이), `AxSIZE`(워드당 바이트), `AxBURST`(보통 INCR), `xLAST`(버스트 마지막 word).

Master read 흐름 (LOAD_TILE):

1. AR로 "베이스 주소 + 버스트 길이 + INCR" 발행
2. DDR이 R로 N워드를 연속으로 흘려보냄 (각 word마다 RVALID)
3. 가속기는 받는 족족 핑퐁 버퍼(BRAM)에 씀
4. 마지막 word에 RLAST=1 → 버스트 종료
5. 타일이 더 필요하면 다음 버스트 발행, 반복

write(WRITE_BACK)는 대칭: AW로 주소+길이 → W로 결과 word 연속 송출 → WLAST 종료 → B로 완료 확인.

### 블록 디자인 결선

- 가속기의 **AXI4-Lite Slave 포트** ← ARM(Zynq PS)의 M_AXI_GP (범용 마스터 포트)
- 가속기의 **AXI4 Master 포트** → ARM의 S_AXI_HP (고성능 슬레이브 포트, DDR 컨트롤러로 이어짐)

가속기는 한 몸에 슬레이브 얼굴과 마스터 얼굴을 둘 다 가진다.

### 직접 구현 vs IP 사용

- **AXI4-Lite Slave**: 직접 구현 권장. 단순하고, 레지스터 맵이 곧 인터페이스라 이해가 중요하다. Vivado "Create and Package IP"가 Lite Slave 골격을 자동 생성하니 레지스터 로직만 채우면 된다.
- **AXI4 Master(버스트 DMA)**: 팀 선택. Xilinx AXI DMA IP를 쓰면 설계 부담이 줄고, 대신 IP 제어 로직이 붙는다. 직접 Master를 짜면 학습·포트폴리오 가치는 높지만 검증이 까다롭다. 검증을 하지 않는다면 **AXI DMA IP 사용 쪽**이 프로젝트 완주에 안전하다.

---

## 7. 전체 동작 흐름

1. ARM이 레이어 config를 AXI4-Lite로 세팅하고 start
2. 컨트롤러 FSM이 타일 루프를 돌며 DMA로 데이터를 핑퐁 버퍼에 적재
3. OS 배열이 INT32로 누적, requantize + SiLU로 INT8 출력
4. 결과를 DDR에 쓰고 DONE 인터럽트 → ARM이 다음 레이어로

---

## 8. Conv 엔진 세부 — 입력 공급 방식

Conv는 커널이 입력 위를 미끄러지며(sliding) 겹치는 윈도우를 뽑아 곱한다. 3×3 stride 1이면 인접한 두 출력이 입력을 2/3 공유한다. 이 재사용을 어떻게 처리하느냐가 방식을 가른다.

### 세 방식 비교

|   | im2col | line buffer | 배열 내부 재사용 |
|---|--------|-------------|------------------|
| 재사용 처리 | 안 함 (펼침)  | line buffer | PE 간 데이터 전달 |
| 메모리 | 최대 9배 부풀음 | 최소 | 최소 |
| 제어 복잡도 | 낮음 | 중간 | 높음 |
| OS 배열 궁합 | 좋음 | 좋음 | 이미 OS가 함 |

- **im2col**: 각 출력 윈도우를 한 줄로 펴서 순수 GEMM(행렬연산)으로 바꿈. 데이터패스는 깔끔하지만 겹치는 입력을 중복 저장해 메모리·대역폭이     최대 9배 부풀고, 재정렬을 ARM이 하면 CPU 병목으로 돌아온다.
- **line buffer + sliding window**: FPGA conv의 정석. 입력을 몇 줄 BRAM(line buffer)에 담고 3×3 윈도우 레지스터가 그 위를 미끄러진다. 이동 시 왼쪽 두 열(6개)은 이미 레지스터에 있고 오른쪽 한 열(3개)만 새로 읽는다. 입력 중복 저장 없음, DDR 대역폭 최소, 스트리밍 친화적.

### 결정: conv 종류에 따라 경로 분기

**1×1 conv는 line buffer 우회, 3×3 conv는 line buffer 경유.**

- YOLOv8n은 C2f 블록 때문에 **1×1 conv가 절반 이상**이다. 1×1은 윈도우가 1칸이라 line buffer가 아예 필요 없고, 순수 채널 방향 곱셈이라 OS 배열에 바로 흘리면 된다.
- 3×3 conv에만 line buffer(2줄 + 현재 줄 = 3줄 상주)를 켠다. max/경계/패딩/stride 처리는 이 경로에만 붙는다.
- im2col은 채택하지 않는다 (메모리 폭증 + ARM 재정렬 병목 회피).

---

## 9. 특수 연산 처리 위치 (MaxPool / Upsample / Concat)

목표 주파수 150MHz에서 PL↔PS 왕복이 병목이 될지가 관건. 핵심은 **연산 자체가 아니라 데이터 왕복**이다. 세 연산을 판정하면 대부분 PS 왕복을 피할 수 있다.

| 연산            | 처리 위치              |           이유                                               |
|----------------|-----------------------|--------------------------------------------------------------|
| Concat         | ARM (주소 배치)         | 데이터 이동 없음, 주소만                                        |
| Upsample       | 가속기 read 주소 or ARM | nearest는 주소 조작으로 복제 회피                                |
| MaxPool (SPPF) | PL (전용 유닛)          | line buffer 재사용, max 비교기(둘 중 큰 값을 골라내는 회로)만 추가 |

### 판정 근거

- **Concat**: 연산이 아니라 두 텐서를 채널 축으로 잇는 것. 다음 conv의 입력 베이스 주소를 두 출력이 연속 주소에 놓이도록 잡으면 **데이터 이동 없이 공짜**. ARM이 주소만 관리.
- **Upsample (nearest 2×)**: 각 픽셀을 2×2로 복제. 연산은 0이지만 데이터가 4배로 분다. 가속기 AXI Master가 입력을 읽을 때 "같은 픽셀을 2번씩 읽는" 주소 패턴을 쓰면 DDR에 4배 데이터를 안 만들고 처리 가능.
- **MaxPool (SPPF 5×5, stride 1)**: 실제 비교 연산이 있지만 conv 데이터패스의 곁가지로 PL에 넣기 쉽다. 이미 있는 line buffer 위에 곱셈-누산 대신 **max 비교기(둘 중 큰 값을 골라내는 회로)**를 붙이면 된다 (같은 sliding window 구조, 연산만 max로).

Line Buffer → 여러 줄의 데이터를 저장해서 윈도우 생성
Max Comparator → 윈도우 안에서 가장 큰 값 선택
둘을 합친 구조 → Max Pooling Accelerator

### 결론

세 연산 때문에 PS로 나갈 필요가 거의 없다. Concat·Upsample은 데이터 이동 없는 주소 트릭으로 해결, MaxPool만 PL에 작은 유닛으로 추가. ARM으로 진짜 나가야 하는 건 Detect head 후처리(NMS 등 제어 흐름이 복잡한 부분)뿐이다.라고 했지만 그래도 혹시 모름.

---
최종적으로 설계해야하는 아키텍쳐 

1. Output Stationary PE 배열
INT8 곱셈기 + INT32 누산기를 격자로 배치. act는 가로, weight는 세로로 흘리고 누산기는 고정. 8×8 또는 16×16 규모, skew 없이 브로드캐스트로 시작. 가장 먼저 만들고 가장 많이 검증할 블록.

2. Requantize + SiLU LUT
INT32 누산값을 M 곱셈 + 비트시프트로 INT8로 되돌리는 유닛. BN(배치 정규화:학습 안정화용 연산층)이 이 스케일에 흡수되고, SiLU는 256-entry LUT로 처리. PE 배열 바로 뒤에 붙는 필수 후단.

3. Line buffer + sliding window
3×3 conv용 입력 재사용 구조. 3줄 상주 BRAM 위를 윈도우가 미끄러짐. 1×1 conv는 이 블록을 우회하도록 경로 분기.

4. 핑퐁 버퍼 (BRAM 2뱅크 × 2종류)
act/weight 이중 버퍼 + 1비트 토글. compute_done과 dma_done 두 신호로 역할 교대.

5. 컨트롤러 FSM
7개 상태(IDLE→LOAD_CFG→LOAD_TILE→COMPUTE→REQUANT→WRITE_BACK→DONE) + 루프 카운터. 위 블록들을 순차 구동하는 컨트롤러.

6. AXI4-Lite Slave (레지스터 뱅크)
레지스터 맵대로 주소 디코더 + 래치. Vivado IP 생성기 골격에 로직만 채우면 됨.

7. MaxPool 유닛 (SPPF)
line buffer 위에 max 비교기를 얹은 작은 곁가지 블록.

## 10. 다음 단계 (미정 / 후속 논의)

- 레지스터 맵을 실제 SystemVerilog 레지스터 뱅크 코드로 구현
- 블록 디자인에서 PS 설정 (HP 포트 활성화 등)
- line buffer의 경계/패딩/stride 처리 로직 상세 설계
- Upsample 주소 패턴을 가속기 read 로직에 흡수할지 ARM에 둘지 최종 결정
- Detect head 후처리(NMS) ARM 구현 범위 확정
