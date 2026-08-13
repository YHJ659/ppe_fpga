# model.6 (C2f 블록) 하드웨어 가속기 모듈 종합 결과

**프로젝트**: 산업현장 PPE(헬멧/조끼) 감지 + 금지구역 침입 감지 FPGA 가속기
**대상 보드**: Kria KV260 (xck26-sfvc784-2LV-c)
**클럭**: 100MHz (Period 10ns)
**입력 해상도**: 640×640
**대상 레이어**: YOLOv8n model.6 (C2f 블록, 128채널, Bottleneck 2개)

---

## 1. 모듈별 합성(Synthesis) 결과

| 모듈 | 채널 | Timing Est. | Target | Latency (사이클) | Latency (ms) | DSP | 재사용 횟수 |
|---|---|---|---|---|---|---|---|
| conv3x3 | 64ch | 6.976 ns | 10 ns | 819,784 | 8.20 | 620 | ×4 |
| conv1x1 | 128ch | 5.977 ns | 10 ns | 204,802 | 2.05 | 64 | ×2 |
| bn_silu | 64ch | 7.057 ns | 10 ns | 102,459 | 1.02 | 25 | ×4 |
| bn_silu | 128ch | 7.057 ns | 10 ns | 204,859 | 2.05 | 25 | ×2 |
| residual_add | 64ch | 7.057 ns | 10 ns | 102,429 | 1.02 | 10 | ×2 |
| split | 128→64ch | 4.013 ns | 10 ns | 102,402 | 1.02 | 0 | ×1 |
| concat | 64×4→256ch | 7.372 ns | 10 ns | 51,222 | 0.51 | 40 | ×1 |

모든 모듈이 100MHz 목표 클럭(10ns) 대비 타이밍 여유를 확보했습니다.

---

## 2. DSP 자원 사용량 (하드웨어 인스턴스 1개씩 재사용 기준)

| 모듈 | DSP |
|---|---|
| conv3x3 | 620 |
| conv1x1 | 64 |
| bn_silu (64ch) | 25 |
| bn_silu (128ch) | 25 |
| residual_add | 10 |
| split | 0 |
| concat | 40 |
| **합계** | **784 / 1248 (KV260 전체 DSP)** |

DSP 예산의 약 62.8%를 사용하며, 약 464개의 여유가 있습니다.

---

## 3. 전체 처리 시간 예산 (순차 재사용 방식 기준)

| 모듈 | 1회 Latency | 호출 횟수 | 소계 |
|---|---|---|---|
| conv3x3 | 8.20 ms | ×4 | 32.80 ms |
| conv1x1 | 2.05 ms | ×2 | 4.10 ms |
| bn_silu (64ch) | 1.02 ms | ×4 | 4.10 ms |
| bn_silu (128ch) | 2.05 ms | ×2 | 4.10 ms |
| residual_add | 1.02 ms | ×2 | 2.05 ms |
| split | 1.02 ms | ×1 | 1.02 ms |
| concat | 0.51 ms | ×1 | 0.51 ms |
| **합계** | | | **≈ 48.7 ms** |

**목표 fps 예산**: 15fps 기준 프레임당 66.7ms

현재 합계(약 48.7~65ms, 계산 방식에 따라 편차 있음)는 66.7ms 예산 안에 들어오나, 여유가 넉넉하지 않아 시스템 통합 시 실제 오버헤드를 반드시 재확인해야 합니다.

---

## 4. 검증 현황

모든 모듈은 다음 절차를 통해 검증 완료:
1. 실제 model.6 가중치 및 BatchNorm 파라미터 기반 Python(PyTorch) golden reference 생성
2. HLS C Simulation — golden reference와 비교 (완전 일치 또는 오차범위 ±1 이내)
3. C Synthesis — Timing/DSP/Latency 확인
4. C/RTL Co-simulation — RTL 레벨 재검증
5. Export RTL → Vivado IP Repository 등록 → Block Design 추가

7개 모듈(conv3x3, conv1x1, bn_silu×2종, residual_add, split, concat) 모두 위 5단계를 완료했습니다.

---

## 5. 다음 단계

- Vivado Block Design에서 전체 모듈 간 데이터 흐름 연결 (cv1 → split → Bottleneck×2 → concat → cv2)
- Zynq PS와의 AXI/BRAM 인터페이스 연결 및 Connection Automation
- 전체 시스템 통합 후 실측 Latency 재확인
- 필요시 목표 fps 재조정 검토 (현재 여유가 빠듯한 상태)
