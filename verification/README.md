# PPE FPGA 브랜치 검증 작업공간

다섯 팀원 브랜치를 같은 커밋으로 고정해 감사하고, 지금 실행할 수 있는 테스트만 자동 회귀로 묶은 폴더입니다. 원본 브랜치는 수정하지 않습니다.

## 결론 먼저

- 지금 테스트할 수 있음: `Giho_Sung`의 기본 8×8 단일채널 RTL, `HyunJun_Yoo`의 7개 개별 HLS C++ 커널, `Sangheon_Oh`의 검증용 mock/scaffold.
- 설계 보완 전 전체 테스트를 만들면 안 됨: `HyunJun_Yoo`의 model.6 전체 C2f, `Wanmin_Kim`의 C2f HLS 초안.
- 하드웨어 TB 대상이 아님: `Jungwon_Park`의 웹캠 Python 앱. 먼저 모델 파일과 사람별 PPE 판정 정책이 필요합니다.

상세 근거와 팀원별 요청사항은 [BRANCH_AUDIT.md](BRANCH_AUDIT.md), 실제 실행 결과는 [AUDIT_RESULTS.md](AUDIT_RESULTS.md)에 있습니다.

## 실행

필요 도구:

- Icarus Verilog 13.x (`iverilog`, `vvp`)
- `g++` (C++17)
- Python 3

다섯 worktree가 이 폴더의 상위 `branches/`에 있으면:

```bash
./verification/run_all.sh
```

다른 위치라면:

```bash
PPE_BRANCH_ROOT=/absolute/path/to/branches ./verification/run_all.sh
```

Icarus가 PATH에 없으면:

```bash
IVERILOG=/absolute/path/to/iverilog \
VVP=/absolute/path/to/vvp \
./verification/run_all.sh
```

`KNOWN ISSUE` 테스트는 현재 결함을 재현하기 위한 것입니다. 정상 계약 테스트와 분리되어 있어, 결함이 재현되어도 전체 runner는 계속 진행합니다.

## 폴더 구성

```text
verification/
├── BRANCH_AUDIT.md
├── AUDIT_RESULTS.md
├── run_all.sh
├── giho_sung/       # 새 strict SystemVerilog scoreboard 4개
├── hyunjun_yoo/     # 7개 기존 C++ TB runner, host shim, chain audit
└── sangheon_oh/     # 새 strict mock RTL TB와 comparator 반례
```

`hyunjun_yoo/shim`은 Mac에서 제출 C++의 기능을 재생하기 위한 signed fixed-width host shim입니다. Vitis HLS의 `ap_int`, 합성 결과, cycle/timing을 증명하지 않습니다. 최종 sign-off에는 Vitis HLS 2022.2 C-sim/C-synth/Co-sim이 필요합니다.

## 고정한 브랜치 스냅샷

| 브랜치 | 커밋 |
|---|---|
| `Sangheon_Oh` | `7443a3d009bc38f9fe824c8624596fbcd324f551` |
| `HyunJun_Yoo` | `ec92219a8f06743254bd1f113bc4eb8eef813e35` |
| `Giho_Sung` | `f7bc21dd145ed3e03896c73219c756d94c95c85a` |
| `Wanmin_Kim` | `1941732dd7693937958cf5d38afe5b389236ba80` |
| `Jungwon_Park` | `393862b6d161317af4885f84804351db174b6d65` |

검증 재실행 전에 remote HEAD가 위 SHA와 달라졌는지 먼저 확인해야 합니다.
