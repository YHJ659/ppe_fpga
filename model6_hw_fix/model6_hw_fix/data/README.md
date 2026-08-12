# 검증에 쓴 실측 데이터

`results/verification.md` 의 수치가 전부 이 파일들에서 나옵니다.
보드 없이 혼자 재현할 수 있습니다.

## 파일

| 파일 | 크기 | 내용 |
|---|---|---|
| `hw_input_hwc.bin` | 204,800 B | model.5 출력을 양자화한 HW 입력 |
| `hw_output_full.bin` | 409,600 B | 그 입력으로 보드가 실제로 낸 출력 |
| `multi/in0~5.bin` | 각 204,800 B | 이미지 6장의 HW 입력 |
| `multi/out0~11.bin` | 각 409,600 B | 12프레임 연속 시험 결과 (0~5 = 1바퀴, 6~11 = 2바퀴) |
| `multi/images.json` | | 어느 이미지였는지 |

`hw_output_full.bin` 을 만든 비트스트림은 `hw/ppe_fpga_yoo_fix4.bit`
(md5 `f9a1ed9865c139ec3d31abc67fde68ed`) 입니다.

## 배열 규약 — 여기서 대부분 어긋납니다

**픽셀 우선(HWC)** 입니다.

```python
inp = np.fromfile("hw_input_hwc.bin",  np.int8).reshape(40, 40, 128)   # [h][w][c]
out = np.fromfile("hw_output_full.bin", np.int8).reshape(40, 40, 256)   # [h][w][c]

# CHW 로 쓰려면 전치
out_chw = out.transpose(2, 0, 1)      # [c][h][w]
```

AXI-Stream 한 beat 이 한 픽셀의 전 채널이고 DMA 가 그 순서로 씁니다.
`conv1x1_cv1/tb_conv1x1_stream.cpp` 가 이 규약을 못박고 있습니다.

```cpp
for (h) for (w) { for (c) px.ch[c] = in[c][h][w]; in_s.write(px); }
```

**인수인계 문서의 "CHW" 는 오류입니다.** 그대로 `reshape(256,40,40)` 하면
값은 전부 맞는데 자리가 뒤섞여 일치율이 3~5% 로 떨어집니다.

## 스스로 확인하기

```bash
python3 sw/verify_boundary.py                  # 맞는 방식
python3 sw/verify_boundary.py --wrong-layout   # 일부러 CHW 로
```

`models/best.pt` 와 `calib_out/calib_params.json` 이 있어야 합니다.

기대 출력:

```
HWC 로 읽음    일치 100.00%    불일치      0 / 204,800    상관 1.000
CHW 로 읽음    일치   4.88%    불일치 194,796            상관 0.002
```

이 두 줄이 그대로 나오면 환경이 맞는 것입니다.
