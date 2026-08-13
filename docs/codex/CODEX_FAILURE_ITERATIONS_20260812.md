# 실패 → 재시도 → 수정 → 결과 시간순 기록

## 2026-07-31 — 개인 직접 수행: DMA 최소 Vivado 설계

1. `axis_passthrough_0/`와 `output_stream`을 줄바꿈 입력
   → pin 미검출, `invalid command name "output_stream"`
   → 올바른 전체 interface pin 이름으로 재입력.
2. `connect_bd_net`에 pin 하나만 전달, `get_bd_pinszynq...` 오타
   → 연결 오류/invalid command
   → `set clk_src [get_bd_pins ...]`, `set clk_dst ...`, net 조회 방식으로 수정.
3. `validate_bd_design`
   → DMA address 미할당, MM2S/SmartConnect clock 오류
   → clock 연결, `assign_bd_address`, address space/segment 확인
   → Validate 진행.
4. Synthesis 완료
   → WNS +7.270만 보면 정상처럼 보였으나 WHS -0.082, 10,326 hold endpoints로 timing fail
   → Implementation routed timing을 별도 확인
   → WNS +5.904, WHS +0.010, TNS/THS 0.
5. 계층 synthesis에서 7 blackbox 표기
   → 최종 design `IS_BLACKBOX==1` 재조회
   → 0.
6. route initialization
   → failed nets 9,183(8,206 unrouted/977 partial), overlap 0
   → route finalize
   → 모두 0.
7. `write_bitstream`
   → 0 Critical Warnings/0 Errors, completed successfully.
8. XSCT용 `targets`를 Vivado Console에 입력
   → `invalid command name "targets"`
   → console 역할을 구분해야 함을 확인.

## 2026-07-31 — 개인 직접 수행: Vitis DMA application

1. `dma_loopback` Debug build
   → `xparameters.h: No such file or directory`
   → platform/BSP 정합을 의심.
2. `dma_loopback_v2`/platform v2 build
   → 성공, ELF total 75,228 bytes.
3. Run/Debugger
   → connect/target/fpga/XSA/FSBL/application download 성공.
4. UART PASS
   → 원본 출력 없음
   → 기능 성공은 [확인 필요]로 유지.

## 날짜 확인 불가 — 개인 직접 수행: 팀 IP 조사·전달

1. placeholder `[residual_add 파일 경로]` 등을 그대로 shell에 입력
   → 잘못된 경로
   → `find`로 실제 절대경로 확인 후 수정.
2. `vitis hls`
   → 잘못된 실행 이름
   → `vitis_hls`로 수정.
3. SCP destination colon 누락/SGP1 hostname resolve 실패
   → push/pull 방향과 절대 destination을 수정.
4. export ZIP/source/component.xml을 비교
   → cv1/cv2와 IP interface가 서로 다름을 구분
   → repo_v2와 full BD 통합으로 진행.

## 2026-08-06~09 — custom full model.6 build

1. 과거 route 실패 과정의 `66,590 overlaps`, `-9.210 ns`, LUTLP-1 및 BN HLS 변형
   → 로컬 원본 없음
   → **[확인 필요: SGP1/다른 Codex 세션]**.
2. 최종 build
   → WNS +0.220, WHS +0.010, failed/unrouted/partial/overlap 0, DRC error 0.
3. bitstream/XSA export
   → bit 7,797,812 B, HWH 1,080,620 B, XSA 6,603,783 B, XSA return 0.

## 2026-08-09 — 개인 직접 수행: KV260 custom overlay

1. `.56` 보드에 bit/hwh 전송 및 hash 확인
   → Overlay parse/download 성공.
2. `overlay.model6_dma` 접근
   → Jupyter `[*]` hang.
3. 새 kernel에서 `MMIO(0xA00A0000,0x10000).read(0)`
   → 다시 `[*]` hang.
4. kernel interrupt/restart
   → Notebook UI는 복구, MMIO 값은 미확인.
5. 결론
   → bitstream 성공/Overlay loaded와 DMA runtime 성공을 분리. 원인은 미해결.

## 2026-08-09 — 개인 직접 수행: PYNQ-DPU 환경

1. 일반 사용자 PYNQ
   → root permission required.
2. sudo system Python
   → `pynq_dpu` module missing.
3. sudo PYNQ venv
   → 한 시도에서 No Devices Found.
4. `sudo -E` PYNQ venv
   → EmbeddedDevice 1개 확인.
5. DpuOverlay
   → 임시 `t.xclbin` FileNotFoundError.
6. `/usr/bin/xclbinutil` 우선 PATH
   → 문제 지속.
7. 결론
   → 권한/venv/device 단계는 좁혔지만 DPU load 미해결.

## 2026-08-09 이후 — 개인 직접 수행: 보드·카메라 식별

1. `.56` ping/SSH 실패, webcam 없음
   → 고정 IP 가정이 틀렸음을 의심.
2. ARP scan으로 Xilinx 장치 다수 확인
   → `.253` 선택.
3. hostname/IP/USB/video/service 교차검증
   → `kria`, `192.168.1.253`, C270 `046d:0825`, `/dev/video0/1`, Jupyter 9090 확인.

## 팀 저장소 iteration — 개인 기여 [확인 필요]

### Router

순차 producer/consumer, C simulation 정상
→ 보드에서 82 pixel 반복 정지
→ IP를 구간별 활성화해 router로 범위 축소
→ DATAFLOW rewrite
→ 1,600 pixel.

### Parameter BRAM 및 반복 frame

단일 데이터 불일치
→ weight는 정상인데 float parameter만 비정상
→ byte/word address 단위 발견
→ depth×4 + COE stride4
→ 첫 frame 개선
→ 둘째 frame stale slot 발견
→ slot1=slot0 duplicate
→ 12 frame 연속 검증.

### DMA

output 409,600 B vs width14 최대16,383 B
→ split receive 시 DMAIntErr
→ width26
→ full receive
→ driver length probe가 transfer 시작하는 부작용
→ fixed constant+IOC
→ wait 10.0s→0.05s.

### HW/SW partition

model.6 전체/cv2 포함 및 IP 복제 검토
→ resource/placement 부담
→ conv/bn/residual 1개 재사용+router, cv2 SW 이동
→ final fix4 timing/resource 통과
→ end-to-end profiling에서 model.6 비중 6.5% 확인
→ ORT PRE/NCNN POST와 PRE/FPGA overlap 검토.

