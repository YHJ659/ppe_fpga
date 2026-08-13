# GitHub `main` / `Giho_Sung` 브랜치 분석

분석일: 2026-08-12  
저장소: `https://github.com/YHJ659/ppe_fpga`

## 분석 범위

- `main` HEAD: `9343f2107805e03783b2f094d314a2168a41c786`
- `Giho_Sung` HEAD: `bc7503ed79bfc6e15427b78ec59a89ffbe280540`
- 공통 조상: `6fe28817d06a7589461029aaf6307ce58768c504`
- `main`: 185 files, 89 commits
- `Giho_Sung`: 23 files, 6 commits

전체 파일 트리를 확인했다. 소스, README, Markdown, JSON, Tcl, 리포트와
테스트벤치는 본문을 읽었다. `.bit/.xsa/.zip/.pt/.pptx/.pdf/.bin/.coe`는
파일 유형·구성·메타데이터와 관련 문서의 설명을 기준으로 분석했다.

## `Giho_Sung` 브랜치

### 개인 기술 작업으로 확인되는 부분

커밋 `d65c8a3` (`Giho_Sung`, 2026-07-23):

- SystemVerilog 3×3 convolution accelerator
- `input_buffer.sv`: INT8 입력 버퍼, 1-cycle read latency
- `window_gen.sv`: 두 줄 line buffer와 3×3 window 생성
- `mac_array.sv`: INT8 multiplier 9개와 4-stage adder tree
- `output_buffer.sv`: INT32 결과 저장
- `controller.sv`: IDLE/RUN/DRAIN/DONE FSM
- `conv_top.sv`: 위 모듈 통합
- 모듈별/통합 testbench 6개
- Vivado OOC timing/utilization report

검증 결과:

- 최초 README: 3종 × 36 = 108/108 bit-exact
- 후속 `conv_rtl_report.json`: 18 cases × 36 = 648/648 PASS
- 150 MHz(6.667 ns)에서 WNS +3.789 ns, WHS +0.059 ns
- critical path data delay 2.873 ns

한계:

- 기본 설정은 8×8, single-channel, padding 없음(8×8 → 6×6)
- AXI-Lite, IP packaging, BD 통합, Bitstream, KV260 실행은 미완료로 기록
- OOC timing이고 I/O delay 미설정 경고가 input 96, output 34개 존재
- 따라서 150 MHz를 최종 model.6 전체 시스템 성능으로 말하면 안 됨

### 브랜치의 다른 자료

- `dma_passthrough.xsa`: AXI DMA + `axis_passthrough` 최소 시스템
- `임플 및 라우팅 실패 데이터`: 전체 model.6 중간 실패 분석
  - routing-error nets 58,353 → 2,257
  - node overlaps 66,590 → 1,698
  - LUTLP-1은 0으로 개선
  - congestion level 6과 illegal routing은 남음
  - WNS -9.210 ns는 illegal routing 상태라 최종 timing으로 사용 불가
- 중간발표 PPT: 19장, 전체 HLS/Vivado 진행 상태와 당시 미완료 사항

주의: `Giho_Sung` 브랜치의 모든 파일이 한 사람의 작성물은 아니다. commit
author가 `Giho_Sung`, `prayja`, `uooosiuuu-debug`, `YHJ659`로 나뉜다.
SystemVerilog accelerator는 개인 작업으로 말할 근거가 강하지만 XSA·실패 보고·PPT는
공동/업로드 자료로 구분하는 편이 안전하다.

## `main` 브랜치

### 팀 공동 최종 구조

`ppe_fpga_final/`에는 model.6 HLS IP, testbench, Golden Python, 양자화
파라미터, COE 변환 도구, export IP package와 문서가 모여 있다.

주요 연산은 Conv1×1 cv1/cv2, BN+SiLU 64/128, Split, Conv3×3,
Residual Add, Concat, Bottleneck Router, BN128 Router다.

### `model6_hw_fix` 최종 수정본

실행 가능한 최종 수정본은 `model6_hw_fix/`가 가장 잘 정리되어 있다.

- `hw/build_fix2.tcl`: PS, DMA, SmartConnect, width converter, FIFO,
  8개 HLS IP, BRAM, address, synthesis/implementation/bitstream/XSA 자동화
- FPGA 범위: **model.6 cv1부터 Concat까지**
- CPU 범위: **model.6 cv2부터 model.7~22까지**
- FPGA 입력: int8 HWC `[40][40][128]`, 204,800 B
- FPGA 출력: int8 HWC `[40][40][256]`, 409,600 B
- PL clock: 100 MHz

최종 수정 내용:

1. float BRAM byte/word address mismatch 보정
2. bn128 static slot 반복 프레임 문제 수정
3. AXI DMA length width 14 → 26
4. PS↔PL AFI/AFIFM data width 런타임 교정
5. bottleneck router DATAFLOW deadlock 수정
6. DMA 완료 판정을 Idle 대신 IOC로 변경
7. CHW로 잘못 알려진 DMA 경계를 HWC로 수정
8. 자원 문제로 cv2를 FPGA에서 CPU로 이동

### 저장소에 기록된 팀 검증 결과

`model6_hw_fix/results/verification.md` 기준:

- y0/y1: 204,800 B 중 mismatch 0, 128/128 channels exact
- 전체 256 channels vs float reference: correlation 0.999
- 12 continuous frames: full receive 12/12, 0.050 s/frame
- detection reproduction: SW 90건 중 HW 88건, 97.8%
- LUT 69,502(59.3%), FF 135,086(57.7%), BRAM 124.5(86.5%),
  URAM 60(93.8%), DSP 476(38.1%)
- WNS +0.462 ns, TNS 0
- hybrid pipeline: 1.265 s/frame, 0.79 FPS
- `ppe_live.py`: camera MJPEG server, 기본 port 8090

이 결과는 `main`의 팀 공동 결과다. 개인이 직접 재현하지 않았다면 개인 실적으로
말하지 말고 “팀 최종 검증 결과”라고 표시해야 한다.

## 두 브랜치의 관계

`Giho_Sung`은 최종 HLS accelerator의 직접 이전 버전이라기보다 초기 학습/실습
단계의 **독립 SystemVerilog 3×3 convolution accelerator**와 중간 통합·실패
분석 자료를 보관한 브랜치다.

`main`은 팀원들의 HLS IP와 Vivado/Vitis/PYNQ 작업을 합친 최종 브랜치이며,
`model6_hw_fix`는 보드 검증과 정확도/성능 측정까지 정리한 후속 결과다.

- 개인 기여: `Giho_Sung` RTL conv 설계/검증과 본인이 직접 수행한 Vivado
  통합·로그 분석·Bitstream·KV260 bring-up
- 팀 공동 기여: `main` 전체 HLS IP, 양자화, 최종 hybrid pipeline,
  실시간 PPE 및 97.8%/0.79 FPS 결과

## 저장소 개선점

1. `main` 루트 README가 최종 실행법과 구조를 충분히 설명하지 않는다.
2. `Add files via upload` 커밋이 많아 기여 추적이 어렵다.
3. `.bit/.xsa/.pt/.zip/.bin` 등 대형 산출물이 Git에 직접 들어 있다.
4. 과거 문서와 `model6_hw_fix` 사이에 CHW/HWC 및 HW cv2 포함 여부가 충돌한다.
   최종 기준을 `model6_hw_fix`로 명시해야 한다.
5. 팀 원본 Vivado `.bd/.xpr`는 없고 수정본 Tcl은 `.hwh`를 바탕으로
   재구성되었다고 README가 밝힌다.
6. 개인 브랜치도 작성자가 섞여 있어 branch name만으로 개인 기여를 단정할 수 없다.

## 발표용 문장

> 팀의 YOLOv8n PPE 파이프라인 중 저는 초기 3×3 Conv RTL 설계·검증과
> model.6 FPGA 통합/디버깅 과정에 참여했습니다. Codex에 모델 구조도,
> GitHub/로컬 소스, Vivado·Vitis 로그를 함께 분석시키고 제가 각 터미널에서
> 결과를 재검증하는 방식으로 개발했습니다. 팀 공동 최종본은 cv1~Concat을
> FPGA에서, cv2 이후를 CPU에서 처리하는 하이브리드 구조입니다.
