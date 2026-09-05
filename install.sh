#!/usr/bin/env bash
#
# infra 공통 자산 설치기 (정본). 소비 repo 는 이걸 fetch 해 실행하는 부트스트랩 한 줄만 갖는다.
# origin 이 infra 면 working tree 자산을 설치해 수정이 그 세션에 바로 반영되고, 아니면 원격 정본을 fetch 한다.
# fetch 실패·빈 응답이면 그 자산만 건너뛰고 기존 설치본을 유지한다. 항상 exit 0 (SessionStart 를 안 깨뜨린다).

set -uo pipefail

INFRA_REPO="TeamPiKi/infra"

hooks_dir="$(git rev-parse --git-common-dir 2>/dev/null)/hooks"
[ -d "$hooks_dir" ] || exit 0
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"

if git remote get-url origin 2>/dev/null | grep -q "TeamPiKi/infra"; then
  self=1   # infra 자신 안에서 실행 (SSOT repo)
  get() { cat "$(git rev-parse --show-toplevel)/$1" 2>/dev/null; }
else
  self=0   # 소비 repo 에서 실행 (부트스트랩 경유)
  get() { gh api -H "Accept: application/vnd.github.raw" "repos/$INFRA_REPO/contents/$1" 2>/dev/null; }
fi

# 원격 정본의 blob sha 목록을 한 번에 받아 둔다(경로<TAB>sha). 자산마다 내려받기 전에 설치본의
# git hash-object 와 비교해 같으면 다운로드를 건너뛴다 — 세션 시작 지연의 대부분이 바뀌지도 않은
# 파일을 매번 다시 받는 순차 API 호출이었다(자산 16개 ≈ 6초). 이 목록을 못 받으면 비워 두고 예전처럼
# 전부 받는다: 느려질 뿐 깨지지는 않는다. self 모드는 로컬 cat 이라 비교할 이유가 없다.
TREE=""
if [ "$self" = 0 ]; then
  TREE=$(gh api "repos/$INFRA_REPO/git/trees/HEAD?recursive=1" \
           --jq '.tree[] | select(.type=="blob") | "\(.path)\t\(.sha)"' 2>/dev/null || true)
fi

# $1=자산 경로 $2=설치 대상. 설치본이 정본과 같은 blob 이면 0.
unchanged() {
  [ -n "$TREE" ] && [ -f "$2" ] || return 1
  local remote local_sha
  remote=$(printf '%s\n' "$TREE" | awk -F'\t' -v p="$1" '$1==p {print $2; exit}')
  [ -n "$remote" ] || return 1
  local_sha=$(git hash-object "$2" 2>/dev/null) || return 1
  [ "$remote" = "$local_sha" ]
}


# 자식으로 판별하는 이유: origin 없음으로 보면 remote 를 아직 안 붙인 소비 repo 가 루트로 오인된다.
workspace=0
if [ "$self" = 0 ] && [ -n "${repo_root:-}" ]; then
  for child in "$repo_root"/*/; do
    [ -e "${child}.git" ] || continue
    case "$(git -C "$child" remote get-url origin 2>/dev/null)" in
      *TeamPiKi/*) workspace=1; break ;;
    esac
  done
fi

# $1=자산 경로 $2=설치 대상(절대경로) $3=권한 mode $4=검증 유형. 빈 응답이면 스킵해 기존 설치본을 유지한다.
install_asset() {
  local tmp
  if ! unchanged "$1" "$2"; then
    tmp=$(mktemp)
    if get "$1" >"$tmp" && [ -s "$tmp" ] && validate_asset "$tmp" "$4"; then
      install -m "$3" "$tmp" "$2"
    fi
    rm -f "$tmp"
  fi

  # 결과가 아니라 선언을 기록한다. 그래야 fetch 실패한 자산을 다음 실행이 은퇴로 오인해 지우지 않는다.
  MANIFEST="$MANIFEST$2
"
}

# sh 는 깨진 정본이 소비 repo 훅을 못 깨게 bash -n 을 건다. yaml 은 파서를 전제할 수 없어 최상위 키만
# 보는데, 이게 "받긴 받았지만 그 카탈로그가 아닌 것"(에러 페이지·잘린 본문)을 거르는 유일한 층이다.
validate_asset() {
  case "$2" in
    sh)   bash -n "$1" 2>/dev/null ;;
    md)   true ;;
    yaml) grep -q '^codes:' "$1" ;;
    *)    false ;;   # 알 수 없는 유형은 설치하지 않는다 (안전)
  esac
}

# 이번 실행이 설치하려는 목록. 정본에서 지운 자산은 철거 경로가 없으면 이미 깔린 환경에 계속 남는다.
MANIFEST=""


# 매니페스트가 손상되거나 남이 편집했을 때 엉뚱한 경로를 지우지 않게 막는 마지막 방어선.
is_managed_path() {
  case "$1" in
    "$HOME/.claude/hooks/"*|"$HOME/.claude/scripts/"*|"$HOME/.claude/commands/"*) return 0 ;;
  esac
  [ -n "${repo_root:-}" ] && case "$1" in
    "$repo_root/.claude/commands/"*|"$repo_root/.claude/rules/"*|"$repo_root/shared-infra/"*) return 0 ;;
  esac
  [ -n "${hooks_dir:-}" ] && case "$1" in
    "$hooks_dir/"*) return 0 ;;
  esac
  return 1
}

# settings.json 에서 그 경로를 실행하는 등록만 뺀다 (빈 그룹·이벤트 키도 함께 정리).
unregister_hook() {
  local cmd="$1" settings="$2" tmp mode
  [ -f "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -e . "$settings" >/dev/null 2>&1 || return 0
  grep -qF "$cmd" "$settings" || return 0
  tmp=$(mktemp)
  if jq --arg cmd "$cmd" '
       .hooks |= with_entries(
         .value |= (map(.hooks |= map(select(.command != $cmd))) | map(select((.hooks | length) > 0)))
       )
       | .hooks |= with_entries(select((.value | length) > 0))
     ' "$settings" >"$tmp" 2>/dev/null && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    mode=$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings" 2>/dev/null || echo 644)
    install -m "$mode" "$tmp" "$settings"
  fi
  rm -f "$tmp"
}

# 지난 기록과 이번 목록의 차집합이 은퇴 자산이다. 기록이 없으면(첫 실행) 아무것도 지우지 않는다.
reconcile_manifest() {
  local manifest="$1" current="$2" settings="$3" old
  if [ -f "$manifest" ]; then
    local old_path
    while IFS= read -r old || [ -n "$old" ]; do
      [ -n "$old" ] || continue
      old_path=${old%%	*}                                       # 옛 기록이 지문을 달고 있으면 경로만 취한다

      printf '%s\n' "$current" | cut -f1 | grep -qxF "$old_path" && continue  # 이번에도 설치 대상
      is_managed_path "$old_path" || continue                     # 관리 밖 경로는 손대지 않는다

      rm -f "$old_path"
      unregister_hook "$old_path" "$settings"
    done < "$manifest"
  fi
  if [ -n "$current" ]; then
    printf '%s\n' "$current" > "$manifest"
  else
    : > "$manifest"
  fi
}

# 매니페스트 이전(#27)에 깔려 차집합으로 못 잡는 잔재. 새 은퇴는 여기 적지 않는다.
RETIRED_HOOKS="session-auto-name.sh"

retire_assets() {
  local settings="$1" f tmp mode cmd
  for f in $RETIRED_HOOKS; do
    rm -f "$HOME/.claude/hooks/$f"
  done

  [ -f "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -e . "$settings" >/dev/null 2>&1 || return 0

  for f in $RETIRED_HOOKS; do
    cmd="$HOME/.claude/hooks/$f"
    grep -qF "$cmd" "$settings" || continue
    tmp=$(mktemp)
    if jq --arg cmd "$cmd" '
         .hooks |= with_entries(
           .value |= (map(.hooks |= map(select(.command != $cmd))) | map(select((.hooks | length) > 0)))
         )
         | .hooks |= with_entries(select((.value | length) > 0))
       ' "$settings" >"$tmp" 2>/dev/null && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
      mode=$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings" 2>/dev/null || echo 644)
      install -m "$mode" "$tmp" "$settings"
    fi
    rm -f "$tmp"
  done
}

# 사용자 개인 설정을 고치는 유일한 지점이라 보수적으로 다룬다. 기존 항목은 지우거나 고치지 않아
# 다른 훅과 공존하고, ~/.claude/.no-session-hooks 가 있으면 등록을 통째로 건너뛴다(탈출구).
register_session_hooks() {
  local settings="$1" tmp mode
  [ -f "$HOME/.claude/.no-session-hooks" ] && return 0
  [ -f "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -e . "$settings" >/dev/null 2>&1 || return 0

  tmp=$(mktemp)
  if jq --arg emit "$HOME/.claude/hooks/session-title-emit.sh" \
        --arg assets "$HOME/.claude/hooks/ensure-assets.sh" '
        def ensure($event; $cmd):
          if [.hooks[$event][]?.hooks[]?.command] | index($cmd) then .
          else .hooks[$event] = ((.hooks[$event] // []) + [{hooks: [{type: "command", command: $cmd, timeout: 10}]}])
          end;
        # 중복 판정을 같은 matcher 그룹 안으로 한정한다. 이벤트 전체에서 찾으면 matcher 를 하나 더
        # 붙이는 변경이 "이미 있다"로 오인돼 조용히 누락된다.
        def ensure_matched($event; $matcher; $cmd):
          if [.hooks[$event][]? | select(.matcher == $matcher) | .hooks[]?.command] | index($cmd) then .
          else .hooks[$event] = ((.hooks[$event] // []) + [{matcher: $matcher, hooks: [{type: "command", command: $cmd, timeout: 20}]}])
          end;
        .hooks = (.hooks // {})
        | ensure("UserPromptSubmit"; $emit)
        | ensure_matched("PostToolUse"; "EnterWorktree"; $assets)
        | ensure_matched("PreToolUse"; "Bash"; $assets)
     ' "$settings" >"$tmp" 2>/dev/null && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    mode=$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings" 2>/dev/null || echo 644)
    install -m "$mode" "$tmp" "$settings"
  fi
  rm -f "$tmp"
}

# ---- 자산 목록 (여기만 고치면 모든 소비 repo 에 반영된다) ----

# 비버전 영역(.git/hooks)이라 self 모드에서도 무해하다.
install_asset hooks/commit-msg "$hooks_dir/commit-msg" 555 sh

# 개발 스킬(slash command). infra 자신도 대상이다: 여기서도 커밋·PR 이 일어난다.
# 정본 하나는 이름 하나로만 깐다 (별칭 금지 — 같은 내용을 두 번 받고 두 파일이 남는다).
# 버전 영역 노이즈는 .gitignore 가 막는다.
cmd_dir="$repo_root/.claude/commands"
mkdir -p "$cmd_dir"
install_asset skills/commit.md     "$cmd_dir/commit.md"     444 md
install_asset skills/coderabbit.md "$cmd_dir/coderabbit.md" 444 md
install_asset skills/pr.md         "$cmd_dir/pr.md"         444 md
install_asset skills/issue.md      "$cmd_dir/issue.md"      444 md
install_asset skills/session-check.md "$cmd_dir/session-check.md" 444 md
install_asset skills/session-close.md "$cmd_dir/session-close.md" 444 md

# 규약 문서는 각 repo 의 CLAUDE.md 가 import 해야 효력이 있다. 그래서 import 할 CLAUDE.md 도,
# 이 원칙을 적용할 코드도 없는 infra 자신과 워크스페이스 루트는 제외한다.
if [ "$self" = 0 ] && [ "$workspace" = 0 ]; then
  rules_dir="$repo_root/.claude/rules"
  mkdir -p "$rules_dir"
  install_asset conventions/testing.md "$rules_dir/testing-principles.md" 444 md
fi

# 루트 CLAUDE.md 가 `@.claude/rules/piki-workspace.md` 로 import 해야 로드된다(실측).
# 그 한 줄은 workspace/workspace-init.sh 가 만든다.
if [ "$workspace" = 1 ]; then
  workspace_rules_dir="$repo_root/.claude/rules"
  mkdir -p "$workspace_rules_dir"
  install_asset workspace/piki-workspace.md "$workspace_rules_dir/piki-workspace.md" 444 md
fi

# 계약 카탈로그. 이 설치는 로컬 참조용 편의일 뿐 CI 강제 근거가 아니다(CI 에선 워크플로의 checkout 이
# 같은 자리에 푼다). 경로를 맞추는 이유가 그것이다: 소비 repo 의 테스트가 경로를 하나만 알면 된다.
# 정본이 이미 손에 있는 infra 자신과, 카탈로그를 읽는 테스트가 없는 워크스페이스 루트는 제외한다.
# 버전 영역에 사본이 생기므로 소비 repo 는 .gitignore 에 shared-infra/ 를 둔다.
if [ "$self" = 0 ] && [ "$workspace" = 0 ]; then
  contracts_dir="$repo_root/shared-infra/contracts"
  mkdir -p "$contracts_dir"
  install_asset contracts/extraction-error-codes.yaml "$contracts_dir/extraction-error-codes.yaml" 444 yaml
fi

# 세션 훅·유틸은 사용자 전역 설정이라 repo 안에 둘 자리가 없다. 대신 repo 를 열 때마다 정본으로 맞춘다.
claude_dir="$HOME/.claude"
if [ -d "$claude_dir" ]; then
  mkdir -p "$claude_dir/hooks" "$claude_dir/scripts" "$claude_dir/commands"
  install_asset claude/hooks/session-title-emit.sh    "$claude_dir/hooks/session-title-emit.sh"    555 sh
  install_asset claude/hooks/session-title-compute.sh "$claude_dir/hooks/session-title-compute.sh" 555 sh
  install_asset claude/scripts/find-session.sh        "$claude_dir/scripts/find-session.sh"        555 sh
  install_asset claude/scripts/piki-worktrees.sh      "$claude_dir/scripts/piki-worktrees.sh"      555 sh
  # 자가치유. 이 설치기는 세션 시작 시점의 repo 한 곳에만 깔리므로, 세션 도중 다른 repo 를 만지는
  # 경로를 이 훅이 메운다. 소비 repo 의 settings 에 두면 그 repo 만 커버해서 홈에 둔다.
  install_asset claude/hooks/ensure-assets.sh         "$claude_dir/hooks/ensure-assets.sh"         555 sh

  # 세션 관리는 repo 를 건드리지 않는 일이라 piki repo 밖에서도 필요하다. 그래서 전역에 깐다.
  install_asset skills/retitle.md      "$claude_dir/commands/retitle.md"      444 md
  install_asset skills/find-session.md "$claude_dir/commands/find-session.md" 444 md

  retire_assets "$claude_dir/settings.json"
  register_session_hooks "$claude_dir/settings.json"
fi

# ---- 은퇴 자산 정리 (지난 설치 기록과의 차집합) ----
# 홈과 repo 기록을 섞으면 A repo 에서 켤 때 B repo 의 설치본이 사라진 것으로 오인된다.
# repo 기록은 .git 안(비버전)에 둬 워크트리 여러 개가 공유한다.
home_manifest="$HOME/.claude/.piki-manifest"
repo_manifest="$(git rev-parse --git-common-dir 2>/dev/null)/piki-manifest"

home_list=$(printf '%s' "$MANIFEST" | grep "^$HOME/.claude/" || true)
repo_list=$(printf '%s' "$MANIFEST" | grep -v "^$HOME/.claude/" || true)

[ -d "$HOME/.claude" ] && reconcile_manifest "$home_manifest" "$home_list" "$HOME/.claude/settings.json"
reconcile_manifest "$repo_manifest" "$repo_list" ""

exit 0
