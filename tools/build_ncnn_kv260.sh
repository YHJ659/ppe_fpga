#!/usr/bin/env bash
set -euo pipefail

PREFIX=${PREFIX:-"$HOME/.local/ncnn"}
WORK=${WORK:-"$HOME/src/ncnn"}
if [ ! -d "$WORK/.git" ]; then
    mkdir -p "$(dirname "$WORK")"
    git clone --depth 1 https://github.com/Tencent/ncnn.git "$WORK"
fi
cmake -S "$WORK" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release \
    -DNCNN_VULKAN=OFF -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_TOOLS=ON \
    -DNCNN_BUILD_BENCHMARK=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$WORK/build" -j"$(nproc)"
cmake --install "$WORK/build"
echo "ncnn installed at $PREFIX"
