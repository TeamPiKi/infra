#!/bin/bash
#
# session-title-emit.sh 가 백그라운드로 부르는 제목 계산기.
# 최근 사용자 발화를 읽어 "지금 무슨 작업 중인지" 한 줄을 만들어 캐시 파일에 쓴다.
#
# 프롬프트 경로 밖에서만 돌기 때문에 여기서는 LLM 을 동기 호출해도 사용자를 막지 않는다.
# 모델은 haiku 고정 — 제목 한 줄에 큰 모델을 쓸 이유가 없다.
#
# 실행 위치와 플래그: 프로젝트 디렉토리가 아니라 캐시 디렉토리에서 돌리고, 세션을 남기지 않는다.
# 프로젝트 안에서 돌리면 CLAUDE.md·rules·메모리·MCP 서버를 제목 한 줄 만들자고 매번 로드하고,
# 계산마다 세션 파일이 남아 /find-session 결과에 가짜 세션으로 섞인다 (실측 2026-09-05: 정리 전 세션 파일 682개 중 343개가 이 잔재였다).
#   --no-session-persistence  세션 파일을 쓰지 않는다
#   --strict-mcp-config       사용자 설정의 MCP 서버를 띄우지 않는다
#   CLAUDE_CODE_DISABLE_AUTO_MEMORY=1  자동 메모리를 읽지도 만들지도 않는다 (실측: 없으면 빈 memory 디렉토리가 생긴다)
# --bare 는 쓰지 않는다 — OAuth 로그인을 못 쓰고 API 키만 받는다.
#
# 인자: $1=transcript 경로  $2=결과를 쓸 캐시 파일
# 정본: TeamPiKi/infra claude/hooks/session-title-compute.sh (install.sh 가 ~/.claude/hooks 로 설치)
tp="$1"
out="$2"
run_dir="$HOME/.claude/session-titles"
[ -f "$tp" ] || exit 0
command -v claude > /dev/null 2>&1 || exit 0

# 최근 사용자 발화만 추출한다. 슬래시 커맨드·시스템 주입 블록은 작업 맥락이 아니므로 걸러낸다.
ctx=$(jq -r 'select(.type=="user") | .message.content
             | if type=="string" then . else ([.[]? | select(.type=="text") | .text] | join(" ")) end' "$tp" 2>/dev/null \
    | grep -vE '^<|command-name|command-message|command-args|local-command|system-reminder|Caveat:' \
    | grep -v '^[[:space:]]*$' \
    | tail -14 | tail -c 2000)
[ -n "$ctx" ] || exit 0

instruction=$(printf '아래 <대화>는 개발 세션의 최근 사용자 발화다. 지금 진행 중인 작업을 나타내는 한국어 명사구를 딱 한 줄만 출력하라.

규칙:
- 20자 이내의 명사구 (예: 아웃박스 재시도 상한 조정)
- 제목 텍스트만 출력. 머리말·설명·목록·마크다운 기호(#, -, *)·따옴표·마침표 금지
- 빈 줄이나 헤더를 앞에 붙이지 말 것

<대화>
%s
</대화>' "$ctx")

# 응답 정제 — 모델이 헤더·코드펜스·불릿을 앞세우는 경우가 있어 그런 줄은 버리고 첫 실질 줄만 취한다.
# stdin 은 닫아서 넘긴다(< /dev/null) — 열어 두면 claude -p 가 파이프 입력을 3초 기다린다(실측 4.4초 중 3초).
mkdir -p "$run_dir" 2>/dev/null
t=$(cd "$run_dir" 2>/dev/null && CLAUDE_TITLE_COMPUTE=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 claude -p "$instruction" --model haiku --no-session-persistence --strict-mcp-config < /dev/null 2>/dev/null \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -vE '^(#|`|-|\*|>|$)' \
    | head -1 | tr -d '\n"' | sed 's/[[:space:]]*[.。]$//')

# 형식 가드 — 비었거나 지나치게 길면(모델이 설명문을 뱉은 경우) 버린다. 한글은 3바이트라 넉넉히 잡는다.
[ -n "$t" ] || exit 0
[ ${#t} -gt 90 ] && exit 0
printf '%s' "$t" > "$out"
