# PPE FPGA 프로젝트 — 자소서용 난제·실패·해결 소재

작성 기준: 2026-08-12  
원칙: 개인 직접 수행, 팀 공동 해결, 확인되지 않은 결과를 분리한다.

## 0. 결과를 먼저 정확히 정의하기

### 개인 직접 확인 완료

- SystemVerilog 3×3 Conv accelerator 설계 및 Golden 검증
  - 초기 108/108, 확장 648/648 bit-exact
  - 150 MHz OOC timing: WNS +3.789 ns
- model.6 C2f Vivado 통합 과정 참여
- Routing/Timing/DRC 로그 분석과 반복 수정
- 최종 개인 빌드: WNS +0.220 ns, WHS +0.010 ns, DRC Error 0
- Bitstream/HWH/XSA 생성
- KV260 SSH, Logitech C270, `/dev/video0/1` 확인
- PYNQ에서 model.6 Overlay 로딩과 IP address map 확인

### 개인 환경에서 미완료

- DMA MMIO 전체 전송·연산 완료
- 본인 환경의 실시간 PPE bounding box 출력
- 본인이 직접 측정한 최종 FPS

### 팀 공동 최종 결과

- `main/model6_hw_fix` 기반 model.6 hybrid pipeline
- FPGA: cv1~Concat, CPU: cv2~Detect
- y0/y1 204,800 B mismatch 0
- 전체 feature correlation 0.999
- detection 88/90 재현(97.8%)
- 실시간 약 0.77~0.79 FPS

자소서에서 팀 결과를 사용할 때는 반드시 “팀 공동 결과”와 본인의 역할을 함께 쓴다.

---

## 사례 1. 단위 검증은 성공했지만 전체 Routing이 실패한 경험

### 상황

각 HLS IP와 초기 3×3 Conv RTL은 simulation과 synthesis에서 정상 동작했다.
그러나 model.6 전체를 Vivado Block Design으로 통합하자 implementation 단계에서
합법적인 routing을 만들지 못했다.

### 증거

- routing-error nets: 최대 58,353
- node overlaps: 최대 66,590
- congestion level: 6
- illegal routing 상태의 WNS: -9.210 ns
- LUTLP-1 combinational loop 존재

### 어려웠던 이유

전체 LUT/DSP 개수가 디바이스 한도 안에 있어도 특정 영역에 LUTRAM, 초광폭 AXIS,
high fan-out control이 집중되면 배선할 공간이 없어진다. “자원 사용률이 100% 미만이면
배치·배선된다”는 예상이 틀렸다.

### 해결 과정

1. Vivado의 route status, DRC, high fan-out, hierarchy utilization을 분리해서 확인
2. AXI Stream TREADY/TVALID 조합 경로에 register boundary 삽입
3. BN64/BN128 interface의 forward/reverse register mode 조정
4. Conv3×3 병렬도와 ARRAY_PARTITION이 만드는 LUTRAM·배선 집중 분석
5. cv2를 FPGA에서 CPU로 이동하는 HW/SW partition 재설계

### 결과

- LUTLP-1: 1 → 0
- routing-error nets 약 96.1% 감소
- node overlaps 약 97.4% 감소
- cv2 이전 후 통합 설계 LUT 약 91% → 약 56% 수준으로 감소한 팀 기록
- 이후 legal routing, timing closure, bitstream 생성으로 수렴

### 자소서 핵심

> 총자원 수치만 보지 않고 물리적 배선 가능성을 별도 문제로 재정의했다. 부분 최적화로
> 해결되지 않자 연산 경계 자체를 바꾸는 HW/SW partition 결정을 내렸다.

---

## 사례 2. C Simulation에서는 보이지 않던 FPGA Stream Deadlock

### 상황

HLS C Simulation은 통과했지만 실제 FPGA에서는 bottleneck router가 약 82픽셀 부근에서
멈추는 현상이 발생했다.

### 원인

C Simulation의 stream은 사실상 충분히 큰 버퍼처럼 동작하지만 실제 AXI4-Stream FIFO는
깊이가 제한된다. Producer는 `fx`를 먼저 쓰고 consumer는 `x`를 먼저 읽는 순서라 서로
기다리는 교착이 발생했다.

### 해결 과정

- Router의 순차 producer/consumer 구조를 DATAFLOW로 변경
- Residual x/fx 경로에 AXI4-Stream Data FIFO 추가
- FIFO memory type을 distributed RAM으로 제한해 BRAM/URAM 예산 보호
- 1600 pixel 전체 처리 여부로 재검증

### 결과

- 82 pixel 정지 → 1600 pixel 전체 처리
- CSim PASS만으로 하드웨어 동작을 보장하지 않는다는 검증 기준 확립

### 자소서 핵심

> 소프트웨어 시뮬레이터와 실제 하드웨어의 버퍼 조건이 다르다는 점을 찾아, 기능 코드가
> 아니라 데이터 생산·소비 순서와 FIFO 구조를 수정했다.

---

## 사례 3. BRAM 주소 규약 때문에 값은 그럴듯하지만 결과가 틀린 문제

### 상황

Conv 출력은 활성값처럼 보였지만 Golden 결과와 맞지 않았다. 단순 scale이나 channel shift
가설로 설명되지 않았다.

### 원인

- HLS BRAM master는 byte address를 출력
- Block Memory Generator는 32-bit word address로 해석
- float parameter의 channel `c`가 실제로 `4c mod 256` 위치를 읽음

### 창의적인 진단

입력을 전부 0으로 만들면 accumulator가 0이므로 출력은 BN shift만으로 결정된다.
여러 주소 가설을 대입해 어느 coefficient를 읽는지 역으로 추정했다.

### 결과

- `4c mod 256` 가설: 128/128 channel 재현
- COE 값을 0,4,8… 위치에 배치하고 memory depth를 4배로 조정
- y0/y1 기준 204,800 B mismatch 0이라는 팀 최종 결과

### 자소서 핵심

> 출력이 틀렸다는 현상만 고치지 않고, 입력을 통제해 내부 파라미터 접근 규칙을 역추론하는
> 실험을 설계했다.

---

## 사례 4. CHW/HWC 레이아웃 불일치

### 상황

모든 값이 존재하지만 검출 결과가 무너지는 문제를 만났다.

### 원인

PyTorch tensor는 CHW로 다루지만 DMA와 HLS의 AXI stream beat는 픽셀 우선 HWC였다.
같은 바이트를 서로 다른 축 순서로 해석해 channel 위치가 뒤섞였다.

### 해결

- CPU→FPGA: CHW tensor를 HWC로 transpose 후 DMA 전송
- FPGA→CPU: HWC raw output을 CHW로 복원
- 경계 계약을 `[40][40][128]` 입력, `[40][40][256]` 출력으로 문서화

### 결과

- main 최종본의 전체 feature correlation 0.999
- software detection 90건 중 88건 재현

### 자소서 핵심

> 알고리즘 오류가 아닌 인터페이스 계약 오류를 의심하고, 값·shape·stride·byte order를
> 경계별로 고정했다.

---

## 사례 5. DMA 길이와 PS–PL 폭 설정의 예상치 못한 실패

### 상황

입력 204,800 B와 출력 409,600 B를 보내야 하지만 DMA 기본 length width는 14bit라
16,383 B까지만 표현할 수 있었다. 또한 `.bit`만 로드했을 때 일부 DMA register write가
반영되지 않는 현상도 있었다.

### 해결

- AXI DMA `c_sg_length_width`: 14 → 26
- DMA 내부를 무리하게 1024/2048-bit로 키우지 않고 32-bit로 유지
- 경계에 AXI4-Stream Data Width Converter 배치
- 런타임에서 AFI/AFIFM PS↔PL width register 교정
- 완료 조건을 Idle이 아니라 IOC interrupt bit로 판정

### 결과

- 409,600 B를 단일 transaction으로 받을 수 있는 구조
- length width 변경 자체는 LUT +183, FF +201, BRAM/DSP 증가 0이라는 팀 기록
- DMA가 사용하던 불필요한 BRAM 압박 완화

### 자소서 핵심

> 연산기만 최적화하지 않고 DMA register width와 PS–PL interconnect 설정까지 시스템
> 경계로 확장해 분석했다.

---

## 사례 6. Bitstream 성공 후에도 End-to-End가 끝나지 않은 경험

### 상황

Vivado에서 Timing, DRC, Bitstream 생성까지 성공했지만 KV260 Jupyter에서 DMA MMIO를
읽는 순간 kernel이 대기 상태가 되었다. PYNQ `DpuOverlay` 경로에서는 권한, XRT,
`t.xclbin` 생성 문제도 발생했다.

### 대응

- 다른 Xilinx 보드를 잘못 접속한 문제를 MAC address와 `arp-scan`으로 바로잡음
- SSH, hostname, USB webcam, `/dev/video*`, Jupyter port를 단계별로 확인
- `.bit/.hwh` parsing과 `Overlay.download()`를 분리해 확인
- 무리하게 “실시간 성공”으로 결론 내리지 않고 Overlay loading까지를 개인 결과로 기록
- 팀 최종본의 raw `Bitstream` + `/dev/mem` MMIO 방식과 비교해 다음 검증 경로 정리

### 결과

- 개인: Bitstream 로딩과 IP address map 확인
- 미완료: DMA full transaction과 개인 실시간 PPE
- 팀: 별도 최종 수정본으로 실시간 약 0.77~0.79 FPS 검증

### 자소서 핵심

> 성공 조건을 Bitstream 생성으로 끝내지 않고 보드의 입력–연산–출력으로 정의했다.
> 동시에 확인하지 않은 결과는 숨기지 않고 다음 검증 항목으로 남겼다.

---

## Codex를 활용한 문제 해결 방식

1. 모델 구조도와 Vivado Block Design 이미지를 제공해 shape와 연결 구조 분석
2. GitHub `main`/`Giho_Sung`, 로컬 소스, `component.xml`, Tcl을 함께 읽힘
3. Vivado%, XSCT, KV260 SSH 터미널의 실제 출력을 다시 전달
4. 오류 메시지에서 직접 원인·근본 원인·검증 명령을 분리
5. 한 번에 한 변경만 적용하고 전후 수치를 비교
6. 로그가 없는 성공은 주장하지 않고 확인 필요로 유지
7. 작업 기록, 인수인계 문서, 발표자료를 동일한 증거에서 생성

이 방식은 “AI가 대신 개발했다”가 아니라 “AI를 로그 분석과 가설 관리에 사용하고,
실제 실행과 최종 판단은 사람이 담당했다”는 점을 보여준다.

---

## 자소서용 STAR 예시 1 — Routing congestion

### S

YOLOv8n model.6의 여러 HLS IP를 KV260에 통합했지만 simulation 성공과 달리 전체
implementation에서 66,590 node overlaps와 congestion level 6이 발생했다.

### T

개별 IP 기능을 유지하면서 100 MHz legal routing과 Bitstream 생성을 확보해야 했다.

### A

Codex와 Vivado route/DRC/hierarchy report를 교차 분석해 조합루프, 초광폭 AXIS,
LUTRAM 집중을 분리했다. Register boundary를 삽입하고 병렬도와 memory mapping을
검토했으며, 가장 큰 자원 부담인 cv2를 CPU로 이동해 HW/SW 경계를 재설계했다.

### R

LUTLP-1을 제거하고 routing error를 96% 이상 줄였다. 최종 개인 빌드에서
WNS +0.220 ns, DRC Error 0, Bitstream/XSA 생성을 확인했다. 이 경험으로 총자원보다
물리적 배선성과 데이터 이동을 함께 고려하는 시스템 관점을 배웠다.

## 자소서용 STAR 예시 2 — 보이지 않는 주소 규약 오류

### S

하드웨어 출력이 활성값처럼 보이지만 Golden과 맞지 않아 scale, channel 순서,
DMA 분할 등 여러 가설이 충돌했다.

### T

값이 언제부터 틀어지는지 추측이 아니라 재현 가능한 실험으로 규명해야 했다.

### A

입력을 0으로 고정해 출력을 BN shift 하나의 함수로 만들고 주소 후보를 전수 대입했다.
그 결과 HLS byte address와 BRAM word address 차이로 `4c mod 256`을 읽는다는 규칙을
찾았다. COE를 stride 4로 재배치하고 HWC 경계 계약도 함께 수정했다.

### R

팀 최종 검증에서 y0/y1 204,800 B가 모두 일치하고 전체 feature correlation 0.999를
확인했다. 복잡한 시스템 문제를 관찰 가능한 단순 실험으로 축소하는 방법을 배웠다.

---

## 면접에서 피해야 할 과장

- “main 전체 코드를 내가 만들었다” → 5명 팀 공동 저장소
- “BRAM과 URAM을 전부 크게 줄였다” → 일부 구조의 낭비를 줄였지만 최종 사용률은
  BRAM 86.5%, URAM 93.8%로 높음
- “15 FPS를 달성했다” → 목표였으며 팀 실측은 약 0.79 FPS
- “내가 실시간 PPE를 완료했다” → 개인 기록은 Overlay loading까지
- “150 MHz model.6 전체 성공” → 150 MHz는 초기 8×8 single-channel RTL OOC 결과

