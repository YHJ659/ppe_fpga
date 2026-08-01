#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BRANCH_ROOT="${PPE_BRANCH_ROOT:-$ROOT/branches}"
RTL="$BRANCH_ROOT/Giho_Sung/conv_accelerator/rtl"
ORIGINAL_TB="$BRANCH_ROOT/Giho_Sung/conv_accelerator/tb"

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

if [[ -n "${VVP:-}" ]]; then
  VVP_BIN="$VVP"
else
  VVP_BIN="$(dirname "$IV")/vvp"
fi
if [[ ! -x "$VVP_BIN" ]]; then
  echo "ERROR: vvp not found beside $IV; set VVP explicitly." >&2
  exit 2
fi

TMP_DIR="$(mktemp -d /private/tmp/ppe-giho-regression.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

compile() {
  local top="$1"
  local output="$2"
  shift 2
  "$IV" -g2012 -s "$top" -o "$output" "$@"
}

echo "[P0] window_gen strict scoreboard, IMG_SIZE=8"
compile tb_window_gen_scoreboard "$TMP_DIR/window8" \
  "$HERE/tb_window_gen_scoreboard.sv" "$RTL/window_gen.sv"
"$VVP_BIN" "$TMP_DIR/window8"

echo "[P0] mac_array signed/bubble scoreboard"
compile tb_mac_array_scoreboard "$TMP_DIR/mac" \
  "$HERE/tb_mac_array_scoreboard.sv" "$RTL/mac_array.sv"
"$VVP_BIN" "$TMP_DIR/mac"

echo "[P0] controller legal-traffic contract"
compile tb_controller_contract "$TMP_DIR/controller" \
  "$HERE/tb_controller_contract.sv" "$RTL/controller.sv"
"$VVP_BIN" "$TMP_DIR/controller"

echo "[BASELINE] original conv_top golden regression"
compile tb_conv_top "$TMP_DIR/conv_top" \
  "$ORIGINAL_TB/tb_conv_top.sv" \
  "$RTL/input_buffer.sv" "$RTL/window_gen.sv" "$RTL/mac_array.sv" \
  "$RTL/output_buffer.sv" "$RTL/controller.sv" "$RTL/conv_top.sv"
"$VVP_BIN" "$TMP_DIR/conv_top" >"$TMP_DIR/conv_top.log"
grep -q 'PASS=108, FAIL=0' "$TMP_DIR/conv_top.log"
echo "PASS original conv_top: 108/108"

echo "[KNOWN ISSUE] non-power-of-two second-frame state"
compile tb_window_gen_scoreboard "$TMP_DIR/window7" \
  -Ptb_window_gen_scoreboard.IMG_SIZE=7 \
  "$HERE/tb_window_gen_scoreboard.sv" "$RTL/window_gen.sv"
if "$VVP_BIN" "$TMP_DIR/window7" >"$TMP_DIR/window7.log" 2>&1; then
  echo "FIXED: IMG_SIZE=7 consecutive-frame regression now passes"
else
  grep -m1 'FAIL frame_base=64' "$TMP_DIR/window7.log"
  echo "REPRODUCED: row counter does not wrap at IMG_SIZE-1"
fi

echo "[KNOWN ISSUE] output-buffer overflow guard"
compile tb_controller_overflow_guard "$TMP_DIR/overflow" \
  "$HERE/tb_controller_overflow_guard.sv" "$RTL/controller.sv"
if "$VVP_BIN" "$TMP_DIR/overflow" >"$TMP_DIR/overflow.log" 2>&1; then
  echo "FIXED: controller now blocks writes beyond address 35"
else
  grep -m1 'output-buffer overflow reproduced' "$TMP_DIR/overflow.log"
  echo "REPRODUCED: controller writes address 36 when a 37th valid arrives"
fi

echo "Giho_Sung regression completed. Positive contracts passed; known defects were probed separately."
