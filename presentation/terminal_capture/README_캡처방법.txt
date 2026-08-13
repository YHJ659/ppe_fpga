PPT 캡처용 실제 작업 기록
===========================

PC Ubuntu 터미널에서 아래 명령을 한 줄씩 실행하세요.

1) Vivado model.6 최종 성공 화면
   less -R /home/sogang/ppe_fpga_ho/artifacts/terminal_capture/01_vivado_model6_success.txt

2) Vitis/XSCT 빌드 및 KV260 다운로드 화면
   less -R /home/sogang/ppe_fpga_ho/artifacts/terminal_capture/02_vitis_xsct_board_run.txt

3) KV260 SSH, 웹캠 인식, PYNQ Overlay 화면
   less -R /home/sogang/ppe_fpga_ho/artifacts/terminal_capture/03_kv260_camera_overlay.txt

조작:
  아래로 이동: PageDown 또는 Space
  위로 이동: PageUp 또는 b
  종료: q
  터미널 전체 화면: F11

권장 캡처:
  슬라이드 3 또는 4: 01번의 WNS/DRC/Bitstream 성공 부분
  슬라이드 4: 02번의 ELF build + XSCT 다운로드 부분
  슬라이드 5: 03번의 Webcam C270 + MODEL6_BITSTREAM_LOADED 부분

주의:
  이 파일들은 실제 로그와 대화에 남은 출력의 핵심 부분을 캡처하기 좋게 재배열한 것이다.
  Vitis의 최종 UART DMA PASS와 model.6 MMIO 실행 완료는 확인되지 않았으므로 넣지 않았다.
