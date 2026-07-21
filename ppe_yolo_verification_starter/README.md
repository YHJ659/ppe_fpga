# PPE YOLO Golden Model & RTL Verification Starter

안전모(`helmet`)와 안전 조끼/재킷(`safety_vest`) 착용 여부를 판별하는 YOLO 프로젝트를
검증하기 위한 시작점이다. 이 저장소는 두 종류의 검증을 분리한다.

1. **알고리즘 검증**: 학습된 YOLO가 이미지에서 PPE를 올바르게 검출하는가?
2. **하드웨어 검증**: RTL/FPGA 출력이 정해진 양자화 골든 모델과 일치하는가?

현재 실제 RTL 명세가 없으므로, 전체 YOLO를 구현했다고 가정하지 않는다. 대신 지금 바로
실행할 수 있는 검출 결과 비교기와 CNN의 기본 연산인 고정소수점 MAC 테스트벤치를 제공한다.
실제 DUT가 나오면 `actual.json` 생성 부분과 SystemVerilog 포트만 교체한다.

## 전체 그림

```text
고정된 이미지 세트
      |
      +--> YOLO best.pt ----------> golden.json
      |
      +--> RTL/FPGA/시뮬레이터 ---> actual.json
                                      |
                           detection comparator
                                      |
                             PASS / FAIL / report

Python 고정소수점 MAC ----> mac_vectors.txt ----> SystemVerilog DUT + scoreboard
```

## 30초 체험

아래 흐름은 OpenCV나 Ultralytics가 없어도 실행된다.

```bash
cd /Users/ohsanghun/Apex/02_Scripts/ppe_yolo_verification_starter

# 정상 DUT를 흉내 낸 결과: PASS
PYTHONPATH=python python3 python/run_verification.py --mode mock-pass

# 일부 검출을 고의로 망가뜨린 결과: FAIL과 mismatch 확인
PYTHONPATH=python python3 python/run_verification.py --mode mock-fail

# Python 단위 테스트
PYTHONPATH=python python3 -m pytest -q

# START/BUSY/DONE이 clock마다 어떻게 변하는지 보기
PYTHONPATH=python python3 python/simulate_control.py --work-cycles 5
```

`mock-fail`은 실패를 보여주는 것이 목적이므로 종료 코드 1이 정상이다.

제어 시뮬레이션 예시는 CPU가 `START=1`을 한 번 쓰고, 가속기가 `BUSY=1`인 동안
처리한 뒤 한 cycle 동안 `DONE=1`을 내는 과정을 표로 보여준다.

## 실제 YOLO 모델을 골든 모델로 실행

필요 패키지를 설치한 뒤 팀원의 `best.pt`와 고정된 테스트 이미지를 준비한다.

```bash
python3 -m pip install -r requirements.txt
mkdir -p models data/images artifacts
```

파일 배치 예시:

```text
models/best.pt
data/images/site_001.jpg
data/images/site_002.jpg
```

골든 결과 생성:

```bash
PYTHONPATH=python python3 python/export_yolo_golden.py \
  --model models/best.pt \
  --images data/images \
  --output artifacts/golden.json \
  --imgsz 960 \
  --conf 0.50
```

실제 DUT/FPGA 결과를 같은 JSON 형식의 `artifacts/actual.json`으로 만든 다음 비교한다.

```bash
PYTHONPATH=python python3 python/run_verification.py \
  --golden artifacts/golden.json \
  --actual artifacts/actual.json \
  --iou 0.50 \
  --confidence-tolerance 0.10
```

JSON 형식:

```json
{
  "frames": [
    {
      "frame_id": "site_001.jpg",
      "width": 960,
      "height": 540,
      "detections": [
        {
          "class_id": 0,
          "class_name": "helmet",
          "confidence": 0.93,
          "bbox_xyxy": [100.0, 40.0, 220.0, 190.0]
        }
      ]
    }
  ]
}
```

## 고정소수점 MAC 시뮬레이션

CNN convolution은 결국 여러 곱셈의 합이다. 먼저 Python 골든 모델로 테스트 벡터를 만든다.

```bash
PYTHONPATH=python python3 python/generate_mac_vectors.py
```

Icarus Verilog가 설치되어 있다면:

```bash
make sim-mac
make sim-control
```

`rtl/mac_core.sv`는 학습용 최소 DUT다. 실제 convolution RTL이 오면 이 파일 대신 실제 DUT를
연결하고, `tb/tb_mac_core.sv`의 입력 포트 및 vector 형식을 확장하면 된다.

## 팀원 4~5명 분담 예시

| 역할 | 산출물 | 이 저장소에서 대응하는 파일 |
|---|---|---|
| 데이터/모델 | 클래스 정의, `best.pt`, 정확도 지표 | `python/export_yolo_golden.py` |
| 골든/양자화 | bit-accurate Python, test vector | `python/ppe_verify/fixed_point.py`, `python/generate_mac_vectors.py` |
| RTL 연산 | Conv/MAC/activation RTL | `rtl/mac_core.sv`를 실제 DUT로 교체 |
| 제어/메모리 | START/DONE, AXI, buffer | `rtl/ppe_control_mock.sv` |
| 통합 검증 | scoreboard, 회귀 테스트, 보고서 | `python/run_verification.py`, `tb/` |

4명이라면 제어/메모리와 RTL 연산을 한 사람이 같이 맡을 수 있다.

## 검증 완료 기준 초안

- 같은 입력, 가중치, 양자화 규칙을 사용할 것
- 모든 프레임의 입력/출력 개수가 맞을 것
- detection-level 비교는 class 일치 + IoU 기준 + confidence 허용오차를 사용할 것
- tensor/레이어 출력은 가능하면 정수 bit-exact 비교할 것
- reset, 빈 입력, 최대/최소값, overflow, 연속 start를 포함할 것
- 실패 시 첫 mismatch의 frame/class/좌표/기대값/실제값을 출력할 것

## 아직 팀에서 확정해야 하는 항목

`config/verification.yaml`의 `TBD` 항목을 회의에서 채운다.

- 실제 클래스 이름과 class ID
- 입력 tensor layout (`NCHW`/`NHWC`)과 색 순서 (`RGB`/`BGR`)
- 입력/가중치/누산기/output 비트폭
- Q-format, rounding, saturation 규칙
- 검증 경계가 layer output인지 NMS 이후 detection인지
- START/DONE 레지스터 주소와 latency 규칙
- RTL 출력 JSON 또는 tensor dump 변환 규칙

## 팀원이 준 카메라 코드에서 주의할 점

- 웹캠은 매번 입력이 달라서 회귀 검증용 골든 입력으로 쓰기 어렵다. 데모용으로는 좋다.
- OpenCV 프레임은 `(height, width, channel)`이다. 960x540 카메라 입력의 PyTorch shape은
  일반적으로 `(1, 3, 540, 960)`이지 `(1, 3, 960, 540)`이 아니다.
- `imgsz=960`에서 Ultralytics의 실제 letterbox shape은 모델 stride와 입력 종횡비에 따라 달라질
  수 있다. 하드웨어와 대조하려면 전처리 후 tensor를 별도로 dump해야 한다.
- FP32 YOLO 결과와 INT8 RTL 결과는 바로 bit-exact 비교할 수 없다. 하드웨어 양자화 규칙을
  반영한 두 번째 골든 모델이 필요하다.
