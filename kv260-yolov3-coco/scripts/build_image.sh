#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run on the KV260 as root: sudo $0" >&2
  exit 2
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
  echo "Build this image on the ARM64 KV260, not on the Mac" >&2
  exit 1
fi

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly IMAGE="kv260/yolov3-webcam:2.5"

docker build -t "${IMAGE}" "${REPO_ROOT}/docker"

architecture="$(docker image inspect "${IMAGE}" --format '{{.Architecture}}')"
if [[ "${architecture}" != "arm64" ]]; then
  echo "Unexpected image architecture: ${architecture}" >&2
  exit 1
fi

missing="$(
  docker run --rm "${IMAGE}" sh -lc \
    'ldd /usr/local/bin/webcam_yolov3 | grep "not found" || true'
)"
if [[ -n "${missing}" ]]; then
  echo "Unresolved runtime libraries:" >&2
  echo "${missing}" >&2
  exit 1
fi

echo "Docker image build PASS: ${IMAGE} (${architecture})"
