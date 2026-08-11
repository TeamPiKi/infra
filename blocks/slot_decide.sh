#!/usr/bin/env bash
#
# 공통 배포 블록: blue-green 슬롯 판정
#
# nginx upstream 상태 파일(현재 서빙 슬롯의 single source, 예: "server 127.0.0.1:18090;")을
# 읽어 ACTIVE(서빙 중)/INACTIVE(이번 배포 대상) 슬롯을 판정한다.
# 실행 위치 중립 - 순수 bash 만 쓴다. transport 는 호출자 소관 (conventions/blocks.md 1번).
#
# 포트 추출은 콜론 뒤 숫자만 문다 - "server 127.0.0.1:18090;" 처럼 host 에 숫자가 섞이면
# 무차별 숫자 추출은 "127" 을 먼저 물어 슬롯 판정이 조용히 어긋난다 (extractor 실측 함정.
# "server localhost:8080;" 류는 우연히 무사해서 복제 구현에 잠복해 있었다).
#
# 상태 파일이 없거나 포트가 두 슬롯 어느 쪽도 아니면 부트스트랩으로 본다:
# ACTIVE 는 빈 값, INACTIVE 는 --slot-a (첫 배포는 a 슬롯으로 간다).
#
# 출력: eval 가능한 한 줄 (stdout)
#   ACTIVE=blue ACTIVE_PORT=18090 INACTIVE=green INACTIVE_PORT=18091
# 호출자는 2단계로 소비한다 - eval "$(...)" 직결은 치환 실패가 빈 문자열 eval(성공)로
# 위장되므로, 할당으로 실패를 먼저 드러낸 뒤 eval 한다:
#   DECIDED=$(bash slot_decide.sh --state-file ... --slot-a blue:18090 --slot-b green:18091)
#   eval "$DECIDED"
#
# 인자:
#   --state-file  (필수) upstream 상태 파일 경로
#   --slot-a      (필수) 첫 슬롯 NAME:PORT (예: blue:18090). 부트스트랩의 배포 대상
#   --slot-b      (필수) 둘째 슬롯 NAME:PORT (예: green:18091)
#
# 종료 코드: 성공 0, 인자 오류 2 (판정 자체는 실패하지 않는다 - 모르는 상태는 부트스트랩)

set -euo pipefail

STATE_FILE=""
SLOT_A=""
SLOT_B=""

while [ $# -gt 0 ]; do
  case "$1" in
    --state-file) STATE_FILE="${2:-}"; shift 2;;
    --slot-a)     SLOT_A="${2:-}"; shift 2;;
    --slot-b)     SLOT_B="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$STATE_FILE" ] || { echo "--state-file is required" >&2; exit 2; }
[ -n "$SLOT_A" ]     || { echo "--slot-a is required" >&2; exit 2; }
[ -n "$SLOT_B" ]     || { echo "--slot-b is required" >&2; exit 2; }

parse_slot() {
  # NAME:PORT 를 검증하며 분해한다. 전역 PARSED_NAME/PARSED_PORT 로 반환.
  local arg_name="$1" value="$2"
  PARSED_NAME="${value%%:*}"
  PARSED_PORT="${value##*:}"
  if [ "$value" = "$PARSED_NAME" ] || [ -z "$PARSED_NAME" ] || [ -z "$PARSED_PORT" ]; then
    echo "$arg_name must be NAME:PORT (got: $value)" >&2
    exit 2
  fi
  case "$PARSED_PORT" in
    *[!0-9]*) echo "$arg_name port must be numeric (got: $value)" >&2; exit 2;;
  esac
}

parse_slot "--slot-a" "$SLOT_A"
NAME_A="$PARSED_NAME" PORT_A="$PARSED_PORT"
parse_slot "--slot-b" "$SLOT_B"
NAME_B="$PARSED_NAME" PORT_B="$PARSED_PORT"

CURRENT_PORT=""
if [ -f "$STATE_FILE" ]; then
  CURRENT_PORT=$(grep -oE ':[0-9]+' "$STATE_FILE" | head -1 | tr -d ':' || true)
fi

if [ "$CURRENT_PORT" = "$PORT_A" ]; then
  echo "ACTIVE=$NAME_A ACTIVE_PORT=$PORT_A INACTIVE=$NAME_B INACTIVE_PORT=$PORT_B"
elif [ "$CURRENT_PORT" = "$PORT_B" ]; then
  echo "ACTIVE=$NAME_B ACTIVE_PORT=$PORT_B INACTIVE=$NAME_A INACTIVE_PORT=$PORT_A"
else
  echo "ACTIVE= ACTIVE_PORT= INACTIVE=$NAME_A INACTIVE_PORT=$PORT_A"
fi
