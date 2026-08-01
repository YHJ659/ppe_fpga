#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0 [FRAME_COUNT]" >&2
  exit 2
fi

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly IMAGE="kv260/yolov3-webcam:2.5"
readonly MODEL_HOST="${REPO_ROOT}/models/yolov3_coco_416_tf2/yolov3_coco_416_tf2.xmodel"
readonly MODEL_CONFIG_HOST="${MODEL_HOST%.xmodel}.prototxt"
readonly MODEL_CONTAINER="/work/models/yolov3_coco_416_tf2/yolov3_coco_416_tf2.xmodel"
readonly CAMERA_DEVICE="${CAMERA_DEVICE:-/dev/video0}"
readonly FRAME_COUNT="${1:-60}"

if ! [[ "${FRAME_COUNT}" =~ ^[1-9][0-9]*$ ]] || \
   (( FRAME_COUNT > 100000 )); then
  echo "FRAME_COUNT must be an integer from 1 to 100000" >&2
  exit 2
fi

if [[ ! -c "${CAMERA_DEVICE}" ]]; then
  echo "Camera device is missing: ${CAMERA_DEVICE}" >&2
  exit 1
fi

if [[ ! -f "${MODEL_HOST}" || ! -f "${MODEL_CONFIG_HOST}" ]]; then
  echo "The verified xmodel/prototxt pair is missing" >&2
  echo "Run: ${REPO_ROOT}/scripts/download_model.sh" >&2
  exit 1
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Docker image is missing: ${IMAGE}" >&2
  echo "Build: sudo docker build -t ${IMAGE} ${REPO_ROOT}/docker" >&2
  exit 1
fi

active_slot="$(
  xmutil listapps |
    awk '$1 == "kv260-benchmark-b4096" {gsub(",", "", $NF); print $NF}'
)"
if [[ "${active_slot}" != "0" ]]; then
  echo "kv260-benchmark-b4096 is not active in slot 0" >&2
  echo "Cold-reboot, then run scripts/load_b4096_after_reboot.sh" >&2
  exit 1
fi

if [[ ! -f /etc/vart.conf ]] || \
   ! grep -Fq "kv260-benchmark-b4096.xclbin" /etc/vart.conf; then
  echo "/etc/vart.conf does not select the B4096 xclbin" >&2
  exit 1
fi

readonly RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly RESULT_NAME="webcam-b4096-${RUN_STAMP}"
readonly RESULT_HOST="${REPO_ROOT}/results/${RESULT_NAME}"
readonly RESULT_CONTAINER="/work/results/${RESULT_NAME}"
readonly TIMEOUT_SECONDS=$((FRAME_COUNT / 5 + 60))
readonly RESULT_OWNER="${SUDO_USER:-ubuntu}"

install -d -m 0755 "${RESULT_HOST}"

docker run --rm --privileged --net=host \
  -v /dev:/dev \
  -v /sys:/sys \
  -v /run:/run \
  -v /tmp:/tmp \
  -v /etc/vart.conf:/etc/vart.conf:ro \
  -v /lib/firmware/xilinx:/lib/firmware/xilinx:ro \
  -v "${REPO_ROOT}:/work" \
  "${IMAGE}" \
  timeout --signal=TERM --kill-after=5s "${TIMEOUT_SECONDS}s" \
  webcam_yolov3 \
  "${MODEL_CONTAINER}" \
  "${CAMERA_DEVICE}" \
  "${FRAME_COUNT}" \
  "${RESULT_CONTAINER}" \
  2>&1 | tee "${RESULT_HOST}/run.log"

if id "${RESULT_OWNER}" >/dev/null 2>&1; then
  chown -R "${RESULT_OWNER}:$(id -gn "${RESULT_OWNER}")" "${RESULT_HOST}"
fi

echo "Evidence saved to ${RESULT_HOST}"
echo "Annotated image: ${RESULT_HOST}/best_annotated.jpg"
