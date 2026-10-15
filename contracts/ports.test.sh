#!/usr/bin/env bash
#
# contracts/ports.json 규칙 검사. 규칙 설명은 conventions/infra.md 3절.
#
# 실행: ./contracts/ports.test.sh [ports.json 경로]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${1:-$SCRIPT_DIR/ports.json}"

# 박스가 이미 쓰는 포트(sshd·DNS·Alloy OTLP·Alloy UI·mysqld-exporter·nginx 상태 페이지·nginx-exporter·redis-exporter).
# 슬롯 포트가 이 값과 겹쳐도 안 된다.
RESERVED="22 53 4317 4318 12345 9104 9112 9113 9121"

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

jq -e 'type == "object" and length > 0' "$FILE" >/dev/null || { echo "FAIL: $FILE 이 비었거나 JSON 객체가 아님" >&2; exit 1; }

# 슬롯은 서비스 포트 앞에 1·2 를 붙여 만든다(deploy_slot.sh --service-port). 그래서 네 자리여야 한다.
while IFS=$'\t' read -r name port box; do
  case "$port" in
    [1-9][0-9][0-9][0-9]) ;;
    *) fail "$name.port 는 네 자리 숫자여야 함 (got: $port)"; continue;;
  esac
  for p in "$port" "1$port" "2$port"; do
    for r in $RESERVED; do
      [ "$p" = "$r" ] && fail "$name 의 포트 또는 슬롯 $p 가 예약 포트와 겹침"
    done
  done
  case "$box" in
    ""|piki-*) ;;
    *) fail "$name.box 는 piki- 로 시작하는 Name 태그여야 함 (got: $box)";;
  esac
done < <(jq -r 'to_entries[] | [.key, (.value.port | tostring), (.value.box // "")] | @tsv' "$FILE")

DUP=$(jq -r '[.[].port] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$FILE")
[ -z "$DUP" ] || fail "포트 중복: $DUP"

UNKNOWN=$(jq -r '.[] | keys[] | select(. != "port" and . != "box")' "$FILE" | sort -u)
[ -z "$UNKNOWN" ] || fail "모르는 키: $UNKNOWN"

if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAILURES FAILED" >&2
  exit 1
fi
