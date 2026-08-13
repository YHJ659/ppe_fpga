# 복원하지 못한 세션 및 추가 조사 위치

작성일: 2026-08-12

이 문서는 현재 로컬 저장소와 현재 Codex transcript만으로 확인하지 못한 내용을 기록한다. 확인되지 않은 내용을 수행 사실로 취급하지 않는다.

## 1. 다른 Codex 세션 transcript

상태: **확인 필요**

현재 대화에 보이는 transcript는 KV260 접속, 카메라, Jupyter/PYNQ 오류 및 일부 최종 Vivado 출력은 포함하지만, 2026-07-28 이후의 모든 별도 Codex 대화를 포함한다고 보장할 수 없다.

추가 조사 방법:

- 과거 Codex 대화 export 또는 transcript를 별도로 제공
- 특히 full model.6 implementation, BN HLS 변형 실험, SGP1 Vivado Tcl Console 대화가 포함된 세션 확인

문서 표기: `다른 Codex 세션 transcript 확인 필요`

## 2. SGP1 `/DATA` 프로젝트

상태: **SGP1 조사 미완료**

대상:

```text
/DATA/home/edu004/workspace/ppe_fpga_ho
```

현재 PC에는 `/DATA`가 없다. 이미 저장된 인증만 사용하는 비대화형 read-only SSH를 시도했지만 `Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password)`로 거부됐다. 비밀번호 입력을 요청하거나 인증을 우회하지 않았다.

추가 조사 후보:

- `ppe_model6_team_latest`
- `vivado.jou`, `vivado.log`, `*.backup.jou`, `*.backup.log`
- `vivado.runs/*/runme.log`
- `reports/vivado`
- `artifacts/model6_icuf8_20260809`
- HLS experiment directories와 `vitis_hls.log`
- edu004 계정의 프로젝트 관련 `.bash_history`(접근 권한이 있을 때만)

이 경로에 있을 가능성이 있으나 현재 확인하지 못한 주장:

- `66,590 node overlaps`
- WNS `-9.210 ns`
- `Failed Timing & Nets`
- `Router completed with failures`
- `LUTLP-1`
- full model.6의 최종 `BLACKBOX_COUNT`
- BN64/BN128의 OOC synthesis 및 최종 적용 Tcl

## 3. Vitis HLS interactive console

상태: **복원 불가/추가 로그 필요**

로컬 `vitis_hls.log`에는 도구 banner만 있고 interactive 명령이 없다. shell history에는 `vitis_hls` 실행과 소스/export 조사만 있다.

찾지 못한 명령과 결과:

- `open_project`, `set_top`, `open_solution`
- `csim_design`, `csynth_design`, `cosim_design`, `export_design`
- `off_stp`, `in_reverse_stp`
- `register_mode off/reverse/forward/both`
- `PIPELINE II=1`, `style=stp`
- ARRAY_PARTITION/UNROLL 비교 실험
- BN64/BN128의 LUT/FF/DSP/BRAM, latency, II, estimated clock, max fanout 원문
- `csim TEST PASSED`, synthesis 0 errors, export.zip 생성 콘솔 출력

추가 조사 위치:

```text
SGP1 HLS project/vitis_hls.log
solution*/syn/report/*_csynth.rpt
solution*/csim/report 및 build logs
solution*/impl/ip/component.xml
```

## 4. Jupyter 원본 기록

상태: **현재 transcript로 일부만 복원**

로컬 저장소에서는 대상 `.ipynb`, `.ipynb_checkpoints`, IPython `history.sqlite`를 찾지 못했다. 현재 transcript에 사용자가 붙여넣은 코드/출력을 8개 논리 셀 그룹으로 복원했다.

추가 조사 위치(KV260 `.253`에 접근 가능할 때 read-only):

```text
/home/ubuntu/**/*.ipynb
/home/ubuntu/**/.ipynb_checkpoints
/home/ubuntu/.ipython/profile_default/history.sqlite
Jupyter runtime/kernel logs
```

미확인:

- 실제 notebook filename과 cell execution number
- `[*]` hang의 kernel stack trace
- `dma_mmio.read(0x00)`가 멈춘 정확한 AXI/driver 원인
- `sudo pkill -f ipykernel_launcher` 실제 실행 여부

## 5. Vitis/XSCT DMA 실행 결과

상태: **build/program 확인, 기능 결과 확인 필요**

확인된 것:

- 최초 `dma_loopback` build는 `xparameters.h` 누락으로 실패
- `dma_loopback_v2` build 성공
- FPGA bit, XSA, FSBL, application ELF download와 `con` 성공

확인하지 못한 것:

- UART의 `STEP1`, `STEP2`, `STEP3`, `STEP 3A` 실제 출력
- MM2S/S2MM register dump
- `XAxiDma` runtime return code
- 최종 PASS/FAIL 문자열
- DMA base `0xA0000000`을 사용한 별도 실험의 정확한 실행 출력

source에 STEP 문자열이 존재하는 것과 보드에서 실제 출력된 것은 구분해야 한다.

## 6. 실시간 YOLO 실행

상태: **최종 실행 미확인**

확인된 것:

- KV260 `.253`에 Logitech C270과 `/dev/video0`, `/dev/video1` 존재
- Python OpenCV 4.11.0 존재
- 당시 `torch`, `ultralytics`, `onnxruntime` 미설치 출력
- 다른 보드 `.56`에는 과거 YOLO/PYNQ-DPU 파일이 있었지만 카메라가 인식되지 않음
- model.6 bitstream의 Jupyter download 성공

확인하지 못한 것:

- `.253`에서 최종 모델/ONNX/NCNN runtime 파일 전송 완료
- dependency 설치 완료
- `MixedPipelinedPipeline` 실제 실행
- webcam detection 창, bounding boxes, FPS
- PRE/FPGA overlap의 실측 결과

따라서 “실시간 YOLO가 구동됐다”는 개인 수행 결과로 아직 기록할 수 없다.

## 7. 날짜 복원 한계

`/home/sogang/.bash_history`에는 timestamp가 저장돼 있지 않다. 파일 mtime은 2026-08-12이지만 각 명령의 실행 날짜로 사용할 수 없다.

정확한 날짜가 있는 근거:

- Vivado journal session: 2026-07-31
- Vitis build/Run metadata: 2026-07-31
- 현재 transcript와 생성 문서 기준일: 2026-08-12

그 사이 shell 명령은 맥락 순서는 복원 가능하지만 날짜는 `날짜 확인 불가`로 유지한다.

## 8. 추가 조사 시 안전 원칙

- 기존 source, project, reports, artifacts를 수정하거나 덮어쓰지 않는다.
- synthesis, implementation, route, bitstream, HLS synthesis를 재실행하지 않는다.
- read-only `find`, `rg`, `sed`, `sha256sum`, journal/report 열람만 수행한다.
- SSH 인증이 없다면 비밀번호 요청이나 우회를 하지 않는다.
- 인증정보와 개인 명령은 문서화하지 않는다.

