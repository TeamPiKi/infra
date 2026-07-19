#!/usr/bin/env bash
#
# blocks/run_container.sh 셀프 테스트
#
# 로컬 docker 데몬으로 블록의 계약(종료 코드·기동 검증)을 실측한다.
# conventions/blocks.md 5번 원칙(셀프 검증 가능)의 실행체이며, CI 와 로컬에서 같은 스크립트로 돈다.
# 대상 이미지는 alpine 하나만 쓴다 (CI 러너에 docker 내장, pull 수 초).
#
# 실행: ./blocks/run_container.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_CONTAINER="$SCRIPT_DIR/run_container.sh"

# docker 없는 로컬(데몬 미기동 등)에서는 명시적으로 스킵한다. 단 CI 는 REQUIRE_DOCKER=1 로 불러
# 데몬 부재가 "케이스 0개 실행된 빈 통과" 로 위장되지 않게 실패시킨다.
if ! docker info >/dev/null 2>&1; then
  if [ "${REQUIRE_DOCKER:-0}" = "1" ]; then
    echo "FAIL: docker daemon unavailable (REQUIRE_DOCKER=1)" >&2
    exit 1
  fi
  echo "SKIP: docker daemon unavailable (CI 에서는 REQUIRE_DOCKER=1 로 강제 실행됨)" >&2
  exit 0
fi

PREFIX="rc-test-$$"
WORKDIR=$(mktemp -d)
cleanup() {
  docker ps -a --format '{{.Names}}' | grep "^$PREFIX" | xargs -r docker rm -f >/dev/null 2>&1
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# 케이스들이 이미지 pull 지연으로 위장 실패하지 않도록 미리 받아둔다.
docker pull -q alpine:3 >/dev/null || { echo "alpine pull failed" >&2; exit 1; }

FAILURES=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc (exit=$actual)"
  else
    echo "FAIL: $desc (expected=$expected actual=$actual)" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# 1. 필수 인자 누락 - name 없음
"$RUN_CONTAINER" --image alpine:3 --restart no >/dev/null 2>&1
check "name 없음 -> exit 2" 2 "$?"

# 1b. 필수 인자 누락 - restart 없음
"$RUN_CONTAINER" --name "$PREFIX-a" --image alpine:3 >/dev/null 2>&1
check "restart 없음 -> exit 2" 2 "$?"

# 2. 알 수 없는 인자
"$RUN_CONTAINER" --name "$PREFIX-a" --image alpine:3 --restart no --bogus x >/dev/null 2>&1
check "알 수 없는 인자 -> exit 2" 2 "$?"

# 2b. 값을 받는 옵션이 값 없이 끝남
"$RUN_CONTAINER" --image alpine:3 --restart no --name >/dev/null 2>&1
check "옵션 값 누락 -> exit 2" 2 "$?"

# 2c. verify-wait 비숫자
"$RUN_CONTAINER" --name "$PREFIX-a" --image alpine:3 --restart no --verify-wait abc >/dev/null 2>&1
check "verify-wait 비숫자 -> exit 2" 2 "$?"

# 3. env-file 경로가 존재하지 않음
"$RUN_CONTAINER" --name "$PREFIX-a" --image alpine:3 --restart no --env-file "$WORKDIR/absent.env" >/dev/null 2>&1
check "env-file 부재 -> exit 2" 2 "$?"

# 4. 정상 기동 (sleep 으로 살아있는 컨테이너)
"$RUN_CONTAINER" --name "$PREFIX-ok" --image alpine:3 --restart no --verify-wait 1 -- sleep 60 >/dev/null 2>&1
check "정상 기동 -> exit 0" 0 "$?"

# 5. 이름 충돌 (replace 없음) -> 기동 실패
"$RUN_CONTAINER" --name "$PREFIX-ok" --image alpine:3 --restart no --verify-wait 1 -- sleep 60 >/dev/null 2>&1
check "이름 충돌 + replace 없음 -> exit 1" 1 "$?"

# 6. --replace 로 같은 이름 재기동
"$RUN_CONTAINER" --name "$PREFIX-ok" --image alpine:3 --restart no --replace --verify-wait 1 -- sleep 60 >/dev/null 2>&1
check "replace 재기동 -> exit 0" 0 "$?"

# 7. 즉사 크래시 (컨테이너가 바로 종료) -> 검증 실패
"$RUN_CONTAINER" --name "$PREFIX-dead" --image alpine:3 --restart no --verify-wait 1 -- false >/dev/null 2>&1
check "즉사 크래시 -> exit 1" 1 "$?"

# 8. --env-file 이 실제로 컨테이너 env 에 반영된다
printf 'RC_TEST_KEY=hello\n' >"$WORKDIR/app.env"
"$RUN_CONTAINER" --name "$PREFIX-env" --image alpine:3 --restart no --env-file "$WORKDIR/app.env" --verify-wait 1 -- sleep 60 >/dev/null 2>&1
check "env-file 기동 -> exit 0" 0 "$?"
docker inspect -f '{{join .Config.Env "\n"}}' "$PREFIX-env" 2>/dev/null | grep -qx 'RC_TEST_KEY=hello'
check "env-file 값 반영" 0 "$?"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES case(s) failed" >&2
  exit 1
fi
echo "all cases passed"
