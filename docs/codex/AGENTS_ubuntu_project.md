# PPE Monitoring AI Hardware Accelerator

## 1. 프로젝트 개요

이 저장소는 AMD/Xilinx Kria KV260 보드에서 PPE Monitoring용 YOLOv8n 모델의 일부를
FPGA 하드웨어 가속기로 구현하기 위한 팀 프로젝트다.

현재 사용자가 담당하는 핵심 범위는 다음과 같다.

1. 조원들이 Vitis HLS로 작성한 커스텀 IP를 확인한다.
2. 각 HLS IP를 Vivado IP Repository에 등록한다.
3. Vivado IP Integrator의 Block Design에 IP를 추가한다.
4. Zynq MPSoC, AXI, Clock, Reset, DDR 또는 BRAM 인터페이스를 연결한다.
5. Validate Design을 통과한다.
6. Synthesis를 통과한다.
7. Implementation을 통과한다.
8. Timing 및 Resource Utilization을 확인한다.
9. KV260용 Bitstream을 생성한다.
10. XSA 또는 Bitstream/HWH를 Export한다.
11. Vitis 또는 PYNQ에서 IP를 제어하고 결과를 검증한다.

현재 최우선 목표는 성능 최적화보다 다음 순서다.

```text
기존 소스 및 IP 조사
→ 인터페이스 불일치 확인
→ 최소 IP 통합
→ 전체 Block Design 통합
→ Validate Design
→ Synthesis
→ Implementation
→ Bitstream
→ 보드 실행
→ 정확도 및 성능 최적화
```

---

## 2. 프로젝트 목표

프로젝트명:

```text
PPE Monitoring AI Hardware Accelerator
```

대상 AI 모델:

```text
YOLOv8n
```

현재 하드웨어 구현 대상:

```text
model.6 C2f 블록
```

기존 Software 추론 성능:

```text
평균 약 6 FPS
```

최종 목표 성능:

```text
640×640 입력
100 MHz PL Clock
15 FPS 이상 목표
```

대상 FPGA에서 확인된 DSP 개수:

```text
Available DSP: 1248
```

단, DSP 1248개를 모두 연산에 사용할 수 있다고 가정하지 않는다.
Vivado의 실제 Utilization Report를 기준으로 판단한다.

---

## 3. 개발 환경

- Host OS: Ubuntu 22.04
- Vivado: AMD/Xilinx Vivado 2022.2
- Vitis: AMD/Xilinx Vitis 2022.2
- Vitis HLS: AMD/Xilinx Vitis HLS 2022.2
- Target Board: Kria KV260 Vision AI Starter Kit
- Device Family: Zynq UltraScale+ MPSoC
- Device: XCK26 계열
- PL Clock Target: 100 MHz
- HLS Language: C/C++
- RTL Language: Verilog/SystemVerilog
- Software Language: C/C++ 또는 Python
- Quantization Target:
  - Input activation: INT8
  - Weight: INT8
  - Accumulator: INT32
  - Output activation: INT8

Vivado, Vitis, Vitis HLS 버전을 임의로 2023.2, 2024.x, 2025.x 등으로 변경하지 않는다.
모든 Tcl 명령과 HLS pragma는 우선 2022.2 환경을 기준으로 작성한다.

---

## 4. 프로젝트 루트

프로젝트 루트는 다음과 같다.

```text
/home/sogang/ppe_fpga_ho
```

Codex는 작업 시작 전 반드시 다음 명령으로 현재 위치를 확인한다.

```bash
pwd
```

출력이 다음과 다르면 프로젝트 루트로 이동한다.

```text
/home/sogang/ppe_fpga_ho
```

이후 다음 명령으로 실제 파일과 디렉터리를 조사한다.

```bash
find . -maxdepth 2 -type d | sort
find . -maxdepth 4 -type f | sort
```

문서에 적힌 예상 경로보다 실제 파일 시스템의 경로를 우선한다.

존재하지 않는 경로, IP, 파일명을 추측하여 사용하지 않는다.

---

## 5. 현재 주요 소스 디렉터리

현재 확인된 주요 HLS 소스 디렉터리는 다음과 같다.

```text
/home/sogang/ppe_fpga_ho/
├── AGENTS.md
├── BatchNorm/
│   └── bn_silu_64.cpp
├── BatchNorm_128/
│   └── bn_silu_128.cpp
├── Split/
│   └── split_channel.cpp
├── Concat/
│   └── concat_channel.cpp
├── residual_add/
│   └── residual_add.cpp
├── conv1x1/
│   └── conv1x1.cpp
└── conv3x3/
    └── conv3x3.cpp
```

실제 파일명이 다르면 `find` 결과를 기준으로 수정한다.

향후 필요할 수 있는 작업용 디렉터리는 다음과 같다.

```text
/home/sogang/ppe_fpga_ho/
├── ip_repo/
├── vivado/
├── scripts/
├── reports/
├── docs/
├── software/
└── artifacts/
```

위 디렉터리가 존재하지 않을 경우, 생성 전에 어떤 용도로 만들 것인지 사용자에게 설명한다.

---

## 6. 구현 대상 model.6 C2f 구조

현재 구현 대상의 예상 입출력은 다음과 같다.

```text
Input feature map:
128 × 40 × 40, INT8
```

예상 데이터 흐름은 다음과 같다.

```text
Input: 128×40×40
        |
        v
cv1: Conv1×1
128 input channels
128 output channels
        |
        v
BN + SiLU
128 channels
        |
        v
Split Channel
128 channels → 64 channels + 64 channels
        |
        +-------------------+
        |                   |
       y0                  y1
                            |
                            v
                     Bottleneck 0
                     Conv3×3 64→64
                     BN + SiLU
                     Conv3×3 64→64
                     BN + SiLU
                     Residual Add
                            |
                            v
                           y2
                            |
                            v
                     Bottleneck 1
                     Conv3×3 64→64
                     BN + SiLU
                     Conv3×3 64→64
                     BN + SiLU
                     Residual Add
                            |
                            v
                           y3

Concat:
y0 + y1 + y2 + y3
64 + 64 + 64 + 64 = 256 channels
        |
        v
cv2: Conv1×1
256 input channels
128 output channels
        |
        v
BN + SiLU
128 channels
        |
        v
Output: 128×40×40
```

이 구조는 예상 구조다.

실제 학습 모델의 다음 정보를 확인하기 전에는 확정 사실로 단정하지 않는다.

- PyTorch model 출력
- `model.6` module 구조
- `state_dict` weight shape
- ONNX graph
- Tensor shape 출력
- 실제 YOLOv8n yaml 또는 model summary

구조가 다르면 실제 모델을 기준으로 문서와 소스를 수정한다.

---

## 7. 현재 HLS IP 7종

현재 프로젝트의 주요 HLS IP 종류는 다음과 같다.

### 7.1 Conv1×1

예상 파일:

```text
conv1x1/conv1x1.cpp
```

현재 알려진 model.6 cv1 설정:

```text
Input shape: 128×40×40
Weight shape: 128×128×1×1
Output shape: 128×40×40
Input type: ap_int<8>
Weight type: ap_int<8>
Accumulator/Output type: ap_int<32>
```

마지막 cv2에는 다음 설정이 필요할 가능성이 있다.

```text
Input channels: 256
Output channels: 128
Kernel: 1×1
```

현재 Conv1×1 IP가 128→128만 지원한다면,
256→128을 지원하도록 별도 IP 또는 parameterized IP가 필요한지 검토한다.

### 7.2 Conv3×3

예상 파일:

```text
conv3x3/conv3x3.cpp
```

현재 알려진 설정:

```text
Input shape: 64×40×40
Weight shape: 64×64×3×3
Output shape: 64×40×40
Padding: 1
Input type: ap_int<8>
Weight type: ap_int<8>
Accumulator/Output type: ap_int<32>
```

### 7.3 BN + SiLU 64

파일:

```text
BatchNorm/bn_silu_64.cpp
```

현재 알려진 설정:

```text
Input shape: 64×40×40
Input type: ap_int<32>
BN scale: float[64]
BN shift: float[64]
Output shape: 64×40×40
Output type: ap_int<8>
```

### 7.4 BN + SiLU 128

파일:

```text
BatchNorm_128/bn_silu_128.cpp
```

현재 알려진 설정:

```text
Input shape: 128×40×40
Input type: ap_int<32>
BN scale: float[128]
BN shift: float[128]
Output shape: 128×40×40
Output type: ap_int<8>
```

### 7.5 Split Channel

파일:

```text
Split/split_channel.cpp
```

현재 알려진 설정:

```text
Input: 128×40×40
Output y0: 64×40×40
Output y1: 64×40×40
Type: ap_int<8>
```

### 7.6 Residual Add

파일:

```text
residual_add/residual_add.cpp
```

현재 알려진 설정:

```text
Input x: 64×40×40
Input F(x): 64×40×40
Output: 64×40×40
Input type: ap_int<8>
Output type: ap_int<8>
Runtime scale parameters: float
```

### 7.7 Concat Channel

파일:

```text
Concat/concat_channel.cpp
```

현재 알려진 설정:

```text
Input y0: 64×40×40
Input y1: 64×40×40
Input y2: 64×40×40
Input y3: 64×40×40
Output: 256×40×40
Input type: ap_int<8>
Output type: ap_int<8>
Runtime scale parameters: float
```

---

## 8. IP 종류와 실행 횟수 구분

IP 종류는 7개지만 model.6에서 실제 실행 횟수는 더 많을 수 있다.

예상 실행 횟수:

```text
conv1x1       : 2회
conv3x3       : 4회
bn_silu_64    : 4회
bn_silu_128   : 2회
split_channel : 1회
residual_add  : 2회
concat_channel: 1회
```

1차 통합에서는 같은 기능의 IP를 여러 개 복제하지 않는다.

가능하면 다음 구조를 우선 검토한다.

```text
Conv3×3 IP 1개를 PS가 4회 실행
BN+SiLU 64 IP 1개를 PS가 4회 실행
Residual Add IP 1개를 PS가 2회 실행
Conv1×1 IP 1개 또는 2개를 필요한 설정으로 실행
```

IP 복제는 Resource Utilization과 Timing을 확인한 후에 수행한다.

---

## 9. 현재 코드의 중요한 확인 사항

현재 일부 IP는 다음과 같은 BRAM 인터페이스를 사용한다.

```cpp
#pragma HLS INTERFACE bram port=input
#pragma HLS INTERFACE bram port=weight
#pragma HLS INTERFACE bram port=output
```

일부 IP는 다음과 같은 AXI-Lite control을 사용한다.

```cpp
#pragma HLS INTERFACE s_axilite port=return
```

IP별로 인터페이스 구성이 서로 다를 수 있으므로,
Block Design Tcl을 만들기 전에 실제 생성 포트를 확인한다.

다음 사항을 추측하지 않는다.

- `s_axi_control` 포트가 있다고 가정
- `m_axi_gmem` 포트가 있다고 가정
- BRAM port끼리 직접 연결할 수 있다고 가정
- 모든 IP의 Reset polarity가 같다고 가정
- 모든 IP에 `ap_start`, `ap_done`이 있다고 가정
- 모든 IP가 `ap_ctrl_hs`를 사용한다고 가정

반드시 다음 파일 또는 명령으로 확인한다.

```text
component.xml
HLS synthesis report
HLS interface report
Vivado IP Catalog
Vivado get_bd_intf_pins
Vivado get_bd_pins
```

---

## 10. HLS IP 인터페이스 원칙

### 10.1 제어 경로

낮은 대역폭의 제어 정보는 AXI4-Lite를 사용한다.

예:

```text
ap_start
ap_done
ap_idle
ap_ready
input pointer address
weight pointer address
output pointer address
input_scale
weight_scale
output_scale
channel count
```

권장 형태:

```cpp
#pragma HLS INTERFACE s_axilite port=input bundle=control
#pragma HLS INTERFACE s_axilite port=weight bundle=control
#pragma HLS INTERFACE s_axilite port=output bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control
```

### 10.2 대용량 데이터 경로

Feature Map과 Weight 같은 대용량 데이터는 AXI-Lite로 전송하지 않는다.

가능한 방식:

```text
1. AXI4 Master를 통한 DDR 접근
2. AXI4-Stream을 통한 IP 간 연결
3. AXI BRAM Controller 및 Block Memory Generator
```

현재 프로젝트의 1차 통합에서는 다음을 우선 검토한다.

```text
Control:
PS M_AXI_HPM0_FPD
→ AXI SmartConnect
→ 각 HLS IP s_axi_control

Data:
각 HLS IP m_axi
→ AXI SmartConnect
→ PS S_AXI_HP0_FPD
→ DDR
```

단, 기존 HLS IP가 BRAM interface만 제공할 경우
코드를 즉시 전부 수정하지 말고 다음을 먼저 보고한다.

1. 현재 BRAM port 이름
2. Master/Slave 성격
3. 필요한 Block Memory Generator 수
4. 필요한 AXI BRAM Controller 수
5. 예상 메모리 용량
6. AXI Master 방식으로 변경할 때 필요한 수정
7. 각 방식의 장단점

### 10.3 AXI4-Stream

AXI4-Stream 방식은 성능 최적화 단계에서 검토한다.

다음 블록은 Stream 구조가 비교적 단순할 수 있다.

```text
Conv → BN/SiLU
```

다음 블록은 별도 버퍼와 분기 제어가 필요하다.

```text
Split
Residual
Concat
```

처음부터 전체 model.6를 AXI4-Stream으로 바꾸지 않는다.

---

## 11. 데이터 레이아웃

기본 Feature Map 레이아웃은 CHW다.

```text
[channel][height][width]
```

1차원 주소 계산:

```text
index = (channel × H + row) × W + column
```

Conv1×1 weight 레이아웃:

```text
[OUT_CH][IN_CH]
```

주소 계산:

```text
index = output_channel × IN_CH + input_channel
```

Conv3×3 weight 레이아웃:

```text
[OUT_CH][IN_CH][K][K]
```

주소 계산:

```text
index =
(((output_channel × IN_CH + input_channel) × K + kernel_row) × K)
+ kernel_column
```

다음 레이아웃을 혼용하지 않는다.

```text
CHW
HWC
NHWC
NCHW
```

레이아웃 변경이 필요하면 다음 항목을 모두 함께 수정한다.

- HLS IP
- 테스트벤치
- Python Golden Model
- Vitis C/C++ 코드
- PYNQ Python 코드
- Weight 변환 코드
- 문서

---

## 12. 데이터 크기 참고

다음 크기를 기준으로 중간 메모리 구조를 검토한다.

### INT8 64×40×40

```text
64 × 40 × 40 = 102,400 byte
```

### INT8 128×40×40

```text
128 × 40 × 40 = 204,800 byte
```

### INT8 256×40×40

```text
256 × 40 × 40 = 409,600 byte
```

### INT32 64×40×40

```text
64 × 40 × 40 × 4 = 409,600 byte
```

### INT32 128×40×40

```text
128 × 40 × 40 × 4 = 819,200 byte
```

IP 사이마다 전체 Feature Map 크기의 BRAM을 무조건 배치하지 않는다.

BRAM 사용량 계산 없이 Block Memory Generator를 반복 생성하지 않는다.

---

## 13. 수치 형식 및 양자화

기본 형식:

```text
Input activation : ap_int<8>
Weight           : ap_int<8>
Accumulator      : ap_int<32>
Output activation: ap_int<8>
```

INT8 출력은 반드시 saturation한다.

```text
Maximum: 127
Minimum: -128
```

다음 값은 실제 학습 또는 양자화 모델에서 가져와야 한다.

- input scale
- weight scale
- output scale
- zero point
- BN scale
- BN shift
- fused multiplier
- shift amount

위 값을 찾을 수 없으면 임의로 생성하지 않고 `확인 필요`라고 기록한다.

---

## 14. BN 및 SiLU 규칙

현재 BN+SiLU 코드에는 다음 연산이 포함될 수 있다.

```text
float multiplication
float addition
float division
hls::exp()
float-to-int conversion
```

`hls::exp()`는 FPGA 자원을 많이 사용할 수 있으므로
다음 보고서를 확인한다.

- DSP usage
- LUT usage
- FF usage
- BRAM usage
- Latency
- Initiation Interval
- Estimated Clock
- Timing warning

최적화 후보:

```text
1. Conv-BN Fusion
2. Fixed-point multiplier
3. Integer multiplier + shift
4. SiLU Lookup Table
5. Piecewise Linear Approximation
```

사용자 승인 없이 SiLU를 ReLU로 변경하지 않는다.

수치 동작이 변하는 최적화 전후에는 반드시 다음 결과를 비교한다.

```text
PyTorch 또는 Python Golden Model
HLS C Simulation
HLS C/RTL Co-simulation
FPGA 실행 결과
```

---

## 15. ARRAY_PARTITION 및 로컬 버퍼 규칙

현재 Conv IP에는 다음 구조가 포함될 수 있다.

```cpp
static ap_int<8> local_input[...];
static ap_int<8> local_weight[...];
#pragma HLS ARRAY_PARTITION ...
```

대형 배열에 여러 차원의 Partition을 동시에 적용하면 다음 문제가 발생할 수 있다.

- BRAM 증가
- LUTRAM 증가
- FF 증가
- Routing congestion
- Timing failure
- Implementation failure

Codex는 ARRAY_PARTITION을 무조건 삭제하거나 무조건 확대하지 않는다.

다음 절차를 따른다.

1. 기존 HLS synthesis report 확인
2. 실제 Final II 확인
3. Memory port limitation 확인
4. Resource 사용량 확인
5. Partition factor별 대안 제시
6. 하나의 변경만 적용
7. 재합성 후 전후 비교

HLS pragma에 작성된 `PIPELINE II`와 실제 `Final II`를 구분한다.

예:

```text
Requested II = 4
Final II = 실제 HLS report 값
```

Final II를 확인하지 않고 성능을 계산하지 않는다.

---

## 16. HLS IP 조사 절차

각 HLS IP에 대해 다음 순서로 조사한다.

1. 실제 소스 파일 경로 확인
2. Top function 이름 확인
3. Macro와 tensor shape 확인
4. Input/Output type 확인
5. HLS pragma 확인
6. Interface type 확인
7. HLS solution 폴더 확인
8. `csynth.rpt` 확인
9. `component.xml` 확인
10. Export IP 존재 여부 확인
11. Vivado IP Catalog 등록 가능 여부 확인
12. VLNV 확인
13. 생성되는 실제 port 이름 확인
14. Known warning 기록

사용 가능한 명령 예시:

```bash
find . -name "component.xml" -o -name "*csynth.rpt" -o -name "*.zip" | sort
find . -path "*/impl/ip" -type d | sort
grep -R "#pragma HLS INTERFACE" -n .
grep -R "void " -n --include="*.cpp" --include="*.h" .
```

각 IP 조사 결과는 다음 파일에 기록한다.

```text
docs/current_ip_audit.md
```

각 IP의 HLS 결과는 다음 형식으로 정리한다.

```text
IP name:
Source path:
Top function:
Input shape:
Output shape:
Input type:
Output type:
Control interface:
Data interface:
Clock target:
Estimated clock:
Latency:
Final II:
LUT:
FF:
BRAM:
URAM:
DSP:
Export IP path:
VLNV:
Warnings:
Block Design integration status:
```

---

## 17. Vivado IP Repository 규칙

IP Repository를 추가하기 전에 각 IP 폴더 안에 다음 파일이 존재하는지 확인한다.

```text
component.xml
```

Repository 후보 예시:

```text
/home/sogang/ppe_fpga_ho/ip_repo
```

또는 각 HLS solution의:

```text
solution*/impl/ip
```

Vivado Tcl 예시:

```tcl
set PROJECT_ROOT "/home/sogang/ppe_fpga_ho"
set IP_REPO_DIR "$PROJECT_ROOT/ip_repo"

if {![file exists $IP_REPO_DIR]} {
    error "IP repository does not exist: $IP_REPO_DIR"
}

set_property ip_repo_paths [list $IP_REPO_DIR] [current_project]
update_ip_catalog
```

실제 VLNV는 다음 명령으로 확인한다.

```tcl
get_ipdefs -all
```

IP 이름을 추측해서 `create_bd_cell`을 작성하지 않는다.

---

## 18. Vivado Block Design 1차 목표 구조

### 18.1 Control Path

권장 제어 경로:

```text
Zynq UltraScale+ MPSoC
M_AXI_HPM0_FPD
        |
        v
AXI SmartConnect
        |
        +--> conv1x1 control
        +--> conv3x3 control
        +--> bn_silu_64 control
        +--> bn_silu_128 control
        +--> split_channel control
        +--> residual_add control
        +--> concat_channel control
```

### 18.2 DDR Data Path

HLS IP가 AXI Master interface를 제공할 경우:

```text
conv1x1 m_axi --------\
conv3x3 m_axi ---------\
bn_silu_64 m_axi -------\
bn_silu_128 m_axi -------+--> AXI SmartConnect
split_channel m_axi -----/            |
residual_add m_axi -----/             v
concat_channel m_axi --/      PS S_AXI_HP0_FPD
                                           |
                                           v
                                          DDR
```

### 18.3 BRAM Data Path

기존 IP가 BRAM interface만 제공할 경우,
각 생산자와 소비자 사이의 BRAM 포트를 직접 연결하지 않는다.

필요한 경우 다음 구조를 검토한다.

```text
Producer HLS IP
      |
      v
Block Memory Generator
      |
      v
Consumer HLS IP
```

또는:

```text
PS AXI
   |
   v
AXI BRAM Controller
   |
   v
Block Memory Generator
   |
   +--> HLS IP BRAM port
```

BRAM Port A/B의 Read/Write 역할과 충돌 여부를 확인한다.

---

## 19. Clock 및 Reset 규칙

기본 PL Clock:

```text
pl_clk0 = 100 MHz
```

가능하면 1차 통합은 하나의 Clock Domain으로 구성한다.

Clock 연결 대상:

```text
모든 HLS IP ap_clk
모든 AXI SmartConnect clock
M_AXI_HPM0_FPD clock
S_AXI_HP0_FPD clock
Processor System Reset slowest_sync_clk
```

Reset 구조:

```text
Zynq pl_resetn0
        |
        v
Processor System Reset
        |
        +--> peripheral_aresetn
        +--> interconnect_aresetn
```

Reset polarity를 실제 port 이름과 component.xml에서 확인한다.

다음을 혼용하지 않는다.

```text
Active High Reset
Active Low Reset
Synchronous Reset
Asynchronous Reset
```

필요하지 않은 Clock Converter 또는 Reset Converter를 임의로 추가하지 않는다.

---

## 20. Vivado Tcl 작성 규칙

반복 가능한 Vivado 작업은 가능한 한 Tcl 스크립트로 작성한다.

권장 스크립트:

```text
scripts/
├── 00_check_environment.sh
├── 01_register_ip_repo.tcl
├── 02_create_project.tcl
├── 03_create_minimal_bd.tcl
├── 04_create_model6_bd.tcl
├── 05_build_bitstream.tcl
├── 06_export_xsa.tcl
└── 07_generate_reports.tcl
```

Tcl 작성 조건:

1. Vivado 2022.2 기준
2. 프로젝트 루트는 하나의 변수로 관리
3. 실제 Board Part 또는 Device Part를 확인
4. IP VLNV를 실제 Catalog에서 확인
5. 실제 interface와 pin 이름을 확인
6. 존재하지 않는 IP는 명확한 오류 출력
7. Clock/Reset 연결 여부 검사
8. Address 할당
9. `validate_bd_design` 실행
10. Generate Output Products
11. HDL Wrapper 생성
12. Synthesis 실행
13. Synthesis 성공 여부 확인
14. Implementation 실행
15. Implementation 성공 여부 확인
16. Timing Report 저장
17. Utilization Report 저장
18. DRC Report 저장
19. Bitstream 성공 여부 확인
20. XSA Export 여부 확인

예시 공통 변수:

```tcl
set PROJECT_ROOT "/home/sogang/ppe_fpga_ho"
set PROJECT_NAME "ppe_model6_kv260"
set PROJECT_DIR "$PROJECT_ROOT/vivado/$PROJECT_NAME"
set IP_REPO_DIR "$PROJECT_ROOT/ip_repo"
set REPORT_DIR "$PROJECT_ROOT/reports/vivado"
set ARTIFACT_DIR "$PROJECT_ROOT/artifacts"
```

기존 프로젝트나 파일을 자동으로 삭제하지 않는다.

삭제가 필요하면 대상과 이유를 먼저 사용자에게 설명한다.

---

## 21. Block Design Tcl 작성 전 필수 확인

Tcl에서 연결 명령을 작성하기 전에 다음 명령으로 실제 포트를 확인한다.

```tcl
get_ipdefs -all
get_bd_cells
get_bd_intf_pins -of_objects [get_bd_cells <cell_name>]
get_bd_pins -of_objects [get_bd_cells <cell_name>]
```

다음 정보가 확인되지 않으면 추측으로 Tcl을 완성하지 않는다.

- IP VLNV
- Interface 이름
- Master/Slave 방향
- Clock pin 이름
- Reset pin 이름
- Reset polarity
- AXI bundle 이름
- BRAM port 이름
- Address width
- Data width
- Control register interface
- DDR address space

확인되지 않은 항목은 다음과 같이 보고한다.

```text
확인 완료
확인 필요
현재 파일에서 찾을 수 없음
추정
```

---

## 22. 최소 통합 우선 원칙

처음부터 7개 IP 전체를 Block Design에 배치하지 않는다.

다음 순서로 진행한다.

### Phase 1: 현재 IP 전수 조사

```text
소스 확인
→ HLS pragma 확인
→ HLS report 확인
→ component.xml 확인
→ Vivado 등록 가능 여부 확인
```

### Phase 2: Conv1×1 최소 통합

목표 구조:

```text
Zynq PS
→ AXI Control
→ Conv1×1 IP
→ DDR 또는 BRAM
```

검증 단계:

```text
Validate Design
→ Synthesis
→ Implementation
→ Bitstream
```

### Phase 3: Conv1×1 + BN/SiLU 통합

```text
Conv1×1
→ 중간 버퍼
→ BN/SiLU 128
```

### Phase 4: Split 통합

```text
Conv1×1
→ BN/SiLU
→ Split
```

### Phase 5: Bottleneck 1개 통합

```text
Conv3×3
→ BN/SiLU
→ Conv3×3
→ BN/SiLU
→ Residual Add
```

### Phase 6: Bottleneck 2개 및 Concat 통합

### Phase 7: 마지막 Conv1×1 256→128 통합

### Phase 8: model.6 전체 Bitstream

단계가 실패하면 로그를 분석하기 전에 다음 단계로 넘어가지 않는다.

---

## 23. Vivado Build 순서

Vivado 통합 작업은 다음 순서를 따른다.

```text
1. Project 생성
2. Board Part 또는 Device Part 확인
3. IP Repository 등록
4. IP Catalog Update
5. Block Design 생성
6. Zynq UltraScale+ MPSoC 추가
7. Run Block Automation
8. 필요한 HPM/HP AXI Port 활성화
9. HLS IP 추가
10. AXI SmartConnect 추가
11. Data interface 연결
12. Control interface 연결
13. Clock 연결
14. Reset 연결
15. Address 할당
16. validate_bd_design
17. Save Block Design
18. Generate Output Products
19. Create HDL Wrapper
20. Set Top
21. Run Synthesis
22. Synthesis Utilization 확인
23. Run Implementation
24. Timing Summary 확인
25. DRC 확인
26. Generate Bitstream
27. XSA Export
```

Vivado GUI에서 통과한 작업도 가능한 한 Tcl로 재현한다.

---

## 24. 성공 기준

### 24.1 HLS IP 성공 기준

```text
C Simulation PASS
C Synthesis 완료
Top function 확인
Interface 확인
Estimated Clock 기록
Latency 기록
Final II 기록
Resource 기록
Export IP 완료
component.xml 확인
Vivado IP Catalog 인식
```

### 24.2 Block Design 성공 기준

```text
Unconnected Clock 없음
Unconnected Reset 없음
Unconnected AXI interface 없음
Address 할당 완료
Validate Design PASS
Critical Warning 검토 완료
```

### 24.3 Synthesis 성공 기준

```text
Synthesis run status = Complete
Resource Utilization 확인
Black Box 없음
Latch 또는 Memory warning 검토
```

### 24.4 Implementation 성공 기준

```text
Implementation run status = Complete
Placement 완료
Routing 완료
DRC Error 0
Timing 결과 기록
```

### 24.5 Bitstream 성공 기준

```text
write_bitstream 완료
.bit 파일 존재
로그에 Bitstream Generation Completed 확인
```

단순히 Vivado 프로세스가 종료된 것을 성공으로 판단하지 않는다.

---

## 25. 리포트 저장 규칙

Vivado 리포트는 다음 위치에 저장한다.

```text
reports/vivado/
├── synth_utilization.rpt
├── impl_utilization.rpt
├── timing_summary.rpt
├── drc.rpt
├── power.rpt
├── clock_interaction.rpt
├── address_map.txt
└── build.log
```

HLS 리포트는 다음 형식으로 저장한다.

```text
reports/hls/
├── conv1x1/
├── conv3x3/
├── bn_silu_64/
├── bn_silu_128/
├── split_channel/
├── residual_add/
└── concat_channel/
```

수정 전후 리포트를 덮어쓰지 않는다.

가능하면 날짜 또는 버전을 파일명에 포함한다.

---

## 26. 코드 수정 규칙

코드 수정 시 다음을 지킨다.

1. 수정 전 원본 파일 확인
2. Git 상태 확인
3. 한 번에 하나의 문제만 수정
4. 수정 이유 기록
5. Tensor shape 유지
6. Data type 유지
7. Interface 변화 기록
8. Resource 영향 예상
9. Latency 영향 예상
10. 변경 후 C Simulation
11. 변경 후 C Synthesis
12. 가능하면 C/RTL Co-simulation
13. 결과 비교
14. 남은 문제 기록

다음 항목은 사용자 승인 없이 변경하지 않는다.

- YOLO model 구조
- Input resolution
- Channel 수
- Kernel 크기
- Padding
- SiLU를 ReLU로 변경
- Quantization scale
- Signed/Unsigned type
- Tensor layout
- Accumulator bit width
- Output saturation 범위
- Clock frequency
- Vivado/Vitis 버전

---

## 27. 자동 생성 파일 규칙

다음 파일과 디렉터리는 직접 수정하지 않는다.

```text
*.xpr
*.bd
*.dcp
*.bit
*.xsa
*.hwh
vivado.cache/
vivado.gen/
vivado.hw/
vivado.ip_user_files/
vivado.runs/
vivado.sim/
solution*/impl/
solution*/syn/
solution*/sim/
```

필요한 변경은 다음 원본에서 수행한다.

```text
HLS C/C++ source
HLS Tcl
Vivado Tcl
XDC
Vitis C/C++
PYNQ Python
```

이후 자동 생성물을 다시 생성한다.

---

## 28. Git 및 백업 규칙

작업 전 다음 명령을 실행한다.

```bash
git status
```

Git 저장소가 아니라면 사용자에게 알린다.

중요 파일을 수정하기 전에 최소한 다음 중 하나를 수행한다.

```text
Git commit
Git branch
백업 복사본
```

다음 대용량 자동 생성물은 기본적으로 Git에 추가하지 않는다.

```text
.Xil/
.vivado/
*.jou
*.log
*.str
*.wdb
*.vcd
*.dcp
vivado.cache/
vivado.gen/
vivado.hw/
vivado.ip_user_files/
vivado.runs/
vivado.sim/
solution*/.autopilot/
solution*/syn/
solution*/sim/
```

제출에 필요한 결과물은 다음 위치에 복사할 수 있다.

```text
artifacts/
```

예:

```text
artifacts/ppe_model6.bit
artifacts/ppe_model6.hwh
artifacts/ppe_model6.xsa
artifacts/timing_summary.rpt
artifacts/impl_utilization.rpt
```

---

## 29. 오류 분석 규칙

오류가 발생하면 로그를 먼저 조사한다.

확인 대상:

```text
Vivado Tcl Console
vivado.log
vivado.jou
runme.log
synth_1 log
impl_1 log
HLS csynth report
HLS build log
Vitis build log
```

오류 분석 형식:

```text
발생 단계:
정확한 오류 메시지:
관련 파일:
관련 IP:
직접 원인:
근본 원인:
수정 후보:
선택한 수정:
수정 후 결과:
남은 위험:
```

로그를 확인하지 않고 원인을 단정하지 않는다.

실행하지 않은 명령을 실행했다고 말하지 않는다.

Bitstream이 생성되지 않았으면 성공했다고 말하지 않는다.

---

## 30. Codex 작업 방식

Codex는 요청을 받으면 다음 순서로 진행한다.

```text
1. AGENTS.md 읽기
2. 현재 위치 확인
3. 파일 구조 조사
4. 관련 소스 읽기
5. 관련 로그 및 리포트 확인
6. 현재 상태 요약
7. 작업 계획 제시
8. 필요한 최소 변경 수행
9. 명령 실행
10. 결과 검증
11. 생성 파일 확인
12. 남은 문제 보고
```

가능하면 한 번에 전체 프로젝트를 수정하지 않는다.

큰 작업은 다음처럼 나눈다.

```text
조사
→ 최소 수정
→ HLS 검증
→ IP Export
→ 최소 Vivado 통합
→ 전체 통합
→ Bitstream
→ Software 제어
→ 성능 최적화
```

---

## 31. Codex 응답 규칙

응답에는 다음을 포함한다.

```text
현재 확인한 사실
확인하지 못한 내용
수정한 파일
생성한 파일
실행한 명령
명령 결과
통과한 단계
실패한 단계
다음 작업
```

불확실성은 다음과 같이 표시한다.

```text
확인 완료
추정
확인 필요
현재 자료에서 찾을 수 없음
```

근거가 없는 성능 수치나 자원 사용량을 만들지 않는다.

---

## 32. 처음 수행할 작업

현재 프로젝트에서 가장 먼저 수행할 작업은 전체 코드 수정이 아니라
7종 HLS IP의 현재 상태 조사다.

다음을 수행한다.

1. 7개 HLS 소스의 실제 경로를 찾는다.
2. 각 파일의 top function을 확인한다.
3. 각 tensor shape를 확인한다.
4. 각 interface pragma를 확인한다.
5. BRAM, AXI4 Master, AXI4-Lite, AXI4-Stream 여부를 구분한다.
6. 각 HLS solution과 `csynth.rpt`를 찾는다.
7. 각 Export IP와 `component.xml`을 찾는다.
8. 각 IP의 실제 VLNV를 확인한다.
9. model.6 구조와 shape가 맞지 않는 부분을 찾는다.
10. Vivado Block Design 연결을 막는 문제를 정리한다.
11. 결과를 다음 문서에 기록한다.

```text
docs/current_ip_audit.md
```

이번 조사 단계에서는 사용자 승인 없이 HLS 소스나 Vivado 프로젝트를 수정하지 않는다.

---

## 33. 최소 Vivado 통합 목표

전체 model.6 통합 전에 Conv1×1 IP 하나를 이용한 최소 설계를 만든다.

목표:

```text
Kria KV260
Zynq UltraScale+ MPSoC
100 MHz PL Clock
Processor System Reset
Conv1×1 HLS IP
Control interface
Data memory interface
Validate Design
Synthesis
Implementation
Bitstream
```

최소 설계가 통과한 연결 방식을
다른 6종 IP 통합의 기준 구조로 사용한다.

---

## 34. 최종 완료 조건

프로젝트의 1차 완료 조건:

```text
7종 HLS IP의 상태 조사 완료
model.6 데이터 흐름 문서화 완료
최소 Conv1×1 Bitstream 통과
전체 IP Block Design 생성
Validate Design 통과
Synthesis 통과
Implementation 통과
DRC Error 0
Bitstream 생성
XSA 또는 Bitstream/HWH Export
Resource Utilization 저장
Timing Summary 저장
```

프로젝트의 최종 완료 조건:

```text
KV260 보드에서 model.6 실행
입력/가중치/출력 전달
IP start/done 제어
Python 또는 C Golden Model과 출력 비교
정확도 검증
실행 시간 측정
FPS 계산
Software 약 6 FPS 대비 성능 비교
최종 15 FPS 목표 달성 여부 분석
```

15 FPS를 달성하지 못하더라도 실제 측정 결과를 숨기지 않는다.

병목을 다음 항목으로 구분하여 보고한다.

```text
Computation
DDR bandwidth
BRAM bandwidth
AXI transaction overhead
Control overhead
Floating-point BN/SiLU
Pipeline II
Clock timing
Resource limitation
Routing congestion
```
