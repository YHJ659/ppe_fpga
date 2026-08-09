#!/usr/bin/env bash
set -euo pipefail

BITFILE=${BITFILE:-"$HOME/ppe_fpga_hybrid/hw/ppe_fpga_yoo_3.bit"}
test -f "$BITFILE"
python3 - "$BITFILE" <<'PY'
import sys
from pynq import Bitstream
Bitstream(sys.argv[1]).download()
PY
test "$(cat /sys/class/fpga_manager/fpga0/state)" = "operating"
test -c /dev/model6_dma
echo "FPGA operating and /dev/model6_dma present"
