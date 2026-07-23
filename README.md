# ppe_fpga
PPE monitoring AI Hardware Accelerator

# detail spec
FPGA 보드안 available DSP는 총 1248개

640x640 + 100Mhz(period=10ns) + 15fps ===> 필요 DSP 약 769개

software모델로 실행시 fps 출력 평균 6fps

hardware 가속기로 실현 목표는 6보다 높은 15fps

# yolov8n 구조 요약
model.0-1   : Stem (초기 다운샘플링 Conv, stride 2 두 번)
model.2     : C2f 블록 (32ch, bottleneck 1개)
model.3     : Conv (stride 2, 다운샘플)
model.4     : C2f 블록 (64ch, bottleneck 2개)
model.5     : Conv (stride 2, 다운샘플)
model.6     : C2f 블록 (128ch, bottleneck 2개)
model.7     : Conv (stride 2, 다운샘플)
model.8     : C2f 블록 (256ch, bottleneck 1개)
model.9     : SPPF (multi-scale pooling)
model.10-21 : Neck (Upsample + Concat + C2f 블록들, FPN/PAN 구조)
model.22    : Detection Head (3개 스케일 출력)

