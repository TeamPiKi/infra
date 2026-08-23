#!/bin/bash
#
# 워크스페이스 루트(로비)에서 작업 후보 워크트리를 열거한다.
#
# 왜: 루트 세션은 어느 repo 에도 서 있지 않다. `/pr`·`/session-*` 이 "어디서 작업하던 것인가" 를
# 물으려면 자식 repo 들을 가로질러 후보를 모아야 하는데, `git worktree list` 는 repo 하나만 본다.
#
# 후보의 정의: **base 가 아닌 브랜치를 가진 linked worktree**. 메인 체크아웃은 제외한다 —
# 루트에서 `EnterWorktree path=` 로 진입할 수 없기 때문이다(실측: not a registered worktree).
# detached HEAD 도 제외한다(올릴 브랜치가 없다).
#
# 사용: piki-worktrees.sh [워크스페이스_루트]        (기본값: $PWD)
# 출력: repo <TAB> path <TAB> branch <TAB> session   (헤더 없음, 후보 없으면 빈 출력)
#       session 은 그 경로에서 다른 Claude Code 세션이 돌고 있으면 "열림", 아니면 "-".
# 정본: TeamPiKi/infra claude/scripts/piki-worktrees.sh (install.sh 가 ~/.claude/scripts 로 설치)

set -uo pipefail

root="${1:-$PWD}"
[ -d "$root" ] || exit 0

# ---- 살아있는 세션의 cwd 를 모은다 ----
# 레지스트리에는 죽은 세션의 파일도 남으므로 pid 생존까지 본다. 이 표시가 틀리면 사용자가 다른
# 세션이 쓰는 워크트리에 들어가게 되므로(양쪽이 같은 파일을 고친다) 조용한 오탐을 만들지 않는다.
# jq 가 없으면 표시를 포기하고 열거는 계속한다 — 후보를 못 보여주는 것보다 낫다.
session_cwds=$(mktemp) || exit 0
trap 'rm -f "$session_cwds"' EXIT
if command -v jq > /dev/null 2>&1; then
    for f in "$HOME"/.claude/sessions/*.json; do
        [ -f "$f" ] || continue
        pid=$(jq -r '.pid // empty' "$f" 2> /dev/null)
        [ -n "$pid" ] || continue
        kill -0 "$pid" 2> /dev/null || continue
        jq -r '.cwd // empty' "$f" 2> /dev/null >> "$session_cwds"
    done
fi

session_mark() {
    grep -qxF "$1" "$session_cwds" 2> /dev/null && echo "열림" || echo "-"
}

# base 브랜치 판정 — `/pr` 0-B 와 같은 우선순위(origin/dev -> 레포 default -> main)를 로컬 ref 로만
# 근사한다. 열거는 네트워크 없이 즉답해야 해서 `gh repo view` 를 부르지 않는다.
base_of() {
    local repo="$1" head
    if git -C "$repo" rev-parse --verify -q origin/dev > /dev/null 2>&1; then
        echo dev
        return
    fi
    head=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null)
    head=${head#origin/}
    echo "${head:-main}"
}

# ---- 자식 repo 를 돈다 ----
# 같은 repo 를 두 번 세지 않도록 git common dir 로 중복을 제거한다. 루트 밑에는 메인 체크아웃
# (piki/core)뿐 아니라 과거 격리 패턴이 남긴 형제 폴더 워크트리(piki/extractor-fetch-bound)도
# 있는데, 그 둘은 같은 repo 라 워크트리 목록도 같다.
seen=""
for child in "$root"/*/; do
    [ -e "${child}.git" ] || continue
    case "$(git -C "$child" remote get-url origin 2> /dev/null)" in
        *TeamPiKi/*) ;;
        *) continue ;;
    esac

    common=$(git -C "$child" rev-parse --path-format=absolute --git-common-dir 2> /dev/null) || continue
    [ -n "$common" ] || continue
    case "$seen" in
        *"|$common|"*) continue ;;
    esac
    seen="$seen|$common|"

    # repo 이름은 common dir 의 부모(= 메인 체크아웃)에서 얻는다. 지금 손에 든 $child 가 형제 폴더
    # 워크트리일 수 있어 그 이름을 쓰면 repo 이름이 브랜치 이름처럼 나온다.
    repo=$(basename "$(dirname "$common")")
    base=$(base_of "$child")

    # porcelain 의 첫 워크트리가 메인 체크아웃이다. 그것만 건너뛰고 나머지(linked)를 후보로 본다.
    git -C "$child" worktree list --porcelain | awk -v repo="$repo" -v base="$base" '
        /^worktree /  { path = substr($0, 10); branch = ""; next }
        /^branch /    { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch); next }
        /^detached/   { branch = ""; next }
        /^$/          { emit() }
        END           { emit() }
        function emit() {
            if (path == "") return
            if (!first) { first = 1; path = ""; return }   # 메인 체크아웃
            if (branch != "" && branch != base) printf "%s\t%s\t%s\n", repo, path, branch
            path = ""
        }
    '
done | while IFS=$'\t' read -r repo path branch; do
    printf '%s\t%s\t%s\t%s\n' "$repo" "$path" "$branch" "$(session_mark "$path")"
done

exit 0
