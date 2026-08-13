# PPE Monitoring AI Hardware Accelerator

AMD/Xilinx Kria KV260에서 YOLOv8n 기반 PPE 탐지의 일부 연산을 FPGA로
가속한 팀 프로젝트 저장소입니다. 이 브랜치는 성기호의 실습 기록과
`model.6 C2f` 하드웨어 통합 작업을 구분해 보관합니다.

## 저장소 구성

| 경로 | 내용 |
|---|---|
| `conv_accelerator/` | 기존 3×3 convolution RTL 실습 및 리포트 |
| `practice/` | HLS 기초, AXI DMA loopback, 웹캠 실습 |
| `project/model6_hw/` | C2f HLS 소스·IP repository·Vivado/Vitis 자료 |
| `project/verification/` | Concat golden reference와 비교용 특징맵 |
| `project/runtime/` | PPE 모델과 웹캠 실행용 Python 자료 |
| `docs/model6/` | model.6 구조, 설계 검토, 문제 해결 기록 |
| `docs/codex/` | Codex 협업 과정, 명령·로그 증거, 인수인계 문서 |
| `presentation/` | 최종 발표 PPT, 설계도, 터미널 캡처 |

세부 파일 목록과 완료 범위는 [WORK_INDEX.md](WORK_INDEX.md)를 참고합니다.

## 개발 환경

- Ubuntu 22.04
- Vivado / Vitis / Vitis HLS 2022.2
- Kria KV260 Vision AI Starter Kit
- PL clock target: 100 MHz
- Activation / weight: INT8
- Accumulator: INT32

## 개인 작업 범위

- 팀원이 만든 HLS IP의 인터페이스와 tensor shape 확인
- Vivado IP Integrator에서 PS, AXI DMA, Clock/Reset, HLS IP 통합
- Routing congestion, AXI-Stream deadlock, BRAM 주소, CHW/HWC 문제 분석
- Implementation, DRC Error 0, Bitstream/XSA 생성
- KV260 PYNQ Overlay 로딩과 웹캠 장치 확인

팀 전체 YOLO 파이프라인은 5명의 공동 결과입니다. 개인 검증은 Bitstream과
KV260 Overlay 로딩까지이며, DMA 실데이터 End-to-End 검증은 후속 과제로
구분합니다.

## 생성물을 전부 커밋하지 않은 이유

Vivado/Vitis의 `cache`, `runs`, BSP, object 파일은 수백 MB이며 같은 버전의
도구로 다시 생성할 수 있습니다. 저장소에는 재현에 필요한 소스, Tcl, Block
Design, IP package, 검증 데이터와 핵심 문서를 남기고 재생성 가능한 임시
산출물은 `.gitignore`로 제외했습니다.
