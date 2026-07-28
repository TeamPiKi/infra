#!/bin/bash
#
# SessionStart 훅 — 작업 브랜치에서 시작한 세션에 브랜치 기반 이름을 부여한다.
#
# 왜: /resume 목록에서 세션을 구분하려면 이름이 필요한데, 이름 없는 세션은 첫 프롬프트 요약으로만
# 남아 "어느 작업이었나" 를 못 가린다. 세션이 뜨는 순간 브랜치명이 그 답을 이미 갖고 있다.
#
# 규칙 셋:
#   - 이미 이름이 있으면(사용자 지정·재개) 건드리지 않는다.
#   - 기본 브랜치(dev/main/master)에서는 붙이지 않는다 — 전부 같은 이름이 되어 구분에 기여하지 않고,
#     그럴 바엔 첫 프롬프트 기반 자동 제목이 낫다.
#   - 타입 prefix 를 뗀다: feat/750-sse-replay -> 750-sse-replay (라벨==prefix 라 정보가 없다).
#
# 정본: TeamPiKi/infra claude/hooks/session-auto-name.sh (install.sh 가 ~/.claude/hooks 로 설치)
input=$(cat)

existing=$(printf '%s' "$input" | jq -r '.session_title // empty' 2>/dev/null)
[ -n "$existing" ] && exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || exit 0

branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
[ -n "$branch" ] || exit 0
case "$branch" in
    dev | main | master) exit 0 ;;
esac

title="${branch#*/}"
[ -n "$title" ] || exit 0

jq -n --arg t "$title" '{hookSpecificOutput: {hookEventName: "SessionStart", sessionTitle: $t}}'
