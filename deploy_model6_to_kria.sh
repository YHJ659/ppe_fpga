#!/usr/bin/env bash
set -euo pipefail

TARGET=${TARGET:-ubuntu@192.168.1.151}
REMOTE_DIR=${REMOTE_DIR:-/home/ubuntu/ppe_fpga_hybrid}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROVEN_BITFILE="$SCRIPT_DIR/../ppe_fpga/model6_hw_fix/hw/ppe_fpga_yoo_fix4.bit"
PROVEN_BIT_SHA256=1231e209b6be4f6d56c8d61565d38872e97d0103bb6f17e319dcd9b0659d6f20

test -f "$PROVEN_BITFILE"
test "$(sha256sum "$PROVEN_BITFILE" | awk '{print $1}')" = "$PROVEN_BIT_SHA256"

ssh "$TARGET" "mkdir -p $REMOTE_DIR/kernel/model6_dma $REMOTE_DIR/hw $REMOTE_DIR/sw $REMOTE_DIR/tools"
scp "$SCRIPT_DIR/kernel/model6_dma/model6_dma.c" \
    "$TARGET:$REMOTE_DIR/kernel/model6_dma/model6_dma.c"
scp "$SCRIPT_DIR/hw/hw_driver.c" "$SCRIPT_DIR/hw/hw_driver.py" \
    "$TARGET:$REMOTE_DIR/hw/"
scp "$SCRIPT_DIR/webcam_infer.py" "$TARGET:$REMOTE_DIR/webcam_infer.py"
scp "$SCRIPT_DIR/sw/hybrid_pipeline.py" "$TARGET:$REMOTE_DIR/sw/hybrid_pipeline.py"
scp "$SCRIPT_DIR/tools/benchmark_backends.py" "$TARGET:$REMOTE_DIR/tools/benchmark_backends.py"
scp "$PROVEN_BITFILE" "$TARGET:$REMOTE_DIR/hw/ppe_fpga_yoo_3.bit"

ssh -tt "$TARGET" "sudo -v && REMOTE_DIR=$REMOTE_DIR bash -s" <<'REMOTE'
set -euo pipefail

cd "$REMOTE_DIR"
make -C "/lib/modules/$(uname -r)/build" \
    M="$REMOTE_DIR/kernel/model6_dma" clean
make -C "/lib/modules/$(uname -r)/build" \
    M="$REMOTE_DIR/kernel/model6_dma" modules
make -C "$REMOTE_DIR/hw" clean all

if lsmod | grep -q '^model6_dma '; then
    sudo rmmod model6_dma
fi
if lsmod | grep -q '^model6_dma '; then
    echo "ERROR: old model6_dma is still loaded"
    exit 1
fi
sudo dmesg -C
test "$(sha256sum "$REMOTE_DIR/hw/ppe_fpga_yoo_3.bit" | awk '{print $1}')" \
    = "1231e209b6be4f6d56c8d61565d38872e97d0103bb6f17e319dcd9b0659d6f20"
python3 - "$REMOTE_DIR/hw/ppe_fpga_yoo_3.bit" <<'PY'
import sys
from pynq import Bitstream
Bitstream(sys.argv[1]).download()
PY
sudo insmod "$REMOTE_DIR/kernel/model6_dma/model6_dma.ko"
sudo chmod 666 /dev/model6_dma
test -c /dev/model6_dma
test "$(modinfo -F model6_source "$REMOTE_DIR/kernel/model6_dma/model6_dma.ko")" \
    = "run_model6-fullframe-v4"
ls -l /dev/model6_dma
echo "MODEL6: deployment complete"
echo "MODEL6: run: cd $REMOTE_DIR && python3 webcam_infer.py"
REMOTE
