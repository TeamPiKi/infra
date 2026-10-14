#!/usr/bin/env bash
#
# blocks/slot_decide.sh 셀프 테스트
#
# 상태 파일 케이스(부트스트랩·a 활성·b 활성·모르는 포트)와 인자 오류, 그리고 이 블록의
# 존재 이유인 포트 추출 함정(host 의 127 이 먼저 잡히는 것) 회귀를 실측한다.
# conventions/blocks.md 5번 원칙(셀프 검증 가능)의 실행체.
#
# 실행: ./blocks/slot_decide.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDE="$SCRIPT_DIR/slot_decide.sh"

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

FAILURES=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (expected=[$expected] actual=[$actual])" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# 1. 필수 인자 누락
"$DECIDE" --slot-a blue:18090 --slot-b green:18091 >/dev/null 2>&1
check "state-file 없음 -> exit 2" 2 "$?"
"$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:18090 >/dev/null 2>&1
check "slot-b 없음 -> exit 2" 2 "$?"

# 2. 알 수 없는 인자
"$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:18090 --slot-b green:18091 --bogus x >/dev/null 2>&1
check "알 수 없는 인자 -> exit 2" 2 "$?"

# 3. 슬롯 형식 위반
"$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue18090 --slot-b green:18091 >/dev/null 2>&1
check "콜론 없는 슬롯 -> exit 2" 2 "$?"
"$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:1809x --slot-b green:18091 >/dev/null 2>&1
check "비숫자 포트 -> exit 2" 2 "$?"
"$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a 'bl;ue:18090' --slot-b green:18091 >/dev/null 2>&1
check "허용목록 밖 슬롯 이름(eval 주입 표면) -> exit 2" 2 "$?"

# 4. 부트스트랩: 상태 파일 없음 -> INACTIVE = slot-a
OUT=$("$DECIDE" --state-file "$WORKDIR/none.conf" --slot-a blue:18090 --slot-b green:18091)
check "부트스트랩 판정" "ACTIVE= ACTIVE_PORT= INACTIVE=blue INACTIVE_PORT=18090" "$OUT"

# 5. 포트 추출 함정 회귀: host 에 숫자(127.0.0.1)가 있어도 콜론 뒤 포트만 문다
echo "server 127.0.0.1:18090;" >"$WORKDIR/up.conf"
OUT=$("$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:18090 --slot-b green:18091)
check "127.0.0.1 host 에서 a 활성 판정" "ACTIVE=blue ACTIVE_PORT=18090 INACTIVE=green INACTIVE_PORT=18091" "$OUT"

# 6. b 활성 (core 의 localhost 표기도 같은 추출 규칙으로 동작)
echo "server localhost:8081;" >"$WORKDIR/up.conf"
OUT=$("$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:8080 --slot-b green:8081)
check "localhost 표기에서 b 활성 판정" "ACTIVE=green ACTIVE_PORT=8081 INACTIVE=blue INACTIVE_PORT=8080" "$OUT"

# 7. 모르는 포트 -> 부트스트랩
echo "server 127.0.0.1:9999;" >"$WORKDIR/up.conf"
OUT=$("$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:18090 --slot-b green:18091)
check "모르는 포트 -> 부트스트랩" "ACTIVE= ACTIVE_PORT= INACTIVE=blue INACTIVE_PORT=18090" "$OUT"

# 8. 출력이 eval 가능한 계약인지 (문서의 2단계 소비 패턴 그대로)
echo "server 127.0.0.1:18091;" >"$WORKDIR/up.conf"
DECIDED=$("$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:18090 --slot-b green:18091)
eval "$DECIDED"
check "eval 소비: ACTIVE" "green" "${ACTIVE:-}"
check "eval 소비: INACTIVE_PORT" "18090" "${INACTIVE_PORT:-}"

# 9. 옛 슬롯: 상태 파일이 옛 포트면 그 이름이 ACTIVE, 새 컨테이너는 반대 이름·새 포트
LEGACY=(--slot-a blue:18080 --slot-b green:28080 --legacy-slot blue:8080 --legacy-slot green:8081)
echo "server localhost:8080;" >"$WORKDIR/up.conf"
OUT=$("$DECIDE" --state-file "$WORKDIR/up.conf" "${LEGACY[@]}")
check "옛 a 슬롯 서빙 -> b 새 포트" "ACTIVE=blue ACTIVE_PORT=8080 INACTIVE=green INACTIVE_PORT=28080" "$OUT"
echo "server localhost:8081;" >"$WORKDIR/up.conf"
OUT=$("$DECIDE" --state-file "$WORKDIR/up.conf" "${LEGACY[@]}")
check "옛 b 슬롯 서빙 -> a 새 포트" "ACTIVE=green ACTIVE_PORT=8081 INACTIVE=blue INACTIVE_PORT=18080" "$OUT"

# 10. 전환 뒤 옛 슬롯 인자가 남아도 새 포트 판정이 이긴다
echo "server 127.0.0.1:28080;" >"$WORKDIR/up.conf"
OUT=$("$DECIDE" --state-file "$WORKDIR/up.conf" "${LEGACY[@]}")
check "새 포트가 옛 슬롯보다 우선" "ACTIVE=green ACTIVE_PORT=28080 INACTIVE=blue INACTIVE_PORT=18080" "$OUT"

# 11. 옛 슬롯 인자가 있어도 모르는 포트·상태 파일 없음은 부트스트랩
echo "server 127.0.0.1:9999;" >"$WORKDIR/up.conf"
OUT=$("$DECIDE" --state-file "$WORKDIR/up.conf" "${LEGACY[@]}")
check "옛 슬롯 인자 + 모르는 포트 -> 부트스트랩" "ACTIVE= ACTIVE_PORT= INACTIVE=blue INACTIVE_PORT=18080" "$OUT"
OUT=$("$DECIDE" --state-file "$WORKDIR/none.conf" "${LEGACY[@]}")
check "옛 슬롯 인자 + 상태 파일 없음 -> 부트스트랩" "ACTIVE= ACTIVE_PORT= INACTIVE=blue INACTIVE_PORT=18080" "$OUT"

# 12. 옛 슬롯 인자 오류
"$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:18080 --slot-b green:28080 --legacy-slot red:8080 >/dev/null 2>&1
check "슬롯 이름 밖의 옛 슬롯 -> exit 2" 2 "$?"
"$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:18080 --slot-b green:28080 --legacy-slot 'bl;ue:8080' >/dev/null 2>&1
check "허용목록 밖 옛 슬롯 이름 -> exit 2" 2 "$?"
"$DECIDE" --state-file "$WORKDIR/up.conf" --slot-a blue:18080 --slot-b green:28080 --legacy-slot blue >/dev/null 2>&1
check "콜론 없는 옛 슬롯 -> exit 2" 2 "$?"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES case(s) failed" >&2
  exit 1
fi

echo "all slot_decide.sh cases passed"
