#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BRANCH_ROOT="${PPE_BRANCH_ROOT:-$ROOT/branches}"
BRANCH="$BRANCH_ROOT/HyunJun_Yoo"
SHIM="$HERE/shim"
CXX="${CXX:-/usr/bin/g++}"

if [[ ! -x "$CXX" ]]; then
  echo "ERROR: C++ compiler not found: $CXX" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d /private/tmp/ppe-hyunjun-regression.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

build() {
  local output="$1"
  local dut="$2"
  local tb="$3"
  "$CXX" -std=c++17 -O2 -Wno-unknown-pragmas -I"$SHIM" \
    "$dut" "$tb" -o "$TMP_DIR/$output"
}

run_in() {
  local name="$1"
  local directory="$2"
  echo "[UNIT] $name"
  (cd "$directory" && "$TMP_DIR/$name")
}

build conv3x3 "$BRANCH/conv3x3/conv3x3.cpp" "$BRANCH/conv3x3/tb_conv3x3.cpp"
build conv1x1 "$BRANCH/conv1x1/conv1x1.cpp" "$BRANCH/conv1x1/tb_conv1x1.cpp"
build bn64 "$BRANCH/BatchNorm/bn_silu_64.cpp" "$BRANCH/BatchNorm/tb_bn_silu_64.cpp"
build bn128 "$BRANCH/BatchNorm_128/bn_silu_128.cpp" "$BRANCH/BatchNorm_128/tb_bn_silu_128.cpp"
build split "$BRANCH/Split/split_channel.cpp" "$BRANCH/Split/tb_split_channel.cpp"
build residual "$BRANCH/residual_add/residual_add.cpp" "$BRANCH/residual_add/tb_residual_add.cpp"
build concat "$BRANCH/Concat/concat_channel.cpp" "$BRANCH/Concat/tb_concat_channel.cpp"

run_in conv3x3 "$BRANCH/conv3x3"
run_in conv1x1 "$BRANCH/conv1x1"
run_in bn64 "$BRANCH/BatchNorm/bn_silu_m0cv1"
run_in bn128 "$BRANCH/BatchNorm_128/bn_silu_128cv1"
run_in split "$BRANCH/Split/split_cv1"
run_in residual "$BRANCH/residual_add/residual_m0"
run_in concat "$BRANCH/Concat/concat_c2f6"

echo "[CHAIN] binary integrity and producer/consumer consistency"
python3 "$HERE/audit_chain.py"

echo "HyunJun_Yoo host C-sim completed. This does not replace Vitis HLS co-simulation."
