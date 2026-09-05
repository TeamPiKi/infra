#!/bin/bash
#
# 세션을 폴더 경계를 넘어 "내용"으로 찾는다.
#
# 왜: /resume 은 현재 폴더(프로젝트)의 세션만 보여준다. worktree 나 다른 repo 에서 하던 작업은
# 목록에 아예 안 떠서 "분명 했는데 못 찾겠다" 가 된다. 이 스크립트는 모든 대화 기록을 검색해
# 그 사각을 메우고, 그 세션이 어느 폴더 소속인지와 재개 명령까지 만들어 준다.
#
# 사용: find-session.sh <검색어> [최대건수]
# 정본: TeamPiKi/infra claude/scripts/find-session.sh (install.sh 가 ~/.claude/scripts 로 설치)
q="$1"
limit="${2:-10}"
if [ -z "$q" ]; then
    echo "사용법: find-session.sh <검색어> [최대건수]"
    echo "예:     find-session.sh 그라파나"
    exit 1
fi

# ripgrep 이 있으면 쓴다 — transcript 가 수 MB 씩 쌓이므로 속도 차가 크다.
if command -v rg > /dev/null 2>&1; then
    count_hits() { rg -ic --no-messages -F -- "$q" "$1" 2> /dev/null || echo 0; }
else
    count_hits() { grep -icF -- "$q" "$1" 2> /dev/null || echo 0; }
fi

# stat·date 는 BSD(macOS)와 GNU(Linux) 의 플래그가 다르다 — 양쪽을 지원한다.
mtime_of() { stat -f '%m' "$1" 2> /dev/null || stat -c '%Y' "$1" 2> /dev/null; }
fmt_time() { date -r "$1" '+%m-%d %H:%M' 2> /dev/null || date -d "@$1" '+%m-%d %H:%M' 2> /dev/null; }

printf '"%s" 를 담은 세션 (최근 수정순, 최대 %s건)\n\n' "$q" "$limit"

hits_file=$(mktemp)
trap 'rm -f "$hits_file"' EXIT

for f in "$HOME"/.claude/projects/*/*.jsonl; do
    [ -f "$f" ] || continue
    # 현재 세션은 제외한다 — 검색어를 방금 타이핑한 탓에 늘 1위로 떠 결과를 가린다.
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$(basename "$f" .jsonl)" = "$CLAUDE_CODE_SESSION_ID" ]; then
        continue
    fi
    c=$(count_hits "$f")
    [ "$c" -gt 0 ] 2> /dev/null || continue
    printf '%s\t%s\t%s\n' "$(mtime_of "$f")" "$c" "$f"
done | sort -rn | head -n "$limit" > "$hits_file"

if [ ! -s "$hits_file" ]; then
    echo "(일치하는 세션 없음)"
    exit 0
fi

while IFS=$'\t' read -r mtime hits file; do
    sid=$(basename "$file" .jsonl)

    # 제목: 사용자·훅이 붙인 customTitle 이 있으면 그것, 없으면 첫 발화 앞머리.
    title=$(grep -o '"customTitle":"[^"]*"' "$file" 2> /dev/null | tail -1 | sed 's/.*:"//; s/"$//')
    if [ -z "$title" ]; then
        title=$(jq -r 'select(.type=="user") | .message.content
                       | if type=="string" then . else ([.[]? | select(.type=="text") | .text] | join(" ")) end' "$file" 2> /dev/null \
            | grep -vE '^<|command-name|command-message|command-args|local-command|Caveat:' | grep -v '^[[:space:]]*$' | head -1 | cut -c1-60)
    fi

    # 그 세션이 실제로 돌던 디렉토리. 마지막 값을 쓴다 — 세션 도중 worktree 로 진입하면 cwd 가 바뀌므로
    # 첫 값은 옛 위치이고, 재개는 마지막 위치에서 해야 맞다.
    cwd=$(jq -r 'select(.cwd) | .cwd' "$file" 2> /dev/null | tail -1)
    [ -n "$cwd" ] || cwd="(알 수 없음)"

    printf '[%s건] %s  %s\n' "$hits" "$(fmt_time "$mtime")" "${title:-(제목 없음)}"
    printf '        재개: cd %s && claude --resume %s\n\n' "$(printf '%q' "$cwd")" "$sid"
done < "$hits_file"
exit 0
