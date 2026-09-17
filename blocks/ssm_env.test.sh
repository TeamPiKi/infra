#!/usr/bin/env bash
#
# blocks/ssm_env.sh 셀프 테스트
#
# aws 없이 stdin JSON 픽스처로 성공·실패·인자오류 경로를 실측한다.
# conventions/blocks.md 5번 원칙(셀프 검증 가능)의 실행체.
#
# 실행: ./blocks/ssm_env.test.sh
#
# shellcheck disable=SC2016  # 단일 인용부 안의 $HOME 은 "해석하지 않음" 을 검증하는 픽스처다

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCK="$SCRIPT_DIR/ssm_env.sh"

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

params() {
  # 인자: Name Value 쌍 반복. aws ssm get-parameters-by-path --output json 모양을 만든다.
  python3 -c '
import json, sys
a = sys.argv[1:]
print(json.dumps({"Parameters": [{"Name": a[i], "Value": a[i+1]} for i in range(0, len(a), 2)]}))' "$@"
}

OUT="$WORKDIR/app.env"

# 1. 인자 오류
echo '{}' | "$BLOCK" >/dev/null 2>&1
check "--out 없음 -> exit 2" 2 "$?"
echo '{}' | "$BLOCK" --out "$OUT" --bogus >/dev/null 2>&1
check "알 수 없는 인자 -> exit 2" 2 "$?"
echo '{}' | "$BLOCK" --out "$OUT" --reserve >/dev/null 2>&1
check "--reserve 값 없음 -> exit 2" 2 "$?"

# 2. 성공: kebab -> UPPER_SNAKE, 값은 바이트 그대로 (따옴표·$·=·공백·문자 백슬래시-n)
COUNT=$(params /piki-x/app/gemini-api-key 'abc' \
               /piki-x/app/redis-host 'host with space' \
               /piki-x/app/odd-value 'a=b "q" $HOME' \
               /piki-x/app/apple-private-key '-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----' \
        | "$BLOCK" --out "$OUT")
check "성공 -> exit 0 · 줄 수 4" 4 "$COUNT"
check "kebab -> UPPER_SNAKE" "GEMINI_API_KEY=abc" "$(sed -n 1p "$OUT")"
check "공백 보존" "REDIS_HOST=host with space" "$(sed -n 2p "$OUT")"
check "따옴표·\$·= 해석 없음" 'ODD_VALUE=a=b "q" $HOME' "$(sed -n 3p "$OUT")"
check "문자 백슬래시-n 은 한 줄로 통과" 'APPLE_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----' "$(sed -n 4p "$OUT")"
check "파일 줄 수 = 파라미터 수" 4 "$(grep -c '' "$OUT")"
PERM=$(stat -c '%a' "$OUT" 2>/dev/null || stat -f '%Lp' "$OUT")
check "파일 권한 600" 600 "$PERM"

# 3. 값은 stdout 에 나오지 않는다
STDOUT=$(params /piki-x/app/secret 'TOPSECRET' | "$BLOCK" --out "$OUT" 2>&1)
case "$STDOUT" in *TOPSECRET*) check "값 stdout 누출 없음" "no-leak" "leaked";; *) check "값 stdout 누출 없음" "no-leak" "no-leak";; esac

# 4. 파라미터 0개 -> exit 1, 기존 파일은 남지 않아야 함 (덮어쓰기 실패가 이전 배포 값을 태우지 않게)
rm -f "$OUT"
echo '{"Parameters": []}' | "$BLOCK" --out "$OUT" >/dev/null 2>&1
check "0개 -> exit 1" 1 "$?"
[ -e "$OUT" ] && EXISTS=yes || EXISTS=no
check "0개 실패 시 출력 파일 없음" no "$EXISTS"

# 5. 실제 개행 값 -> exit 1
params /piki-x/app/pem "$(printf 'line1\nline2')" | "$BLOCK" --out "$OUT" >/dev/null 2>&1
check "실제 개행 값 -> exit 1" 1 "$?"
params /piki-x/app/pem "$(printf 'line1\r')" | "$BLOCK" --out "$OUT" >/dev/null 2>&1
check "CR 포함 값 -> exit 1" 1 "$?"

# 6. 예약 이름 충돌 -> exit 1 (복원된 UPPER_SNAKE 기준)
params /piki-x/app/image-tag 'x' | "$BLOCK" --out "$OUT" --reserve IMAGE_TAG --reserve ENVIRONMENT >/dev/null 2>&1
check "예약 이름 충돌 -> exit 1" 1 "$?"
COUNT=$(params /piki-x/app/image-tag 'x' | "$BLOCK" --out "$OUT" --reserve ENVIRONMENT)
check "예약 목록에 없으면 통과" 1 "$COUNT"

# 7. JSON 아님 -> exit 1
echo 'not json' | "$BLOCK" --out "$OUT" >/dev/null 2>&1
check "JSON 아님 -> exit 1" 1 "$?"

# 8. 실패 시 임시 파일 잔재 없음
ls "$WORKDIR"/app.env.* >/dev/null 2>&1 && LEFT=yes || LEFT=no
check "임시 파일 잔재 없음" no "$LEFT"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAILURES FAILED" >&2
  exit 1
fi
