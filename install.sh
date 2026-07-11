#!/usr/bin/env bash
#
# infra 공통 자산 설치기 (정본)
#
# 어떤 자산을 어디에 어떤 권한으로 설치하는지, 실패를 어떻게 다루는지는 이 파일만 안다.
# 소비 repo 의 SessionStart 는 이 스크립트를 원격 fetch 해 실행하는 한 줄 부트스트랩만 갖고,
# 소비 repo 에 남는 상수는 repo 좌표(TeamPiKi/infra) 1개뿐이다. 자산이 늘거나
# 설치 로직이 바뀌어도 소비 repo 는 무변경이다.
#
# 실행 모드 (origin 원격으로 자동 판별):
#   - infra 자신 안에서 실행 -> working tree 의 로컬 자산을 설치 (수정 중인 자산 즉시 반영)
#   - 소비 repo 에서 실행(부트스트랩 경유) -> 원격 정본을 fetch 해 설치
#
# 실패 안전: fetch 실패(오프라인·권한 없음)나 빈 응답이면 해당 자산을 건너뛰고 기존
# 설치본을 유지한다. 항상 exit 0 (SessionStart 를 깨뜨리지 않는다).

set -uo pipefail

INFRA_REPO="TeamPiKi/infra"

hooks_dir="$(git rev-parse --git-common-dir 2>/dev/null)/hooks"
[ -d "$hooks_dir" ] || exit 0

if git remote get-url origin 2>/dev/null | grep -q "TeamPiKi/infra"; then
  self=1   # infra 자신 안에서 실행 (SSOT repo)
  get() { cat "$(git rev-parse --show-toplevel)/$1" 2>/dev/null; }
else
  self=0   # 소비 repo 에서 실행 (부트스트랩 경유)
  get() { gh api -H "Accept: application/vnd.github.raw" "repos/$INFRA_REPO/contents/$1" 2>/dev/null; }
fi

# $1=자산 경로(repo 내) $2=설치 대상(절대경로) $3=권한 mode $4=검증 유형(sh|md)
# 빈 응답(fetch 실패·권한 없음)이면 어느 유형이든 스킵해 기존 설치본을 유지한다 (가용성 가드).
# 그 위에 유형별 검증을 얹는다 (validate_asset).
install_asset() {
  local tmp
  tmp=$(mktemp)
  if get "$1" >"$tmp" && [ -s "$tmp" ] && validate_asset "$tmp" "$4"; then
    install -m "$3" "$tmp" "$2"
  fi
  rm -f "$tmp"
}

# 자산 유형별 검증. 새 유형이 생기면 여기 case 를 늘린다.
#   sh: bash -n 으로 문법을 확인한다. 문법 깨진 정본이 main 에 잠깐 올라가도 소비 repo 의
#       훅을 깨뜨리지 않게 설치를 스킵하고 기존 설치본을 유지한다.
#   md: 셸이 아니라 bash -n 이 오히려 실패하므로 적용하지 않는다. 비어있지 않음([ -s ])만 보며,
#       그건 install_asset 이 이미 확인했다.
validate_asset() {
  case "$2" in
    sh) bash -n "$1" 2>/dev/null ;;
    md) true ;;
    *)  false ;;   # 알 수 없는 유형은 설치하지 않는다 (안전)
  esac
}

# ---- 자산 목록 (여기만 고치면 모든 소비 repo 에 반영된다) ----

# git hooks — 비버전 영역(.git/hooks)에 설치되므로 self 모드(infra 자신)에서도 무해하다.
install_asset hooks/commit-msg "$hooks_dir/commit-msg" 755 sh

# 개발 스킬(slash command) — 소비 repo 의 .claude/commands 에 설치한다.
# self 모드(infra 자신)에서는 설치하지 않는다: 스킬은 버전 영역(.claude/commands)에 들어가
# infra working tree 에 untracked 파일을 남기지만, 훅(.git/hooks)은 비버전이라 그 문제가 없다.
# 스킬은 소비 repo 를 위한 자산이고 infra 는 그 생산자다 — infra 자신은 소비자가 아니라 스킵한다.
# gc 는 commit 의 별칭이라 같은 정본을 두 이름으로 설치한다 (정본은 하나, 표면만 둘).
if [ "$self" = 0 ]; then
  cmd_dir="$(git rev-parse --show-toplevel)/.claude/commands"
  mkdir -p "$cmd_dir"
  install_asset skills/commit.md     "$cmd_dir/commit.md"     644 md
  install_asset skills/commit.md     "$cmd_dir/gc.md"         644 md
  install_asset skills/coderabbit.md "$cmd_dir/coderabbit.md" 644 md
fi

exit 0
