# 성기호 작업 자료 인덱스

이 문서는 `Giho_Sung` 브랜치에 정리한 실습과 PPE 프로젝트 자료의 위치와
검증 범위를 설명합니다.

## 1. 실습 자료

### 1.1 RTL convolution accelerator

- 위치: `conv_accelerator/`
- 내용: controller, MAC array, window generator, input/output buffer
- 검증 자료: testbench, timing, utilization

### 1.2 HLS 기초

- 위치: `practice/hls_basics/`
- `hls_edu.cpp`: HLS C/C++ 학습 코드
- `shape.py`: tensor shape 확인 보조 코드

### 1.3 AXI DMA loopback

- 위치: `practice/dma_loopback/`
- 내용: Vitis bare-metal DMA loopback `main.c`, linker script
- 목적: model.6 연결 전 DMA 전송 경로를 독립적으로 확인

### 1.4 KV260 웹캠

- 위치: `practice/webcam/`
- 내용: OpenCV 기반 웹캠 인식 실습

## 2. PPE 프로젝트 — model.6 C2f 하드웨어

### 2.1 HLS 소스와 Golden reference

- 위치: `project/model6_hw/hls/concat/`
- `concat_channel.cpp`: Concat HLS 구현
- `tb_concat_channel.cpp`: HLS testbench
- `concat_golden_reference.py`: Python golden reference

현재 로컬 작업공간에서 확인된 원본 HLS C++ 소스는 Concat입니다. 나머지
연산 블록은 Vivado에 등록할 수 있는 export IP package 형태로 보존했습니다.

### 2.2 HLS IP repository

- 위치: `project/model6_hw/hls_ip_repo/`
- IP 종류: `conv1x1_cv1`, `conv1x1_cv2`, `conv3x3`, `bn_silu_64`,
  `bn_silu_128`, `split_channel`, `residual_add`, `concat_channel`
- 각 폴더에 `component.xml`, HDL, driver, XGUI 자료 포함

### 2.3 Vivado 통합

- 위치: `project/model6_hw/vivado/`
- `dma_passthrough.bd`: DMA 최소 통합 Block Design
- `ppe_dma_passthrough.xpr`: Vivado 2022.2 프로젝트 진입 파일
- `dma_passthrough_before_control_fix.tcl`: 문제 수정 전후 추적용 Tcl
- `dma_passthrough.xsa`: Vitis 전달용 하드웨어 플랫폼

### 2.4 Vitis 보드 코드

- 위치: `project/model6_hw/vitis/`
- `dma_loopback_v2_main.c`: Cortex-A53 bare-metal DMA 시험 코드

## 3. 검증 자료

- 위치: `project/verification/concat/`
- `y0.bin`~`y3.bin`: Concat 입력 특징맵
- `golden_output.bin`: Golden 출력

데이터 layout은 작업 단계에 따라 CHW/HWC 경계를 확인해야 하며, 관련 원인과
수정 내용은 `docs/model6/` 및 `docs/codex/` 문서에 기록했습니다.

## 4. Runtime 자료

- 위치: `project/runtime/`
- `models/best.pt`: 팀 PPE custom weight
- `models/yolov8n.pt`: YOLOv8n 기준 weight
- `python/webcam_infer.py`: 웹캠 실행 코드

모델 파일의 클래스 구성과 실행 환경은 실제 학습 설정 및 팀 main 브랜치를
함께 확인해야 합니다.

## 5. 문서와 발표자료

### 설계 및 회고

- `docs/model6/model6_hardware_summary.md`
- `docs/model6/self_intro_project_challenges_20260812.md`
- `docs/codex/CODEX_FPGA_MASTER_HANDOFF_20260812.md`
- `docs/codex/CODEX_FAILURE_ITERATIONS_20260812.md`

### 발표

- `presentation/PPE_B팀_성기호_최종본_슬라이드3교체.pptx`
- `presentation/assets/model6_c2f_design.png`
- `presentation/terminal_capture/`

## 6. 확인된 완료 범위

- HLS IP / Vivado Block Design 통합
- 100 MHz timing 만족 기록
- DRC Error 0 기록
- Bitstream / XSA 생성
- KV260 Overlay 로딩

## 7. 남은 검증

- DMA 단독 loopback의 최종 PASS 기록 확보
- 실제 특징맵 DMA 왕복
- FPGA 출력과 Python Golden 출력 비교
- 웹캠 전체 PPE pipeline 개인 재현
- FPS와 정확도 직접 측정

## 8. 제외한 자동 생성물

- Vivado `.cache`, `.gen`, `.runs`, `.sim`, `.ip_user_files`
- Vitis `.metadata`, BSP 전체, `Debug`, object 및 ELF
- 중복 export zip과 임시 로그

이 파일들은 저장소 크기를 크게 늘리며 Vivado/Vitis 2022.2에서 재생성할 수
있기 때문에 GitHub 업로드 대상에서 제외했습니다.
