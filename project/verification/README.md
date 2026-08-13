# Model.6 Verification Data

FPGA 출력과 Python/C++ Golden Model을 비교하기 위한 입력·출력 특징맵입니다.

- `concat/y0.bin`~`y3.bin`: Concat 입력
- `concat/golden_output.bin`: 기준 출력

비교 전 dtype, scale, signedness, CHW/HWC layout과 BRAM byte/word 주소 단위를
반드시 동일하게 맞춰야 합니다.
