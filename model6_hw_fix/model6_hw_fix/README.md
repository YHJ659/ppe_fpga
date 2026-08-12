# model.6 FPGA 검증 — 수정본 일습

YOLOv8n PPE 검출을 **SW(model.0\~5) + HW(model.6) + SW(cv2 + model.7\~22)** 로 나눠
KV260(XCK26)에서 돌린 결과와, 그렇게 되기까지 고친 것들을 모았습니다.

**결론부터.** model.6이 FPGA에서 돌고 소프트웨어 단독과 **같은 검출**을 냅니다.
경계 텐서 y0/y1은 1600픽셀 204,800바이트 중 **불일치 0**.
보드 카메라로 실시간 동작(0.77 fps)까지 확인했습니다.

한 장짜리 보고서: [`docs/model6_수정보고서.pdf`](docs/model6_수정보고서.pdf)
검증 수치 전문: [`results/verification.md`](results/verification.md)
성능이 왜 이런지: [`docs/성능_분석.md`](docs/성능_분석.md)

---

## 폴더

```
hw/
  build_fix2.tcl              Vivado BD 를 처음부터 세우는 스크립트 (수정 반영)
  design_1_bd.tcl             위 스크립트가 만든 BD 를 export 한 것
  coe_stride4.py              파라미터 .coe 를 4칸 간격으로 재배치
  coe_addr4/                  그렇게 만든 .coe 15개 (바로 쓸 수 있음)
  ppe_fpga_yoo_fix4.bit       완성된 비트스트림
  ppe_fpga_yoo_fix4.xsa       같은 빌드의 하드웨어 플랫폼
  ppe_fpga_yoo_fix4.hwh       .xsa 에서 꺼낸 것 (편의용)
  CHECKSUMS.md5               셋의 md5
data/
  hw_input_hwc.bin            검증에 쓴 실측 입력  (204,800 B)
  hw_output_full.bin          보드가 낸 실측 출력  (409,600 B)
  multi/                      12프레임 연속 시험의 입출력
  README.md                   배열 규약과 기대 수치
sw/
  verify_boundary.py          위 데이터로 검증 수치를 혼자 재현 (보드 불필요)
  run_model6.py               한 프레임 전송 + 검증용
  run_multi.py                비트스트림 1회 로드로 여러 프레임 연속
  ppe_live.py                 카메라 실시간 (MJPEG 서버)
  sw_model0to5.py             model.0~5 -> HW 입력 생성
  sw_model7up.py              HW 출력 -> model.7~22 검증
  check_xsa.py                .xsa 의 미연결/주소 누락 점검
  layers.py                   레이어별 소요 시간 측정
  bench.py                    CPU 실효 처리량 측정
docs/    보고서
results/ 검증 수치
```

### 파일 이름에 대해

`build_fix2.tcl` 은 출력을 늘 **`ppe_fpga_yoo_fix2.*`** 로 씁니다. 같은 스크립트를
여러 번 돌렸기 때문에, 어느 빌드인지 구분하려고 여기서는 **`fix4`** 로 이름만 바꿔
담았습니다. `fix4` = 이 스크립트의 4번째 빌드이고, `.bit` / `.xsa` / `.hwh` 는
**전부 같은 한 번의 빌드**에서 나온 것입니다.

```
.xsa 안에 들어 있는 .bit  = f9a1ed9865c139ec3d31abc67fde68ed
같이 올린 .bit           = f9a1ed9865c139ec3d31abc67fde68ed   (동일 확인)
```

`ppe_fpga_yoo_3.xsa` 같은 이름은 **존재한 적 없습니다.**

### .hwh 가 없어도 실행은 됩니다

여기 스크립트들은 `.hwh` 를 읽지 않습니다.

```python
from pynq import Bitstream
Bitstream(bitfile).download()      # PL 만 굽는다
```

`.hwh` 가 필요한 것은 PYNQ `Overlay()` 입니다. 그건 주소 맵을 파싱해 IP 객체를
만들어 주는데, 여기서는 주소를 상수로 두고 raw MMIO 로 접근하므로 쓰지 않습니다.
(`Overlay()` 를 쓰면 오히려 `.xclbin` 을 찾다가 실패합니다.)
`.xsa` / `.hwh` 는 주소 맵 확인과 재빌드를 위해 넣어 둔 것입니다.

**따로 준비해야 하는 것** — 용량과 소유 문제로 넣지 않았습니다.

| 경로 | 내용 |
|---|---|
| `models/best.pt` | 학습된 가중치 |
| `calib_out/calib_params.json` | 캘리브레이션 결과 |

---

## 보드에서 돌리기

```bash
# 보드 (Ubuntu, PYNQ venv)
sudo /usr/local/share/pynq-venv/bin/python3 -m pip install \
     torch==2.5.1 torchvision==0.20.1
sudo /usr/local/share/pynq-venv/bin/python3 -m pip install --no-deps \
     ultralytics==8.0.43 thop
sudo /usr/local/share/pynq-venv/bin/python3 -m pip install \
     numpy==1.26.4 pandas matplotlib tqdm requests pyyaml scipy seaborn psutil
```

`numpy` 를 1.26.4 로 고정하고 `ultralytics` 를 `--no-deps` 로 넣는 이유는
**PYNQ 가 쓰는 numpy 와 cv2 를 건드리지 않기 위해서**입니다. 그냥 설치하면
opencv-python 이 덮어써서 PYNQ 쪽이 흔들릴 수 있습니다.

```bash
# 한 프레임 검증
python3 run_model6.py --bitfile hw/ppe_fpga_yoo_fix4.bit \
                      --input hw_input_hwc.bin --output out.bin

# 여러 프레임 연속 (비트스트림 1회 로드)
python3 run_multi.py --indir multi --repeat 2

# 카메라 실시간 -> http://<보드>:8090/
python3 ppe_live.py --camera 0 --port 8090

# 이미지 한 장 + 단계별 시간
python3 ppe_live.py --image test.jpg --repeat 3
```

`/dev/mem` 을 열어야 해서 root 권한이 필요합니다.

---

## 경계 규약 (중요)

DMA 와 HLS 사이의 배열 순서입니다. **픽셀 우선(HWC)** 입니다.

| | 모양 | 크기 |
|---|---|---|
| 입력 | int8 `[40][40][128]` | 204,800 B |
| 출력 | int8 `[40][40][256]` | 409,600 B |

AXI-Stream 한 beat 이 한 픽셀의 전 채널이고 DMA 가 그 순서로 씁니다.
`conv1x1_cv1/tb_conv1x1_stream.cpp` 가 이 규약을 못박고 있습니다.

```cpp
for (h) for (w) { for (c) px.ch[c] = in[c][h][w]; in_s.write(px); }
```

기존 인수인계 문서의 **"CHW" 는 오류**입니다. CHW 로 읽으면 값은 다 맞는데
자리가 뒤섞여 검출이 무너집니다(실측: 일치율 62.9% → 3.5%, 검출 4건 → 2건).

**직접 확인해 보세요.** 같은 파일을 두 방식으로 읽어 비교합니다.

```bash
python3 sw/verify_boundary.py                  # HWC — 일치 100.00%, 불일치 0
python3 sw/verify_boundary.py --wrong-layout   # CHW — 일치   4.88%
```

---

## 고친 것

| 대상 | 무엇이 잘못됐나 | 어떻게 고쳤나 |
|---|---|---|
| **파라미터 BRAM** | HLS 는 **바이트 주소**를 내보내는데 blk_mem_gen 은 **워드 주소**로 읽는다. float(4B)이라 채널 `c` 가 `4c` 번 칸을 읽고, 주소선 8비트라 256에서 되감긴다 | 32비트 메모리 깊이를 4배로, `.coe` 값을 0·4·8… 칸에 배치 |
| **bn128 슬롯1** | `call_counter` 가 `static` 인데 cv2 가 삭제돼 프레임당 1회만 불린다 → **2프레임째에 cv2 값**을 읽는다 | 슬롯1 을 슬롯0(cv1) 값으로 덮음 |
| **DMA 길이** | `c_sg_length_width` 기본 14 → 16,383 B. 출력은 409,600 B. HLS 스트림에 TLAST 가 없어 나눠 받으면 첫 조각 뒤 `DMAIntErr` | 26 으로 (67 MB). 한 번에 전송 |
| **PS↔PL 폭** | `AFI_FS(0xFD615000)` 는 부팅 때 FSBL 이 설정한다. `.bit` 만 갈아끼우면 미적용 → **주소 %16==8 인 레지스터 쓰기가 조용히 버려짐** (DMA 의 `SA`/`LENGTH` 가 거기) | 실행 시 교정. `AFIFM2(0xFD380000)` HP0 폭도 함께 |
| **bottleneck_router** | 스트림 소비자가 생산 종료 후에 도는 순차 구조 → 82픽셀에서 교착. C 시뮬레이션은 스트림 깊이가 무한이라 안 드러난다 | DATAFLOW 로 재작성 → 1600픽셀 |
| **DMA 구동 (SW)** | 길이 한도를 레지스터에 **써보며** 알아냈다. 그 쓰기가 곧 전송 시작 명령이라 주소 0 의 쓰레기가 회로로 들어갔다 | 상수로 고정. 완료 판정도 Idle 대신 **IOC 비트**로 (10.0초 → 0.05초) |

### 왜 여태 안 보였나

- **8비트 가중치 BRAM은 무사했다** — 1바이트 = 1칸이라 주소가 어긋나지 않는다.
  그래서 conv1x1 의 곱셈·누적은 처음부터 정확했고, 출력이 "활성값처럼" 그럴듯해 보였다.
- **깊이 2인 스케일 BRAM도 우연히 맞았다** — `4·set mod 2 = 0` 이라 늘 슬롯0 을 읽는다.
- **C 시뮬레이션에는 이 층이 없다** — 배열 인덱스로 돌기 때문에 주소 규약이 등장하지 않는다.
- Vivado 는 내내 경고하고 있었다 —
  `CRITICAL WARNING [BD 41-237] MASTER_TYPE ... (OTHER) vs (BRAM_CTRL)`

---

## 팀에 확인 요청

1. **팀 원본 BD 가 어느 브랜치에도 없습니다.** `.xpr` / `.bd` / BD tcl 이 버전 관리에
   올라와 있지 않습니다. 여기 있는 `hw/design_1_bd.tcl` 은 **팀 원본이 아니라**,
   `.hwh` 에서 역으로 재구성한 `build_fix2.tcl` 이 만들어낸 BD 를 export 한 것입니다.
   원본을 올려 주세요. 둘을 대조해야 아래 2번을 확인할 수 있습니다.
2. **위 BRAM 주소 문제가 원본 BD 에도 있는지 확인이 필요합니다.** HLS bram 포트를
   blk_mem_gen 에 직접 붙이면 어느 설계에서나 생깁니다. 합성 로그에서
   `MASTER_TYPE ... BRAM_CTRL` 경고를 찾아보시면 됩니다.
3. **배포 방식.** PYNQ 로 `.bit` 만 바꾸는 방식은 PS 설정을 적용하지 않습니다.
   최종은 XRT(`xmutil loadapp` + 디바이스트리의 `xlnx,afi-fpga` 노드)로 가는 편이
   구조적으로 안전합니다.

---

## 속도에 대해 — 솔직한 이야기

레이어별로 실측한 결과입니다 (보드, 순수 소프트웨어, 합계 1.194초).

| 레이어 | 시간 | 비중 |
|---|---|---|
| 22 Detect | 0.316 s | 26.5% |
| 2 C2f | 0.121 s | 10.1% |
| 4 C2f | 0.104 s | 8.7% |
| **6 C2f (FPGA 로 뺀 것)** | **0.077 s** | **6.5%** |

FPGA 는 이 6.5% 를 전송·양자화 포함 0.055초에 처리합니다.
**아끼는 시간은 0.022초, 전체의 1.7%** 입니다.

즉 **한 블록만 FPGA 로 빼는 구조로는 속도가 오르지 않습니다.**
전송과 양자화 비용이 아낀 계산량과 비슷하기 때문입니다.
이번 작업의 값어치는 속도가 아니라 *하드웨어가 소프트웨어와 같은 답을 낸다*
는 것을 증명한 데 있습니다.

CPU 자체는 이미 한계입니다 — Cortex-A53 4코어의 이론 최대 21.3 GFLOP/s 에 대해
행렬곱 실측이 21.86 GFLOP/s 로, 붙어 있습니다.

속도가 목표라면 방향은 하나뿐입니다. **여러 C2f 블록을 연속으로 FPGA 에 두고
중간 결과를 PS 로 왕복시키지 않는 것.** C2f 8개 합이 전체의 약 50% 이고,
구조가 모두 같아 채널 수만 다릅니다.
