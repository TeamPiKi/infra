#!/bin/bash
#
# 워크스페이스 루트(로비)에서 자식 repo 를 가로질러 작업 후보 워크트리를 열거한다.
#
# 사용: piki-worktrees.sh [워크스페이스_루트]        (기본값: cwd 의 git toplevel)
# 출력: repo <TAB> path <TAB> branch <TAB> open|free  (후보가 없으면 빈 출력)
# 정본: TeamPiKi/infra claude/scripts/piki-worktrees.sh (install.sh 가 ~/.claude/scripts 로 설치)

set -uo pipefail

root=${1:-$(git rev-parse --show-toplevel 2> /dev/null)}
[ -d "$root" ] || exit 0

# 레지스트리에 죽은 세션의 파일도 남는다.
live_cwds=$'\n'
for f in "$HOME"/.claude/sessions/*.json; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r pid cwd < <(jq -r '[.pid, .cwd] | @tsv' "$f" 2> /dev/null)
    [ -n "${cwd:-}" ] || continue
    kill -0 "${pid:-}" 2> /dev/null || continue
    live_cwds="$live_cwds$cwd"$'\n'
done

seen=
for child in "$root"/*/; do
    [ -e "${child}.git" ] || continue
    case "$(git -C "$child" remote get-url origin 2> /dev/null)" in
        *TeamPiKi/*) ;;
        *) continue ;;
    esac

    # 형제 폴더 워크트리(piki/extractor-fetch-bound)도 자식으로 잡혀 같은 repo 가 두 번 걸린다.
    common=$(git -C "$child" rev-parse --path-format=absolute --git-common-dir 2> /dev/null) || continue
    case "$seen" in *"|$common|"*) continue ;; esac
    seen="$seen|$common|"

    # $child 가 형제 폴더 워크트리면 그 basename 은 repo 가 아니라 작업 이름이다.
    repo=$(basename "$(dirname "$common")")

    # `/pr` 0-B 와 같은 우선순위지만 `gh repo view` 는 안 쓴다 - 열거는 네트워크 없이 즉답해야 한다.
    if git -C "$child" rev-parse --verify -q origin/dev > /dev/null 2>&1; then
        base=dev
    else
        base=$(git -C "$child" symbolic-ref --short -q refs/remotes/origin/HEAD 2> /dev/null)
        base=${base#origin/}
        base=${base:-main}
    fi

    # 첫 레코드인 메인 체크아웃은 제외한다 - 로비에서 `EnterWorktree path=` 로 진입할 수 없다.
    git -C "$child" worktree list --porcelain | awk -v RS='' -v repo="$repo" -v base="$base" '
        NR == 1 { next }
        {
            path = ""; branch = ""
            n = split($0, line, "\n")
            for (i = 1; i <= n; i++) {
                if (line[i] ~ /^worktree /)            path   = substr(line[i], 10)
                else if (line[i] ~ /^branch refs\/heads\//) branch = substr(line[i], 19)
            }
            if (path != "" && branch != "" && branch != base) printf "%s\t%s\t%s\n", repo, path, branch
        }
    '
done | while IFS=$'\t' read -r repo path branch; do
    case "$live_cwds" in
        *$'\n'"$path"$'\n'*) printf '%s\t%s\t%s\topen\n' "$repo" "$path" "$branch" ;;
        *) printf '%s\t%s\t%s\tfree\n' "$repo" "$path" "$branch" ;;
    esac
done

exit 0
