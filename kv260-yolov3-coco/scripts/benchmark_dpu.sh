#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 2
fi

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly IMAGE="kv260/yolov3-webcam:2.5"
readonly MODEL_HOST="${REPO_ROOT}/models/yolov3_coco_416_tf2/yolov3_coco_416_tf2.xmodel"
readonly MODEL_CONTAINER="/work/models/yolov3_coco_416_tf2/yolov3_coco_416_tf2.xmodel"
readonly RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly RESULT_DIR="${REPO_ROOT}/results/dpu-b4096-${RUN_STAMP}"
readonly RESULT_OWNER="${SUDO_USER:-ubuntu}"

if [[ ! -f "${MODEL_HOST}" ]]; then
  echo "Model is missing; run scripts/download_model.sh" >&2
  exit 1
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Docker image is missing; build ${REPO_ROOT}/docker first" >&2
  exit 1
fi

active_slot="$(
  xmutil listapps |
    awk '$1 == "kv260-benchmark-b4096" {gsub(",", "", $NF); print $NF}'
)"
if [[ "${active_slot}" != "0" ]]; then
  echo "kv260-benchmark-b4096 is not active in slot 0" >&2
  exit 1
fi

if [[ ! -f /etc/vart.conf ]] || \
   ! grep -Fq "kv260-benchmark-b4096.xclbin" /etc/vart.conf; then
  echo "/etc/vart.conf does not select the B4096 xclbin" >&2
  exit 1
fi

install -d -m 0755 "${RESULT_DIR}"

docker run --rm --privileged --net=host \
  -e SLEEP_MS=5000 \
  -v /dev:/dev \
  -v /sys:/sys \
  -v /run:/run \
  -v /tmp:/tmp \
  -v /etc/vart.conf:/etc/vart.conf:ro \
  -v /lib/firmware/xilinx:/lib/firmware/xilinx:ro \
  -v "${REPO_ROOT}:/work:ro" \
  "${IMAGE}" \
  timeout --signal=TERM --kill-after=5s 25s \
  xdputil benchmark "${MODEL_CONTAINER}" 1 -i 1 \
  2>&1 | tee "${RESULT_DIR}/benchmark.log"

if id "${RESULT_OWNER}" >/dev/null 2>&1; then
  chown -R "${RESULT_OWNER}:$(id -gn "${RESULT_OWNER}")" "${RESULT_DIR}"
fi

echo "Benchmark log: ${RESULT_DIR}/benchmark.log"
