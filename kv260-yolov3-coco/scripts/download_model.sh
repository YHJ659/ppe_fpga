#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ASSET_DIR="${REPO_ROOT}/assets"
readonly MODEL_ROOT="${REPO_ROOT}/models"
readonly MODEL_DIR="${MODEL_ROOT}/yolov3_coco_416_tf2"
readonly ARCHIVE_NAME="yolov3_coco_416_tf2-zcu102_zcu104_kv260-r2.5.0.tar.gz"
readonly ARCHIVE_PATH="${ASSET_DIR}/${ARCHIVE_NAME}"
readonly ARCHIVE_URL="https://www.xilinx.com/bin/public/openDownload?filename=${ARCHIVE_NAME}"

readonly ARCHIVE_MD5="ae417567b1462c7d5b6708285643f140"
readonly ARCHIVE_SHA256="b566a6a4bad3d552d819c3c4c9968f4a95bb05b4a71e34c6583b878137ecec0b"
readonly XMODEL_SHA256="315a0c0ff6d901b0c79d63068aa9c70b26f45521ff4e11687fd39586cb111cb8"
readonly PROTOTXT_SHA256="65fc79e2f181d1ecbd7f2e2e7a0b1b8c3adceb929ca6e461caae9c01b6418c48"

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

md5_of() {
  md5sum "$1" | awk '{print $1}'
}

mkdir -p "${ASSET_DIR}" "${MODEL_ROOT}"

archive_is_valid=false
if [[ -f "${ARCHIVE_PATH}" ]] && \
   [[ "$(md5_of "${ARCHIVE_PATH}")" == "${ARCHIVE_MD5}" ]] && \
   [[ "$(sha256_of "${ARCHIVE_PATH}")" == "${ARCHIVE_SHA256}" ]]; then
  archive_is_valid=true
fi

if [[ "${archive_is_valid}" != true ]]; then
  echo "Downloading the official Vitis AI 2.5 KV260 YOLOv3 archive..."
  curl -L --fail --show-error --retry 3 \
    --output "${ARCHIVE_PATH}.part" \
    "${ARCHIVE_URL}"

  if [[ "$(md5_of "${ARCHIVE_PATH}.part")" != "${ARCHIVE_MD5}" ]] || \
     [[ "$(sha256_of "${ARCHIVE_PATH}.part")" != "${ARCHIVE_SHA256}" ]]; then
    echo "Downloaded archive checksum mismatch" >&2
    exit 1
  fi
  mv -f "${ARCHIVE_PATH}.part" "${ARCHIVE_PATH}"
else
  echo "Using the verified archive already in ${ASSET_DIR}"
fi

echo "Extracting model files..."
tar -xzf "${ARCHIVE_PATH}" -C "${MODEL_ROOT}"

readonly XMODEL="${MODEL_DIR}/yolov3_coco_416_tf2.xmodel"
readonly PROTOTXT="${MODEL_DIR}/yolov3_coco_416_tf2.prototxt"

if [[ ! -f "${XMODEL}" || ! -f "${PROTOTXT}" ]]; then
  echo "Expected xmodel/prototxt files were not found after extraction" >&2
  exit 1
fi

if [[ "$(sha256_of "${XMODEL}")" != "${XMODEL_SHA256}" ]]; then
  echo "xmodel SHA-256 mismatch" >&2
  exit 1
fi

if [[ "$(sha256_of "${PROTOTXT}")" != "${PROTOTXT_SHA256}" ]]; then
  echo "prototxt SHA-256 mismatch" >&2
  exit 1
fi

echo "Model verification PASS"
echo "xmodel: ${XMODEL}"
echo "prototxt: ${PROTOTXT}"
