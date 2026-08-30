# piki 워크스페이스 (로비) 규칙

정본은 `TeamPiKi/infra workspace/piki-workspace.md` 이고 `install.sh` 가 워크스페이스 루트의 `.claude/rules/` 로 설치한다. 루트 `piki/` 는 코드가 없는 얇은 git repo(로비)라 작업하는 자리가 아니다. 로비에서 대상을 고르고 워크트리로 들어가 작업한다. 한 번에 한 곳만 쓴다.

## 지도

| repo | 역할 | base |
|---|---|---|
| `core` | 백엔드 API (Kotlin·Spring) | `dev` |
| `client` | 앱 클라이언트 | `dev` |
| `extractor` | 상품 추출 서비스 | `main` |
| `renderer` | 헤드리스 렌더링 서비스 | `main` |
| `infra` | 공통 자산 정본 (스킬·훅·규약·계약) | `main` |

base 는 참고용이다. 스킬은 `origin/dev` 존재 여부로 매번 판정하므로 이 표가 낡아도 동작은 어긋나지 않는다.

## 로비 규칙

- **작업 전에 들어간다.** 편집·커밋·PR·테스트 전에 대상 repo 의 워크트리로 hop 한다. 로비에서 한 편집은 어느 repo 에도 속하지 않는다.
- **`EnterWorktree` 는 `path=` 만 쓴다.** `name=` 은 루트 repo 자신에 워크트리를 만들어 버린다. 새 자리가 필요하면 `git -C <repo> worktree add .claude/worktrees/<slug> -b <branch> origin/<base>` 로 만든 뒤 `path=` 로 들어간다.
- **대상은 linked worktree 뿐이다.** repo 의 메인 체크아웃(`piki/core` 등)은 진입이 거부된다(실측).
- **다른 repo 로 갈 땐 로비를 거친다.** 워크트리에서 다른 repo 로 직행은 거부된다(기준이 현재 워크트리의 소유 repo). `ExitWorktree(action:"keep")` 로 로비에 돌아온 뒤 재진입한다.
- **이전 워크트리는 read-only 로 둔다.** `Edit` 은 세션이 선 워크트리 밖을 거부하지만 Bash 는 막지 않는다. 그 차이를 우회 수단으로 쓰지 않는다. 고쳐야 하면 그리로 hop 한다.
- **루트에서 빌드·테스트를 돌리지 않는다.** hop 후에 돌린다.
- **다른 세션이 열어 둔 워크트리는 경고를 보고 고른다.** 후보 열거(`$HOME/.claude/scripts/piki-worktrees.sh`)가 `open` 으로 표시할 뿐, 제외하지는 않는다. 같은 파일을 동시에 고칠 위험을 감수할지는 사용자가 정한다.
- **자기가 만들지 않은 워크트리는 지우지 않는다.** `ExitWorktree(action:"remove")` 의 비소유자 거부가 곧 "내 자리가 아니다" 신호다. `keep` 으로 나오고 사용자에게 알린다.

## hop 후에 따라오는 것과 아닌 것

| 항목 | hop 후 |
|---|---|
| `CLAUDE.md`·`.claude/rules/` | 그 워크트리 것으로 따라온다 |
| 슬래시 명령 목록 | 세션 시작 위치(루트) 기준 그대로 |
| 프로젝트 `settings.json` 훅 | 적용되지 않는다. repo 의 가드 훅은 사람이 지킨다 |
| 자동 메모리 위치 | 루트 기준 고정 |
| 공통 자산(스킬·규약·계약) | `ensure-assets` 훅이 hop 직후 채운다 |

## 크로스 repo

계약·공통 자산이 걸린 변경은 **infra 정본을 먼저 머지**하고 소비 repo 를 뒤에 올린다. 순서가 뒤집히면 소비 repo 의 CI 가 아직 없는 정본을 대조해 깨진다.
