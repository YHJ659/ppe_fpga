#!/usr/bin/env bash
set -euo pipefail

# The 2022.1 KV260 stack can become unstable after repeated accelerator
# unload/load cycles.  This script therefore requires an explicit assertion
# that the board has just been rebooted.

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0 --after-reboot" >&2
  exit 2
fi

listapps="$(xmutil listapps)"
active_slot="$(
  awk '$1 == "kv260-benchmark-b4096" {gsub(",", "", $NF); print $NF}' \
    <<<"${listapps}"
)"

if [[ "${active_slot}" == "0" ]] && \
   [[ -f /etc/vart.conf ]] && \
   grep -Fq "kv260-benchmark-b4096.xclbin" /etc/vart.conf; then
  echo "kv260-benchmark-b4096 is already active in slot 0"
  exit 0
fi

if [[ "${1:-}" != "--after-reboot" ]]; then
  echo "Cold-reboot the board first, reconnect, then run:" >&2
  echo "  sudo $0 --after-reboot" >&2
  exit 2
fi

if ! awk '$1 == "kv260-benchmark-b4096" {found=1} END {exit !found}' \
     <<<"${listapps}"; then
  echo "The kv260-benchmark-b4096 accelerator package is not installed" >&2
  echo "Install: sudo apt install xlnx-firmware-kv260-benchmark-b4096" >&2
  exit 1
fi

echo "Disabling the desktop and unloading the boot accelerator..."
xmutil desktop_disable

active_accelerator="$(
  awk 'NR > 2 {slot=$NF; gsub(",", "", slot); if (slot != "-1") print $1}' \
    <<<"${listapps}"
)"
if [[ -n "${active_accelerator}" ]]; then
  xmutil unloadapp
  sleep 10
fi

if [[ -e /etc/vart.conf ]]; then
  backup="/etc/vart.conf.before-b4096.$(date -u +%Y%m%dT%H%M%SZ)"
  mv /etc/vart.conf "${backup}"
  echo "Backed up stale VART configuration to ${backup}"
fi

echo "Loading kv260-benchmark-b4096 once..."
xmutil loadapp kv260-benchmark-b4096
sleep 15

listapps="$(xmutil listapps)"
active_slot="$(
  awk '$1 == "kv260-benchmark-b4096" {gsub(",", "", $NF); print $NF}' \
    <<<"${listapps}"
)"
if [[ "${active_slot}" != "0" ]]; then
  echo "B4096 accelerator did not become active in slot 0" >&2
  exit 1
fi

if [[ ! -f /etc/vart.conf ]] || \
   ! grep -Fq "kv260-benchmark-b4096.xclbin" /etc/vart.conf; then
  echo "B4096 VART configuration was not created" >&2
  exit 1
fi

echo "B4096 overlay preparation PASS"
cat /etc/vart.conf
