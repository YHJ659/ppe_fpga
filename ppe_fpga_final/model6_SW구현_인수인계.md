# model.6 하이브리드 파이프라인 — 소프트웨어 구현 인수인계

> 이 문서 하나로 소프트웨어(model.0~5, model.7~ + cv2)를 구현할 수 있도록
> 필요한 계약(입출력 형식)과 이미 만들어진 스켈레톤 코드 사용법만 정리했습니다.
> 하드웨어 설계·디버깅 과정은 여기 안 담았습니다 (필요하면 별도 문서 참고).

---

## 0. 전체 그림

```
[SW] model.0~5  →  hw_input.bin  →  [HW] model.6 (conv1x1_cv1~concat)  →  hw_output.bin  →  [SW] cv2 + model.7~
```

**중요한 변경**: 원래 model.6 전체(cv2 포함)를 하드웨어로 만들 계획이었으나,
자원 문제로 **cv2(conv1x1 256→128 + BN + SiLU)를 소프트웨어로 이전**했습니다.
그래서 하드웨어가 실제로 계산하는 건 **cv1 ~ concat까지**이고, cv2는 이제
당신이 구현할 소프트웨어 몫입니다.

---

## 1. 하드웨어 입출력 계약 (반드시 정확히 맞춰야 함)

### 입력

| 항목 | 값 |
|---|---|
| 형식 | int8, CHW, 128채널 × 40 × 40 |
| 파일 예시 | `hw_input.bin` (204,800 bytes) |
| 스케일 | `calib_out/calib_params.json` → `boundary.hw_in_scale` (= `S_in`) |
| 만드는 코드 | `sw_model0to5.py` (아래 2절) |

### 출력 — ★ 스케일이 바뀌었습니다

| 항목 | 값 |
|---|---|
| 형식 | int8, CHW, **256채널** × 40 × 40 (128채널 아님!) |
| 파일 예시 | `hw_output.bin` (409,600 bytes) |
| 스케일 | `calib_out/calib_params.json` → `activation_scale.S_cat` (**`boundary.hw_out_scale`가 아님** — 그 값은 cv2가 하드웨어에 있던 시절의 것으로, 지금은 무효) |

**왜 바뀌었나**: 하드웨어의 마지막 연산이 이제 `concat`이라, 그 출력(256채널,
`S_cat` 스케일)이 곧 하드웨어 출력입니다. cv2는 그 뒤에 소프트웨어에서
계산됩니다.

---

## 2. model.0~5 — 그대로 사용 (수정 불필요)

`sw_model0to5.py`를 그대로 쓰면 됩니다.

```bash
python3 sw_model0to5.py \
    --weights models/best.pt \
    --calib calib_out/calib_params.json \
    --image <입력 이미지> \
    --out hw_input.bin
```

내부적으로 model.5 출력을 캡처해 `S_in`으로 양자화합니다. 실시간 웹캠
버전으로 확장할 때는 이미지 파일 대신 프레임 배열을 받도록 `preprocess_frame()`
부분만 바꾸면 됩니다 (구조는 동일).

---

## 3. HW 실행 (당신이 아직 안 정한 부분)

`hw_input.bin`을 하드웨어에 넣고 `hw_output.bin`(256채널)을 받아오는 코드는
PL 프로그래밍 방식에 따라 달라집니다 — **PYNQ(Python)로 갈지, UIO+C로 갈지
아직 확정이 안 됐습니다.** 팀과 상의해서 정해주세요.

어느 쪽이든 부팅 시 한 번만 해줘야 하는 게 있습니다:

- **Auto Restart 비트 켜기** (재사용되는 IP 6개: conv3x3, bn_silu_64,
  residual_add, bn_silu_128, concat, bottleneck_router) — 안 하면 프레임마다
  당신이 직접 `ap_start`를 켜줘야 합니다
- **concat의 스케일 값 5개 write** (`scale0`~`scale3`, `output_scale` —
  `calib_out/calib_params.json`의 `activation_scale` 딕셔너리에서 값 확인.
  concat은 다른 IP들과 달리 `.coe`가 아니라 `s_axilite` 레지스터라 이렇게
  직접 써야 함)

이후 프레임마다 하는 일은 "`hw_input.bin` DMA로 보내기 → 완료 대기 →
`hw_output.bin`(256채널) DMA로 받기"뿐입니다.

---

## 4. cv2 + model.7~ — 새로 구현할 부분

### 4.1 권장 방법 — PyTorch 모델의 float cv2를 그대로 재사용

`conv1x1(cv2)+BN+SiLU`를 직접 재구현(가중치 추출, 양자화 등)할 필요
**없습니다.** `best.pt`를 로드하면 이미 `model.model[6].cv2` 안에 원래
float 가중치가 다 들어있으니, 그걸 그대로 쓰면 됩니다. 정확도도 이게 더
좋습니다(양자화 없는 float 연산).

방법은 `sw_model7up.py`에 이미 있는 **hook 치환 기법을 한 단계 앞으로
옮기는 것**입니다 — 원래는 `model.model[6]`(C2f 전체) 출력을 통째로
바꿔치기했는데, 이제는 **`model.model[6].cv2`의 입력**을 하드웨어 출력으로
바꿔치기합니다.

```python
def dequantize_hw_output(hw_output_bin, s_cat, shape=(1, 256, 40, 40)):
    """하드웨어에서 받은 256채널 int8 -> float"""
    raw = np.fromfile(hw_output_bin, dtype=np.int8).astype(np.float32)
    return torch.from_numpy(raw.reshape(shape)) * s_cat

def run_with_hw_output(model, x, hw_feat_float):
    """model.6.cv2의 입력을 HW 출력으로 바꿔치기하고 나머지는 그대로 실행"""
    def pre_hook(module, args):
        return (hw_feat_float,)   # cv2가 원래 받을 입력을 대체

    h = model.model.model[6].cv2.register_forward_pre_hook(pre_hook)
    with torch.no_grad():
        out = model.model(x)   # model.6.cv2 -> bn_silu_128(cv2측) -> model.7~ 전부 float로 자동 실행
    h.remove()
    return out
```

`model.model[6].cv2`부터는 **PyTorch가 그 뒤(bn_silu 포함, model.7~22까지)를
전부 원래 float 모델 그대로 실행**해줍니다 — skip connection도 신경 쓸
필요 없습니다. `sw_model7up.py`가 이미 이 hook 치환 방식을 쓰고 있으니,
그 파일의 `run()` 함수를 참고해서 hook 지점만 `model.model[6]`(output 대체)
에서 `model.model[6].cv2`(input 대체, `register_forward_pre_hook` 사용)로
바꾸면 됩니다.

### 4.2 필요한 파일

- `best.pt` — cv2의 float 가중치가 이미 들어있음 (별도 가중치 파일 불필요)
- `calib_out/calib_params.json`의 `activation_scale.S_cat` — 역양자화용
- `hw_output.bin` — 3절에서 받은 하드웨어 출력

### 4.3 검증 방법 (하드웨어 없이도 먼저 확인 가능)

`sw_model7up.py`의 `hw_emulate` 모드를 참고하면, 실제 HW 없이도 "HW가
있었다면 어떤 값이 나왔을지"를 미리 흉내낼 수 있습니다 — model.6을 float로
쭉 계산해두고, concat 출력만 `S_cat`으로 양자화→역양자화해서 4.1절 코드에
넣어보면 됩니다. 이걸로 로직이 맞는지 먼저 검증하고, 실제 `hw_output.bin`이
나오면 그걸로 바꿔 끼우면 됩니다.

---

## 5. 참고용 — 지금 갖고 있는 스크립트 정리

| 파일 | 역할 | 이번 변경 필요? |
|---|---|---|
| `sw_model0to5.py` | model.0~5, hw_input.bin 생성 | 아니오 |
| `sw_model7up.py` | model.6 출력 이후 처리 | **예 — 4.1절대로 hook 지점 수정** |
| `calibrate_model6.py` | 양자화 보정 (이미 실행 완료) | 아니오, `calib_out/`만 참고 |
| `calib_out/calib_params.json` | 전체 스케일 값 저장소 | 이 파일에서 `S_in`, `S_cat` 확인 |

---

## 6. 막히면 확인할 것

- **출력이 128채널이라고 착각하지 마세요** — 256채널입니다 (1절)
- **cv2 가중치를 따로 뽑을 필요 없습니다** — `best.pt`에 이미 있습니다 (4.1절)
- **`boundary.hw_out_scale`는 이제 안 씁니다** — `activation_scale.S_cat`을
  쓰세요 (1절)
