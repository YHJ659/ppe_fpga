# KV260 YOLOv3 COCO FPGA Webcam Baseline

AMD/Xilinx Vitis AI 2.5의 공식 `yolov3_coco_416_tf2` 모델을 Kria KV260의
B4096 DPU에서 실행하고, USB 웹캠 프레임을 처리하는 재현용 저장소입니다.

이 저장소는 **FPGA DPU·USB 카메라·Vitis AI 실행 경로가 정상인지 검증하는
공식 COCO 기준선**입니다. 공사장 하이바/안전조끼 미착용을 검출하는 PPE
모델은 포함하지 않습니다.

## 검증된 결과

검증 보드 환경:

- Kria KV260, Ubuntu 22.04 ARM64
- Vitis AI 2.5 / XRT 2.13
- `kv260-benchmark-b4096` 오버레이
- `DPUCZDX8G_ISA1_B4096`, 300 MHz
- 모델·DPU fingerprint: `0x101000016010407`
- USB 카메라: `/dev/video0`, YUYV 640×480 @ 30 FPS

실측 결과:

- DPU 단독 벤치마크: **14.5832 FPS**, `Test PASS`
- 웹캠 처리: **60/60 프레임 성공**
- `YOLOv3::run()` 평균: **72.483 ms/frame**
- 60프레임 처리 루프: **11.447 FPS**

검증 원본 로그는 [`evidence/`](evidence/)에 있습니다. 개인 공간이 찍힌 웹캠
JPEG는 공개 저장소에 섞이지 않도록 제외했습니다.

## 저장소 구성

```text
.
├── README.md
├── .gitignore
├── docker/
│   ├── Dockerfile
│   └── webcam_yolov3.cpp
├── scripts/
│   ├── download_model.sh
│   ├── build_image.sh
│   ├── load_b4096_after_reboot.sh
│   ├── benchmark_dpu.sh
│   └── run_webcam.sh
├── models/
│   └── README.md
└── evidence/
```

## 빠른 실행

아래 명령은 **KV260 보드의 Ubuntu 터미널에서** 실행합니다. 저장소를
`/home/ubuntu/kv260-yolov3-coco`에 clone했다고 가정한 예시입니다.

### 1. 필수 패키지 설치

```bash
cd /home/ubuntu/kv260-yolov3-coco

sudo apt update
sudo apt install -y \
  curl \
  docker.io \
  v4l-utils \
  xlnx-firmware-kv260-benchmark-b4096

sudo systemctl enable --now docker
```

KV260 Ubuntu 이미지에 Xilinx 애플리케이션 PPA가 설정돼 있어야 합니다.

### 2. 공식 YOLOv3 모델 다운로드 및 검증

```bash
./scripts/download_model.sh
```

스크립트가 공식 KV260 archive를 내려받고 MD5/SHA-256을 검증한 뒤 다음
두 파일을 생성합니다.

```text
models/yolov3_coco_416_tf2/yolov3_coco_416_tf2.xmodel
models/yolov3_coco_416_tf2/yolov3_coco_416_tf2.prototxt
```

모델 archive와 추출 파일은 GitHub에 commit되지 않습니다.

### 3. ARM64 실행 이미지 빌드

```bash
sudo ./scripts/build_image.sh
```

Dockerfile은 검증에 사용한 공식 이미지를 digest로 고정합니다.

```text
xilinx/smartcam:2022.1
sha256:da2e52629011aeec332152a0f468d3ff156917dba9b596cf6d0de958d5dc29d7
```

컴파일러와 OpenCV 개발 패키지는 build stage에만 설치되며, 최종 이미지에는
실행 바이너리와 필요한 runtime만 남습니다.

### 4. 재부팅 후 B4096 오버레이를 한 번만 로드

```bash
sudo reboot
```

다시 SSH로 접속한 뒤:

```bash
cd /home/ubuntu/kv260-yolov3-coco
sudo ./scripts/load_b4096_after_reboot.sh --after-reboot
```

2022.1 스택에서는 accelerator를 짧은 간격으로 반복 unload/load하면 불안정할
수 있습니다. 문제가 생기면 반복 실행하지 말고 cold reboot 후 위 명령을 한
번만 실행하십시오.

### 5. 선택: DPU 단독 벤치마크

```bash
sudo ./scripts/benchmark_dpu.sh
```

결과는 `results/dpu-b4096-날짜시간/benchmark.log`에 저장됩니다.

### 6. USB 웹캠 YOLOv3 실행

```bash
v4l2-ctl --list-devices
sudo ./scripts/run_webcam.sh 60
```

기본 카메라는 `/dev/video0`입니다. 다른 장치를 사용하려면:

```bash
sudo CAMERA_DEVICE=/dev/video2 ./scripts/run_webcam.sh 60
```

결과 폴더:

```text
results/webcam-b4096-날짜시간/
├── raw_first.jpg
├── best_annotated.jpg
├── last_annotated.jpg
├── detections.csv
├── summary.txt
└── run.log
```

`best_annotated.jpg`가 검출 박스가 가장 많이 나온 프레임입니다. 프로그램은
SSH 환경에서 안전하게 실행하도록 GUI 창을 열지 않고 결과 파일을 저장합니다.

## Mac으로 결과 복사

Mac 터미널에서 실행합니다. 저장소를 위 예시 경로에 clone한 경우:

```bash
RESULT_DIR="$(ssh ubuntu@192.168.1.224 \
  'ls -dt /home/ubuntu/kv260-yolov3-coco/results/webcam-b4096-* | head -1')"

scp "ubuntu@192.168.1.224:${RESULT_DIR}/best_annotated.jpg" ~/Downloads/
open ~/Downloads/best_annotated.jpg
```

## 모델·하드웨어 불변식

이 조합이 FPGA에서 동작하려면 아래 값이 반드시 일치해야 합니다.

```text
xmodel DPU Arch : DPUCZDX8G_ISA1_B4096
hardware DPU    : DPUCZDX8G_ISA1_B4096
xmodel fingerprint : 0x101000016010407
hardware fingerprint: 0x101000016010407
```

`kv260-smartcam`의 B3136 오버레이와 이 B4096 xmodel을 혼용하지 마십시오.
상세 query 결과는 [`evidence/hardware-query.log`](evidence/hardware-query.log)와
[`evidence/xmodel-query.log`](evidence/xmodel-query.log)에 있습니다.

## 공식 출처

- [Vitis AI 2.5 YOLOv3 model.yaml](https://github.com/Xilinx/Vitis-AI/blob/v2.5/model_zoo/model-list/tf2_yolov3_coco_416_416_65.9G_2.5/model.yaml)
- [Vitis AI 2.5 YOLOv3 API](https://github.com/Xilinx/Vitis-AI/blob/v2.5/src/Vitis-AI-Library/yolov3/include/vitis/ai/yolov3.hpp)
- [Vitis AI 2.5 YOLOv3 sample](https://github.com/Xilinx/Vitis-AI/tree/v2.5/examples/Vitis-AI-Library/samples/yolov3)
- [KV260 SmartCam model customization](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/smartcamera/docs/customize_ai_models.html)
- [KV260 SmartCam known issues](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/smartcamera/docs/issue-sc.html)

## 주요 체크섬

```text
YOLOv3 archive MD5
ae417567b1462c7d5b6708285643f140

YOLOv3 archive SHA-256
b566a6a4bad3d552d819c3c4c9968f4a95bb05b4a71e34c6583b878137ecec0b

xmodel SHA-256
315a0c0ff6d901b0c79d63068aa9c70b26f45521ff4e11687fd39586cb111cb8

prototxt SHA-256
65fc79e2f181d1ecbd7f2e2e7a0b1b8c3adceb929ca6e461caae9c01b6418c48
```
