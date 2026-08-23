# piki 워크스페이스 (로비) 규칙

이 문서는 **워크스페이스 루트에서 시작한 세션**에만 설치된다. 정본은 `TeamPiKi/infra workspace/piki-workspace.md` 이고 `install.sh` 가 매 세션 시작에 루트 `.claude/rules/` 로 갱신한다.

## 원칙

`piki/` 는 코드가 없는 **얇은 git repo(워크스페이스)** 이고, 세션은 여기서 시작한다. 루트는 로비일 뿐이라 작업하는 자리가 아니다. 로비에서 후보를 고르고 `EnterWorktree(path=...)` 로 nested repo 의 워크트리에 들어가 작업한다. 다른 repo 로 옮길 땐 `ExitWorktree(action:"keep")` 로 로비에 돌아온 뒤 다시 들어간다. **한 번에 한 곳만 쓴다.**

## 지도

| repo | 역할 | base |
|---|---|---|
| `core` | 백엔드 API (Kotlin·Spring) | `dev` |
| `client` | 앱 클라이언트 | `dev` |
| `extractor` | 상품 추출 서비스 | `main` |
| `renderer` | 헤드리스 렌더링 서비스 | `main` |
| `infra` | 공통 자산·배포 정본 (스킬·훅·규약·계약) | `main` |

base 는 참고용이다. 스킬은 `origin/dev` 존재 여부로 매번 판정하므로 이 표가 낡아도 동작은 어긋나지 않는다.

## 로비 규칙

- **작업 전에 들어간다.** 파일을 고치거나 커밋·PR·테스트를 하기 전에 대상 repo 의 워크트리로 hop 한다. 로비에서 한 편집은 어느 repo 에도 속하지 않는다.
- **`EnterWorktree` 는 `path=` 만 쓴다.** `name=` 은 루트 repo(워크스페이스) 자신에 워크트리를 만들어 버린다. 새 작업 공간이 필요하면 `git -C <repo> worktree add .claude/worktrees/<slug> -b <branch> origin/<base>` 로 만든 뒤 `path=` 로 들어간다.
- **대상은 linked worktree 뿐이다.** repo 의 메인 체크아웃(`piki/core` 등)은 진입이 거부된다(실측).
- **다른 repo 로 갈 땐 반드시 로비를 거친다.** 워크트리 안에서 다른 repo 로 직행하면 거부된다. 기준이 현재 워크트리의 소유 repo 이기 때문이다.
- **다른 워크트리의 파일을 Bash 로 고치지 않는다.** `Edit` 은 세션이 선 워크트리 밖을 거부하지만 Bash 는 막지 않는다. 그 차이를 우회 수단으로 쓰지 않는다. 고쳐야 하면 그 워크트리로 hop 한다.
- **루트에서 빌드·테스트를 돌리지 않는다.** hop 후에 돌린다.
- **다른 세션이 열려 있는 워크트리에는 들어가지 않는다.** 두 세션이 같은 파일을 고치게 된다. 후보 열거(`~/.claude/scripts/piki-worktrees.sh`)가 "열림" 으로 표시한다.

## 알아둘 차이 (hop 후에 무엇이 따라오고 무엇이 안 따라오는가)

| 항목 | hop 후 |
|---|---|
| `CLAUDE.md`·`.claude/rules/` | 그 워크트리 것으로 따라온다 |
| 슬래시 명령 목록 | **세션 시작 위치(루트) 기준 그대로**. 루트에 설치된 사본이 실행된다 |
| 프로젝트 `settings.json` 훅 | **적용되지 않는다.** repo 의 가드 훅(예: core 의 `.kt` null 비교 차단)은 hop 후 걸리지 않으므로 그 규약은 사람이 지켜야 한다 |
| 자동 메모리 위치 | 루트 기준 고정 |
| 공통 자산(스킬·규약·계약) | `ensure-assets` 훅이 hop 직후 그 워크트리에 채운다 |

## 정리

작업이 끝나 워크트리를 지울 때, **자기가 만들지 않은 워크트리는 지우지 않는다**. 이 세션이 `EnterWorktree` 로 만든 것이 아니면 `ExitWorktree(action:"remove")` 가 비소유자로 거부하는데, 그것이 곧 "내 것이 아니다" 라는 신호다. 그 경우 `keep` 으로 나오고 사용자에게 알린다.
