#!/usr/bin/env bash
set -euo pipefail

# Software-only runtime setup; FPGA and kernel artifacts are untouched.
sudo apt-get update
sudo apt-get install -y python3-pip python3-dev build-essential cmake git
python3 -m pip install --user --upgrade onnx onnxruntime
python3 - <<'PY'
import onnx, onnxruntime
print("onnx", onnx.__version__)
print("onnxruntime", onnxruntime.__version__)
print("providers", onnxruntime.get_available_providers())
PY
