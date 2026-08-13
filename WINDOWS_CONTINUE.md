# Windows에서 Codex 작업 이어가기

## 1. 저장소 받기

PowerShell 또는 Git Bash에서 다음을 실행합니다.

```powershell
git clone --branch Giho_Sung https://github.com/YHJ659/ppe_fpga.git
cd ppe_fpga
```

## 2. Codex에 프로젝트 문맥 전달

Windows Codex에서 clone한 `ppe_fpga` 폴더를 연 뒤 다음처럼 요청합니다.

```text
README.md, WORK_INDEX.md,
docs/codex/AGENTS_ubuntu_project.md,
docs/codex/CODEX_FPGA_MASTER_HANDOFF_20260812.md를 읽고
성기호의 model.6 FPGA 작업 완료 범위와 남은 검증을 요약해줘.
```

## 3. 환경 차이

- 원래 FPGA 작업 환경은 Ubuntu 22.04와 Vivado/Vitis 2022.2입니다.
- 문서의 `/home/sogang/ppe_fpga_ho` 경로는 Windows clone 경로로 바꿔야 합니다.
- Vivado/Vitis 자동 생성물은 GitHub에 포함하지 않았으므로 2022.2에서 재생성합니다.
- 실제 KV260 제어는 SSH로 보드에 접속하거나 Ubuntu/WSL 환경을 사용하는 편이
  편리합니다.

## 4. 중요한 시작 문서

1. `WORK_INDEX.md`
2. `docs/model6/model6_hardware_summary.md`
3. `docs/codex/CODEX_FPGA_MASTER_HANDOFF_20260812.md`
4. `docs/model6/self_intro_project_challenges_20260812.md`
5. `presentation/PPE_B팀_성기호_최종본_슬라이드3교체.pptx`

## 5. GitHub에 없는 로컬 생성물

Vivado cache/runs, Vitis BSP와 object 파일은 저장소에서 제외했습니다. 원본 PC를
정리하기 전에는 `/home/sogang/ppe_fpga_ho` 전체를 외장 저장장치에도 한 번
백업하는 것을 권장합니다.
