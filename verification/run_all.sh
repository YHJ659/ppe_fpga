#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for branch in Giho_Sung HyunJun_Yoo Sangheon_Oh Wanmin_Kim Jungwon_Park; do
  path="${PPE_BRANCH_ROOT:-$HERE/../branches}/$branch"
  if [[ ! -d "$path" ]]; then
    echo "ERROR: missing branch worktree: $path" >&2
    echo "Set PPE_BRANCH_ROOT to the directory containing all five worktrees." >&2
    exit 2
  fi
done

echo "============================================================"
echo "Giho_Sung: strict RTL regression"
echo "============================================================"
"$HERE/giho_sung/run.sh"

echo
echo "============================================================"
echo "HyunJun_Yoo: seven host C-sim units and chain audit"
echo "============================================================"
"$HERE/hyunjun_yoo/run.sh"

echo
echo "============================================================"
echo "Sangheon_Oh: verification-starter strict regression"
echo "============================================================"
"$HERE/sangheon_oh/run.sh"

echo
echo "============================================================"
echo "Wanmin_Kim and Jungwon_Park"
echo "============================================================"
echo "SKIP Wanmin_Kim: core datapath/I-O/weights/activation contract is incomplete."
echo "SKIP Jungwon_Park: webcam application is not a hardware DUT and models/best.pt is absent."

echo
echo "ALL EXECUTABLE REGRESSIONS COMPLETED"
echo "A completed runner is not a five-branch sign-off; see BRANCH_AUDIT.md for blockers."
