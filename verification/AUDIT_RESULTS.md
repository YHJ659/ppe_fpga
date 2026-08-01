# 실행 결과

실행일: 2026-08-01  
환경: macOS, `g++` C++17, Icarus Verilog 13.0 임시 설치본

## 전체 runner

명령:

```bash
./verification/run_all.sh
```

종료 코드: `0`  
의미: 실행 가능한 정상 계약 regression이 끝까지 수행됐다는 뜻입니다. 다섯 브랜치 전체 sign-off라는 뜻은 아닙니다.

## 성기호

| 테스트 | 결과 |
|---|---|
| 새 window scoreboard, IMG_SIZE=8, 2 frames/bubbles | PASS, 72 windows |
| 새 MAC scoreboard | PASS, 6 directed transactions |
| 새 controller legal contract | PASS, reads 64/writes 36 |
| 원본 conv_top | PASS, 108/108 |
| 새 window scoreboard, IMG_SIZE=7, no reset between frames | **KNOWN DEFECT 재현**, second-frame data mismatch |
| 새 controller 37th-valid probe | **KNOWN DEFECT 재현**, output address 36 |

## 유현준

| 테스트 | 결과 |
|---|---|
| conv3x3 | PASS exact |
| conv1x1 | PASS exact |
| BN+SiLU 64 | PASS ±1 |
| BN+SiLU 128 | PASS ±1 |
| split | PASS exact |
| residual_add | PASS ±1 |
| concat | PASS ±1 |
| 10개 binary byte-size contract | PASS |
| split.y0 → concat.y0 | PASS bit-exact |
| split.y1 → concat.y1 | **BLOCKED**, exact 8,260/102,400, max diff 42 |
| concat 256ch → final conv | **BLOCKED**, 256→128 kernel 없음 |

## 오상헌

| 테스트 | 결과 |
|---|---|
| 새 MAC strict TB | PASS, accumulator/wrap/requantization/done |
| 새 control strict TB | PASS, exact latency/done/reset/busy-start |
| comparator bipartite counterexample | **KNOWN DEFECT 재현**, 1 match/1 missing/1 unexpected |
| comparator class-map counterexample | **KNOWN DEFECT 재현**, `helmet→no_helmet` false PASS |

## 실행 보류

- 김완민: 핵심 datapath와 인터페이스가 placeholder여서 기능 TB 없음
- 박정원: 하드웨어 DUT가 아니고 `models/best.pt`가 없어 webcam 정확도 test 없음

## 도구 한계

- 유현준 테스트는 host shim C-sim입니다. Xilinx `ap_int`, `hls::exp`, export RTL과 cycle 정확성을 증명하지 않습니다.
- 성기호 canonical sign-off에는 Vivado XSIM 2022.2와 실제 합성/구현 재현이 필요합니다.
- 알려진 결함 probe는 결함이 재현될 때 simulator non-zero를 내지만 wrapper가 이를 별도 분류해 다음 regression을 계속합니다.
