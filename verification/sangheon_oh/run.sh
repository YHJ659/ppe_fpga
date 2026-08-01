#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BRANCH_ROOT="${PPE_BRANCH_ROOT:-$ROOT/branches}"
STARTER="$BRANCH_ROOT/Sangheon_Oh/ppe_yolo_verification_starter"

if [[ -n "${IVERILOG:-}" ]]; then
  IV="$IVERILOG"
elif command -v iverilog >/dev/null 2>&1; then
  IV="$(command -v iverilog)"
elif [[ -x /private/tmp/iverilog-v12-audit/icarus-verilog/13.0/bin/iverilog ]]; then
  IV=/private/tmp/iverilog-v12-audit/icarus-verilog/13.0/bin/iverilog
else
  echo "ERROR: iverilog not found. Install Icarus Verilog 13 or set IVERILOG." >&2
  exit 2
fi
VVP_BIN="${VVP:-$(dirname "$IV")/vvp}"

TMP_DIR="$(mktemp -d /private/tmp/ppe-sangheon-regression.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[STRICT] educational mac_core accumulator and protocol"
"$IV" -g2012 -s tb_mac_core_strict -o "$TMP_DIR/mac" \
  "$HERE/tb_mac_core_strict.sv" "$STARTER/rtl/mac_core.sv"
"$VVP_BIN" "$TMP_DIR/mac"

echo "[STRICT] mock control exact-cycle protocol"
"$IV" -g2012 -s tb_control_protocol_strict -o "$TMP_DIR/control" \
  "$HERE/tb_control_protocol_strict.sv" "$STARTER/rtl/ppe_control_mock.sv"
"$VVP_BIN" "$TMP_DIR/control"

echo "[KNOWN ISSUES] detection comparator adversarial cases"
python3 "$HERE/probe_comparator.py"

echo "Sangheon_Oh starter regression completed. These mock RTL tests are verification infrastructure, not PPE DUT sign-off."
