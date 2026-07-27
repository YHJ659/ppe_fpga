# model.6 확인 요청 2건

작성일: 2026-07-27
대상: `model.6` C2f HLS 산출물
목적: 통합(모듈 연결) 검증 전, 아래 2건만 확인 부탁드립니다.

---

## 1) cv2 (256→128) 어떻게 처리하는지

- `Concat/concat_channel.cpp` → `OUT_CH 256`
- `conv1x1/conv1x1.cpp` → `IN_CH 128` 고정

cv1은 맞는데 cv2가 안 맞습니다.
그리고 `conv1x1.cpp:45`가 `output[oc][oh][ow] = sum;` (덮어쓰기)이라
128채널씩 2패스로 부분합을 누산하는 방식도 현재 코드로는 불가능합니다.

아래 중 어느 쪽인지만 알려주세요.

- (a) `IN_CH=256` 별도 인스턴스
- (b) 누산 입력 추가해서 2패스
- (c) 이미 처리했는데 커밋이 안 된 것

---

## 2) Concat tb의 `Y1_SCALE` 값

`Concat/tb_concat_channel.cpp:13` → `Y1_SCALE = 0.0317828`

저장된 `.bin`으로 직접 대조한 결과입니다.

| 비교 | 결과 |
|---|---|
| `split_cv1/golden_y0` vs `concat_c2f6/y0.bin` | 완전 일치 |
| `split_cv1/golden_y1` vs `concat_c2f6/y1.bin` | **불일치, 평균 비율 1.495** |
| `Y0_SCALE / Y1_SCALE` | 1.497 |

정확히 scale 비만큼 어긋납니다.

원인은 두 골든 스크립트의 양자화 방식이 다르기 때문입니다.

- `Split/split_channel_golden_reference.py` : 128채널 텐서 **하나**를 단일 scale(0.047591)로 양자화한 뒤 자름 → y0, y1이 같은 scale
- `Concat/concat_golden_reference.py` : y0, y1을 **각각 따로** 양자화 → 서로 다른 scale

추가로, `concat_c2f6/golden_output.bin`의 채널 64:128 구간은
`split_cv1/golden_y1`과 **비트 단위로 완전히 동일**합니다.
즉 연결 시 올바른 동작은 y1 pass-through입니다.

### 결론

모듈 자체는 정상입니다. `concat_channel.cpp`의 scale은 s_axilite 런타임 인자라
RTL 수정이 필요 없습니다. **tb 상수와 골든 생성 스크립트만 맞추면 됩니다.**

연결 테스트에서는 `scale1 = 0.047591` (= Split 입력 scale)로 넣어야 합니다.

---

## 3) 같이 주셨으면 하는 것

- `csynth.rpt`, `cosim.rpt`
- HLS 프로젝트 재생성 Tcl (또는 실행 절차)
- 레이어별 입력/출력 scale 표

특히 `concat_channel.cpp`가 픽셀당 float 나눗셈 4회(`v / output_scale`)를
`II=1`로 돌리고 있는데, 실제 II가 달성됐는지 리포트로 확인하고 싶습니다.

---

## 참고: 검증 완료된 부분

골든 데이터 생성 자체는 잘 되어 있습니다. 독립 재계산 결과입니다.

| 대상 | 결과 |
|---|---|
| Conv3×3 | 102,400 / 102,400 exact |
| Conv1×1 | 204,800 / 204,800 exact |
| Split y0/y1 | 204,800 / 204,800 exact |
| BN+SiLU 64 | 102,399 exact (1개 ±1) |
| BN+SiLU 128 | 204,800 / 204,800 exact |

위 2건은 **모듈 단위가 아니라 모듈을 이어 붙일 때만** 드러나는 문제입니다.
그래서 개별 테스트는 전부 통과한 상태가 맞습니다.
