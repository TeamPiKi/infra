#!/bin/bash
#
# UserPromptSubmit 훅 — 대화 맥락을 반영해 세션 제목을 주기적으로 갱신한다.
#
# 왜 이 구조인가 (지연 0 원칙):
# 제목을 맥락에서 뽑으려면 LLM 이 필요한데, 프롬프트 경로에서 동기로 부르면 매 입력이 수 초씩 막힌다.
# 그래서 **방출과 계산을 분리**한다 — 방출은 미리 계산해 둔 캐시에서 즉시, 계산은 백그라운드에서.
# 대가로 제목이 한 박자 늦지만(계산한 다음 프롬프트에 반영) 입력이 절대 안 막힌다.
#
# 사용자 주권: /rename 으로 직접 붙인 이름은 덮지 않는다. 우리가 마지막에 넣은 값과 현재 제목이
# 다르면 사람이 개입한 것으로 보고 그 세션은 영구 백오프한다(.off). /retitle 이 이를 해제한다.
#
# 정본: TeamPiKi/infra claude/hooks/session-title-emit.sh (install.sh 가 ~/.claude/hooks 로 설치)

# 계산용 자식 세션(claude -p)에서 재귀 발동 방지
[ -n "${CLAUDE_TITLE_COMPUTE:-}" ] && exit 0

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0

dir="$HOME/.claude/session-titles"
mkdir -p "$dir" 2>/dev/null
off="$dir/$sid.off"
last="$dir/$sid.last"
cnt="$dir/$sid.count"
nxt="$dir/$sid.next"
[ -f "$off" ] && exit 0

cur=$(printf '%s' "$input" | jq -r '.session_title // empty' 2>/dev/null)
prev=$(cat "$last" 2>/dev/null)
if [ -n "$prev" ] && [ -n "$cur" ] && [ "$cur" != "$prev" ]; then
    : > "$off"
    exit 0
fi

n=$(cat "$cnt" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$cnt"

# 1) 캐시된 제목이 있으면 즉시 방출한다 (여기서 LLM 호출 없음 = 체감 지연 0)
if [ -s "$nxt" ]; then
    t=$(head -c 200 "$nxt" | head -1 | tr -d '\n"')
    rm -f "$nxt"
    if [ -n "$t" ]; then
        printf '%s' "$t" > "$last"
        jq -n --arg t "$t" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $t}}'
    fi
fi

# 2) 다음 제목을 백그라운드로 계산한다 — 2번째에 한 번(seed), 이후 10회마다.
#    2번째인 이유: 1번째는 훅이 프롬프트 기록 전에 돌아 읽을 맥락이 없고(헛 호출),
#    첫 주기(10회)까지 기다리면 짧은 세션은 맥락 제목을 영영 못 받는다.
if [ "$n" -eq 2 ] || [ $((n % 10)) -eq 0 ]; then
    tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    compute="$HOME/.claude/hooks/session-title-compute.sh"
    if [ -n "$tp" ] && [ -f "$tp" ] && [ -x "$compute" ]; then
        nohup "$compute" "$tp" "$nxt" "$cwd" > /dev/null 2>&1 &
    fi
fi
exit 0
