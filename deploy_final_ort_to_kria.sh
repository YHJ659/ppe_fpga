#!/usr/bin/env bash
set -euo pipefail

TARGET=${TARGET:-ubuntu@192.168.1.151}
REMOTE=${REMOTE:-/home/ubuntu/ppe_fpga_hybrid}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ssh "$TARGET" "mkdir -p $REMOTE/sw $REMOTE/tools $REMOTE/models/onnx"
scp "$ROOT/webcam_infer.py" "$TARGET:$REMOTE/webcam_infer.py"
scp "$ROOT/sw/final_hybrid_pipeline.py" "$ROOT/sw/ort_hybrid_pipeline.py" \
    "$TARGET:$REMOTE/sw/"
scp "$ROOT/tools/benchmark_backends.py" "$ROOT/tools/collect_int8_calibration.py" \
    "$ROOT/tools/quantize_split_int8.py" "$TARGET:$REMOTE/tools/"
scp "$ROOT/models/onnx/pre_model6.onnx" "$ROOT/models/onnx/post_model6.onnx" \
    "$ROOT/models/onnx/split_metadata.json" "$TARGET:$REMOTE/models/onnx/"
ssh "$TARGET" "cd $REMOTE && python3 -m py_compile webcam_infer.py sw/final_hybrid_pipeline.py sw/ort_hybrid_pipeline.py && test -c /dev/model6_dma"
echo "ORT final software deployed; hardware/kernel were not changed."
