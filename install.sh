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
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"

if git remote get-url origin 2>/dev/null | grep -q "TeamPiKi/infra"; then
  self=1   # infra 자신 안에서 실행 (SSOT repo)
  get() { cat "$(git rev-parse --show-toplevel)/$1" 2>/dev/null; }
else
  self=0   # 소비 repo 에서 실행 (부트스트랩 경유)
  get() { gh api -H "Accept: application/vnd.github.raw" "repos/$INFRA_REPO/contents/$1" 2>/dev/null; }
fi

# 워크스페이스 루트(소비 repo 여럿을 자식으로 두는 자리)면 repo 전용 자산의 대상이 아니다. 코드가 없다.
# "origin 이 없음" 이 아니라 자식으로 판별하는 이유: remote 를 아직 안 붙인 소비 repo 와 구분되지 않는다.
workspace=0
if [ "$self" = 0 ] && [ -n "${repo_root:-}" ]; then
  for child in "$repo_root"/*/; do
    [ -e "${child}.git" ] || continue
    case "$(git -C "$child" remote get-url origin 2>/dev/null)" in
      *TeamPiKi/*) workspace=1; break ;;
    esac
  done
fi

# $1=자산 경로(repo 내) $2=설치 대상(절대경로) $3=권한 mode $4=검증 유형(sh|md|yaml)
# 빈 응답(fetch 실패·권한 없음)이면 어느 유형이든 스킵해 기존 설치본을 유지한다 (가용성 가드).
# 그 위에 유형별 검증을 얹는다 (validate_asset).
install_asset() {
  local tmp
  tmp=$(mktemp)
  if get "$1" >"$tmp" && [ -s "$tmp" ] && validate_asset "$tmp" "$4"; then
    install -m "$3" "$tmp" "$2"
  fi
  rm -f "$tmp"

  # 설치 성공 여부와 무관하게 "이번 버전이 설치하려는 목록" 에 기록한다.
  # 결과가 아니라 선언을 기록해야 오프라인으로 fetch 가 실패한 자산을 "정본에서 사라진 것" 으로
  # 오인해 지우지 않는다.
  MANIFEST="$MANIFEST$2
"
}

# 자산 유형별 검증. 새 유형이 생기면 여기 case 를 늘린다.
#   sh: bash -n 으로 문법을 확인한다. 문법 깨진 정본이 main 에 잠깐 올라가도 소비 repo 의
#       훅을 깨뜨리지 않게 설치를 스킵하고 기존 설치본을 유지한다.
#   md: 셸이 아니라 bash -n 이 오히려 실패하므로 적용하지 않는다. 비어있지 않음([ -s ])만 보며,
#       그건 install_asset 이 이미 확인했다.
#   yaml: yaml 파서를 전제할 수 없어(python·yq 가 없는 환경이 있다) 문법 검증 대신 최상위 키만 본다.
#       빈 응답은 install_asset 이 이미 거르므로, 여기가 막는 건 "받긴 받았는데 그 카탈로그가 아닌 것"
#       (에러 페이지·잘린 본문)이다. 이 검사가 파서 없이 오탐 없는 유일한 층이다.
validate_asset() {
  case "$2" in
    sh)   bash -n "$1" 2>/dev/null ;;
    md)   true ;;
    yaml) grep -q '^codes:' "$1" ;;
    *)    false ;;   # 알 수 없는 유형은 설치하지 않는다 (안전)
  esac
}

# 은퇴한 자산을 사용자 홈에서 걷어낸다.
#
# 설치기는 설치만 하므로, 정본에서 자산을 지워도 이미 깔린 환경에서는 파일과 등록이 그대로 남아
# 계속 동작한다. 그래서 "지웠다"가 실제로 지워지려면 철거 경로가 필요하다.
#
# 우리가 설치했던 것만, 경로가 정확히 일치할 때만 지운다 (사용자의 다른 훅은 건드리지 않는다).
# 목록은 추가만 하고 지우지 않는다 — 오래 안 켠 환경도 언젠가 켜면 정리되어야 한다.
MANIFEST=""


# 매니페스트가 기록한 경로만, 그것도 우리가 쓰는 설치 위치 안에 있을 때만 지운다.
# 매니페스트 파일이 손상되거나 남이 편집했을 때 엉뚱한 경로가 지워지는 것을 막는 마지막 방어선이다.
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

# 지난 설치 기록과 이번 설치 목록의 차집합이 곧 은퇴 자산이다.
#
# 이 방식의 요점은 사람이 은퇴를 선언하지 않아도 된다는 것이다 — 정본에서 파일을 지우면
# 다음 실행에서 설치기가 스스로 알아낸다. 잊어버릴 수 있는 절차를 기계가 대신한다.
# 매니페스트가 없으면(첫 실행) 비교 대상이 없으므로 아무것도 지우지 않는다.
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

# 매니페스트 이전 시대(#27)에 깔린 자산 — 그 시절엔 기록이 없어 차집합으로 못 잡는다.
# 한 번도 갱신 안 한 환경을 위해 남겨 둔다. **새 은퇴는 여기 적을 필요가 없다.**
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
    # 해당 command 를 가진 항목만 빼고, 그래서 비게 된 그룹도 함께 정리한다.
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

# 홈 훅을 사용자 settings.json 에 등록한다. 이 설치기가 **사용자 개인 설정을 고치는 유일한 지점**이라
# 가장 보수적으로 다룬다.
#   - 멱등: 같은 command 가 이미 있으면 아무것도 하지 않는다 (중복 등록 방지).
#   - 비파괴: 기존 항목을 지우거나 고치지 않는다. Orca 등 다른 훅과 그대로 공존한다.
#   - opt-out: ~/.claude/.no-session-hooks 가 있으면 등록을 건너뛴다. 훅을 원치 않는 사람이
#     매번 지우지 않아도 되게 하는 탈출구다 (파일만 지우면 설치기가 되살리지 않는다).
#   - 실패 안전: jq 가 없거나, 설정 파일이 없거나, JSON 이 깨져 있으면 손대지 않는다. 결과가
#     유효한 JSON 일 때만 원자적으로 교체하고, 원본 권한을 보존한다.
#
# 등록하는 훅 둘:
#   session-title-emit — UserPromptSubmit. matcher 가 없는 이벤트라 그룹 하나로 붙인다.
#   ensure-assets      — PostToolUse(EnterWorktree)·PreToolUse(Bash). 이 둘은 **툴 이름 matcher** 가
#                        필요해 ensure_matched 를 따로 둔다. 한 스크립트를 두 이벤트에 거는 이유는
#                        스크립트 주석 참고: 위치가 바뀌는 순간(EnterWorktree)과 그것을 놓쳤을 때의
#                        안전망(테스트 실행 직전)이 서로를 덮는다.
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
        # matcher 가 있는 이벤트용. 중복 판정을 **같은 matcher 그룹 안**으로 한정한다 — 이벤트 전체에서
        # 찾으면 한 이벤트에 matcher 를 하나 더 붙이는 변경이 "이미 있다"로 오인돼 조용히 누락된다.
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

# git hooks — 비버전 영역(.git/hooks)에 설치되므로 self 모드(infra 자신)에서도 무해하다.
install_asset hooks/commit-msg "$hooks_dir/commit-msg" 555 sh

# 개발 스킬(slash command) — repo 의 .claude/commands 에 설치한다. infra 자신(self 모드)도 포함한다:
# infra 에서도 커밋·PR 이 일어나므로 같은 절차 스킬이 필요하다 (infra#32 를 스킬 없이 수동 STAR 로
# 올린 것이 계기). self 모드의 get() 은 working tree 를 읽으므로 스킬 정본을 고치면 자기 세션에
# 즉시 반영되는 드라이푸딩도 된다. 버전 영역의 untracked 노이즈는 .gitignore(.claude/commands/)가 막는다.
# gc 는 commit 의 별칭이라 같은 정본을 두 이름으로 설치한다 (정본은 하나, 표면만 둘).
cmd_dir="$repo_root/.claude/commands"
mkdir -p "$cmd_dir"
install_asset skills/commit.md     "$cmd_dir/commit.md"     444 md
install_asset skills/commit.md     "$cmd_dir/gc.md"         444 md
install_asset skills/coderabbit.md "$cmd_dir/coderabbit.md" 444 md
install_asset skills/pr.md         "$cmd_dir/pr.md"         444 md
install_asset skills/issue.md      "$cmd_dir/issue.md"      444 md
install_asset skills/session-check.md "$cmd_dir/session-check.md" 444 md
install_asset skills/session-close.md "$cmd_dir/session-close.md" 444 md

# 규약 문서 — 소비 repo 의 .claude/rules 에 설치하고, 각 repo 의 CLAUDE.md 가 import 해 자동 로드한다.
# 스킬(행동 절차)과 달리 이건 판단 기준이라 에이전트 컨텍스트에 상주해야 효력이 있다.
# 언어·스택 바인딩은 각 repo 가 자기 문서에 소유하고, 여기서는 공통 원칙만 내려보낸다.
# 스킬과 달리 infra 자신은 제외한다 — import 할 CLAUDE.md 가 없고, JVM·Spring 원칙이라 대상도 아니다.
# 워크스페이스 루트도 같은 이유로 제외한다 (import 할 CLAUDE.md 도, 이 원칙을 적용할 코드도 없다).
if [ "$self" = 0 ] && [ "$workspace" = 0 ]; then
  rules_dir="$repo_root/.claude/rules"
  mkdir -p "$rules_dir"
  install_asset conventions/testing.md "$rules_dir/testing-principles.md" 444 md
fi

# 계약 카탈로그 — 소비 repo 의 shared-infra/contracts 에 설치한다.
#
# 이 설치는 로컬 세션 참조용 편의이지 CI 강제의 근거가 아니다. install.sh 는 SessionStart 훅이라
# CI 에서 돌지 않는다. 소비 repo 의 메타 테스트를 실제로 강제하는 건 그 repo 워크플로의
# actions/checkout(이 repo -> shared-infra/)이다.
#
# 그럼에도 경로를 shared-infra/contracts 로 맞추는 이유: 로컬과 CI 의 카탈로그 위치가 같아야
# 소비 repo 의 테스트가 경로를 하나만 알면 된다. 경로가 갈리면 테스트에 분기가 생기고, 그 분기가
# 로컬에서만 초록불인 사각을 만든다.
#
# 다른 계약 문서(health·observability)는 사람이 읽는 산문이라 설치 대상이 아니다. 카탈로그만 여기
# 오는 건 그것만 기계가 읽는 데이터이기 때문이다. self 모드(infra 자신)는 정본이 이미 손에 있어 제외한다.
# 버전 영역에 사본이 생기므로, 소비 repo 는 이 배선을 받을 때 .gitignore 에 shared-infra/ 를 더한다
# (CI 의 checkout 도 같은 자리에 풀리므로 그쪽 노이즈까지 함께 덮인다).
# 워크스페이스 루트도 제외한다. 카탈로그를 읽는 테스트는 자식 repo 에 있지 루트엔 없다.
if [ "$self" = 0 ] && [ "$workspace" = 0 ]; then
  contracts_dir="$repo_root/shared-infra/contracts"
  mkdir -p "$contracts_dir"
  install_asset contracts/extraction-error-codes.yaml "$contracts_dir/extraction-error-codes.yaml" 444 yaml
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
  install_asset claude/hooks/session-title-emit.sh    "$claude_dir/hooks/session-title-emit.sh"    555 sh
  install_asset claude/hooks/session-title-compute.sh "$claude_dir/hooks/session-title-compute.sh" 555 sh
  install_asset claude/scripts/find-session.sh        "$claude_dir/scripts/find-session.sh"        555 sh
  # 자산 자가치유 — 이 설치기의 사각(세션 시작 시점의 repo 한 곳에만 깔린다)을 스스로 메운다.
  # repo 가 아니라 홈에 두는 이유: 소비 repo 의 settings 에 두면 그 repo 와 그 워크트리만 커버해
  # "core 세션에서 extractor·renderer 를 만지는" 경로를 못 잡는다.
  install_asset claude/hooks/ensure-assets.sh         "$claude_dir/hooks/ensure-assets.sh"         555 sh

  # 세션 스킬은 repo 스킬(commit·pr·issue…)과 달리 **전역**으로 설치한다. 세션 관리는 repo 를
  # 건드리지 않는 일이라 piki repo 밖(다른 repo·빈 디렉토리)에서도 필요하고, 전역에 두면 소비 repo
  # 3곳에 .gitignore 를 더할 이유도 없어진다. 정본이 하나이므로 repo 사본과의 drift 도 생기지 않는다.
  install_asset skills/retitle.md      "$claude_dir/commands/retitle.md"      444 md
  install_asset skills/find-session.md "$claude_dir/commands/find-session.md" 444 md

  retire_assets "$claude_dir/settings.json"
  register_session_hooks "$claude_dir/settings.json"
fi

# ---- 은퇴 자산 정리 (지난 설치 기록과의 차집합) ----
#
# 홈과 repo 를 따로 기록한다. 홈 자산은 머신당 하나, repo 자산은 repo 마다 다르기 때문에
# 한 파일에 섞으면 A repo 에서 켤 때 B repo 의 설치본이 "사라진 것" 으로 오인된다.
# repo 쪽 기록은 .git 안(비버전)에 둬 워크트리가 여러 개여도 공유된다.
home_manifest="$HOME/.claude/.piki-manifest"
repo_manifest="$(git rev-parse --git-common-dir 2>/dev/null)/piki-manifest"

home_list=$(printf '%s' "$MANIFEST" | grep "^$HOME/.claude/" || true)
repo_list=$(printf '%s' "$MANIFEST" | grep -v "^$HOME/.claude/" || true)

[ -d "$HOME/.claude" ] && reconcile_manifest "$home_manifest" "$home_list" "$HOME/.claude/settings.json"
reconcile_manifest "$repo_manifest" "$repo_list" ""

exit 0
