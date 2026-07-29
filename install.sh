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

# 세션 훅(UserPromptSubmit)을 사용자 settings.json 에 등록한다. 이 설치기가 **사용자 개인 설정을 고치는 유일한 지점**이라
# 가장 보수적으로 다룬다.
#   - 멱등: 같은 command 가 이미 있으면 아무것도 하지 않는다 (중복 등록 방지).
#   - 비파괴: 기존 항목을 지우거나 고치지 않는다. Orca 등 다른 훅과 그대로 공존한다.
#   - opt-out: ~/.claude/.no-session-hooks 가 있으면 등록을 건너뛴다. 훅을 원치 않는 사람이
#     매번 지우지 않아도 되게 하는 탈출구다 (파일만 지우면 설치기가 되살리지 않는다).
#   - 실패 안전: jq 가 없거나, 설정 파일이 없거나, JSON 이 깨져 있으면 손대지 않는다. 결과가
#     유효한 JSON 일 때만 원자적으로 교체하고, 원본 권한을 보존한다.
register_session_hooks() {
  local settings="$1" tmp mode
  [ -f "$HOME/.claude/.no-session-hooks" ] && return 0
  [ -f "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -e . "$settings" >/dev/null 2>&1 || return 0

  tmp=$(mktemp)
  if jq --arg emit "$HOME/.claude/hooks/session-title-emit.sh" '
        def ensure($event; $cmd):
          if [.hooks[$event][]?.hooks[]?.command] | index($cmd) then .
          else .hooks[$event] = ((.hooks[$event] // []) + [{hooks: [{type: "command", command: $cmd, timeout: 10}]}])
          end;
        .hooks = (.hooks // {})
        | ensure("UserPromptSubmit"; $emit)
     ' "$settings" >"$tmp" 2>/dev/null && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    mode=$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings" 2>/dev/null || echo 644)
    install -m "$mode" "$tmp" "$settings"
  fi
  rm -f "$tmp"
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
  install_asset skills/pr.md         "$cmd_dir/pr.md"         644 md
  install_asset skills/issue.md      "$cmd_dir/issue.md"      644 md
  install_asset skills/session-check.md "$cmd_dir/session-check.md" 644 md
  install_asset skills/session-close.md "$cmd_dir/session-close.md" 644 md

  # 규약 문서 — 소비 repo 의 .claude/rules 에 설치하고, 각 repo 의 CLAUDE.md 가 import 해 자동 로드한다.
  # 스킬(행동 절차)과 달리 이건 판단 기준이라 에이전트 컨텍스트에 상주해야 효력이 있다.
  # 언어·스택 바인딩은 각 repo 가 자기 문서에 소유하고, 여기서는 공통 원칙만 내려보낸다.
  rules_dir="$(git rev-parse --show-toplevel)/.claude/rules"
  mkdir -p "$rules_dir"
  install_asset conventions/testing.md "$rules_dir/testing-principles.md" 644 md
fi

# 세션 훅·유틸 — 설치 대상이 repo 가 아니라 사용자 홈(~/.claude)이다.
#
# 왜 홈인가: Claude Code 의 세션 훅은 사용자 전역 설정이라 repo 안에 둘 자리가 없다. 그럼에도 SSOT
# 대상인 이유는 성격이 같기 때문이다 — 여러 repo 를 오가며 쓰이고, 복제해 두면 어긋난다.
# repo 를 열 때마다(SessionStart 부트스트랩) 최신 정본으로 맞춰진다.
#
# 홈은 사용자 영역이라 repo 보다 조심해서 다룬다: 파일은 정본으로 덮되, 등록(settings.json)은
# 없을 때만 더하고 다른 훅은 건드리지 않으며, opt-out 파일이 있으면 등록을 통째로 건너뛴다.
claude_dir="$HOME/.claude"
if [ -d "$claude_dir" ]; then
  mkdir -p "$claude_dir/hooks" "$claude_dir/scripts" "$claude_dir/commands"
  install_asset claude/hooks/session-title-emit.sh    "$claude_dir/hooks/session-title-emit.sh"    755 sh
  install_asset claude/hooks/session-title-compute.sh "$claude_dir/hooks/session-title-compute.sh" 755 sh
  install_asset claude/scripts/find-session.sh        "$claude_dir/scripts/find-session.sh"        755 sh

  # 세션 스킬은 repo 스킬(commit·pr·issue…)과 달리 **전역**으로 설치한다. 세션 관리는 repo 를
  # 건드리지 않는 일이라 piki repo 밖(다른 repo·빈 디렉토리)에서도 필요하고, 전역에 두면 소비 repo
  # 3곳에 .gitignore 를 더할 이유도 없어진다. 정본이 하나이므로 repo 사본과의 drift 도 생기지 않는다.
  install_asset skills/retitle.md      "$claude_dir/commands/retitle.md"      644 md
  install_asset skills/find-session.md "$claude_dir/commands/find-session.md" 644 md

  register_session_hooks "$claude_dir/settings.json"
fi

exit 0
