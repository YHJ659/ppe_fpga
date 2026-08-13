# 자기소개서·면접 소재 TOP 7

선정 원칙: 개인 수행 A/B/C 우선, 시행착오와 판단 근거, before/after, 직무 연결성. 팀 E 사례는 개인 기여 확인 전 보조 소재로만 사용한다.

## TOP 1 — DMA 최소설계 Validate 실패부터 Bitstream까지

- 가장 강한 문항: 실패를 극복한 경험 / 분석적 문제해결 / FPGA 전문성
- 핵심 난제: clock/reset/address 누락과 Tcl 입력 오류가 겹쳐 BD validation 실패
- 내가 한 행동: 실제 pin/net/address를 조회하고 누락 연결→address assign→blackbox→route→timing 순으로 검증
- 실패 과정: 줄바꿈 pin 오류, 잘못된 `get_bd_pins` command, 1-pin net 연결, 초기 Validate 실패
- 정량 결과: failed/unrouted/partial/overlap 0, WNS +5.904 ns, WHS +0.010 ns, bitstream 성공
- 한 줄 메시지: **“오류를 추측으로 고치지 않고 설계 객체와 report를 단계별로 확인해 최소 DMA 시스템을 끝까지 완성했다.”**
- 예상 면접 질문: address assignment 원리, setup/hold 차이, initial failed nets와 final route 차이, blackbox 확인 이유
- 증거/신뢰도: 개인 A

## TOP 2 — Bitstream 성공 뒤 MMIO hang을 발견한 board bring-up

- 문항: 예상하지 못한 문제 / 끈기 / CS·FSE 직무
- 난제: bitstream과 Overlay는 성공했지만 DMA register read에서 kernel hang
- 행동: HWH parse, IP dictionary/base/register 확인, DMA object와 MMIO 비교, kernel restart, PYNQ/XRT 환경 분리
- 실패: `dma_mmio.read(0x00)`가 `[*]`; 최종 transfer 미해결
- 결과: build 성공과 runtime 성공의 경계를 명확히 하고 재현 조건을 남김
- 메시지: **“설치 완료를 기능 검증으로 착각하지 않고 실제 I/O 경계에서 실패를 재현해 원인 범위를 좁혔다.”**
- 면접 질문: MMIO read가 hang할 수 있는 원인, 다음 진단 순서, 왜 직접 원인을 단정하지 않았는가
- 증거/신뢰도: 개인 C

## TOP 3 — Synthesis의 양수 WNS 뒤 숨은 Hold violation 판독

- 문항: 분석적 문제해결 / 예상 못한 이슈
- 난제: setup WNS +7.270 ns인데 `Timing constraints are not met`
- 행동: WHS/THS/endpoints, routed report, blackbox를 분리 확인
- 실패: 대표 WNS만 보면 성공으로 오판할 수 있었음
- 결과: synthesis WHS -0.082 ns, 10,326 endpoints → routed WHS +0.010 ns, THS 0
- 메시지: **“대표 수치 하나가 아니라 측정 단계와 violation 종류를 분리해 정확한 합격 기준을 세웠다.”**
- 면접 질문: synthesis와 implementation timing 차이, hold fix 방식, report 신뢰성
- 증거/신뢰도: 개인 A

## TOP 4 — Vitis BSP build 실패에서 hardware download까지

- 문항: 실패 극복 / HW-SW integration
- 난제: `xparameters.h` 누락으로 첫 DMA application build 실패
- 행동: platform/application v2 재구성, build, FPGA/XSA/FSBL/application 순서 확인
- 결과: ELF 75,228 bytes, XCK26 program/download 성공; UART PASS는 확인 필요
- 메시지: **“소스 문법이 아니라 hardware platform–BSP 의존성을 원인으로 보고 실행 체인을 복구했다.”**
- 면접 질문: xparameters 생성 주체, FSBL 역할, XSA와 BSP 관계
- 증거/신뢰도: 개인 A(다운로드까지)

## TOP 5 — 여러 KV260 중 올바른 장비 식별

- 문항: 현장 문제해결 / FSE·CS / 끈기
- 난제: `.56`과 `.253` 보드 혼동으로 webcam·artifact 상태 모순
- 행동: ping/neigh→ARP scan→MAC→hostname/IP→USB ID→video node→9090 순으로 확인
- 결과: `.253`, Logitech C270 `046d:0825`, `/dev/video0/1` 확정
- 메시지: **“IP 주소를 가정하지 않고 독립적인 장비 지표를 교차검증해 올바른 대상 장비를 찾아냈다.”**
- 면접 질문: 동일 LAN 장비 식별, DHCP 환경, 재발 방지
- 증거/신뢰도: 개인 C

## TOP 6 — 팀 IP repository/interface 통합

- 문항: 협업·조율 / 책임감 / FPGA 전문성
- 난제: 여러 팀원이 만든 source/export ZIP의 interface와 version을 맞춰야 함
- 행동: find/unzip/component.xml/VLNV/포트/sha256 확인, cv1/cv2 별도 IP 구분, SGP1 repo 전달, Vivado 통합
- 실패: placeholder 경로·명령 오타, source 없는 export와 경로 혼동
- 결과: custom BD `ip_dict`에 핵심 IP들이 노출되고 full bitstream 생성
- 메시지: **“팀 산출물을 이름으로 신뢰하지 않고 interface metadata와 hash를 기준으로 통합했다.”**
- 면접 질문: AXIS/AXI-Lite/BRAM 차이, VLNV, version 관리, 본인 수정 범위
- 증거/신뢰도: 개인 B/C + 팀 IP 구현

## TOP 7 — 팀 HW/SW partition 및 end-to-end 병목 재평가

- 문항: 창의적 해결 / 제한 자원 trade-off / 시스템 관점
- 난제: cv2 포함과 IP 복제로 placement/resource 부담, model.6만 가속해도 FPS 개선 미미
- 팀 행동: 1개 IP 순차 재사용+router, cv2를 SW로 이동, stage profiling, ORT/NCNN 및 PRE/FPGA overlap 검토
- 결과: final fix4 LUT 59.3%, FF 57.7%, BRAM 86.5%, URAM 93.8%, DSP 38.1%, WNS +0.462 ns; model.6 0.077→0.055 s지만 전체 약 0.79 FPS
- 메시지: **“단품 가속보다 route 가능성과 전체 병목을 기준으로 HW/SW 경계를 재설계했다.”**
- 면접 질문: 왜 cv2를 SW로 보냈는가, Amdahl law, 다음 가속 블록, router 비용
- 증거/신뢰도: 팀 E. **개인 의사결정 기여 확인 전 단독 자소서 사용 금지**

## 추천 사용 조합

- FPGA/RTL 직무: TOP 1 + TOP 3 + TOP 6
- 반도체 장비 CS/FSE: TOP 2 + TOP 5 + TOP 4
- 시스템/가속기 직무: TOP 1 + TOP 2 + TOP 7(팀 기여를 명시)
- 실패극복 문항: TOP 1
- 예상 밖 문제 문항: TOP 2 또는 TOP 3
- 협업 문항: TOP 6

