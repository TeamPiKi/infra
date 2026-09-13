#!/usr/bin/env bash
#
# blocks/prune_images.sh 셀프 테스트
#
# 다른 블록 테스트와 달리 **실제 docker 데몬을 쓰지 않는다.** 이 블록은 `docker image prune -af`
# 로 쓰지 않는 이미지를 전부 지우므로, 진짜 데몬에 물리면 개발자 로컬·CI 러너의 남의 이미지까지
# 날린다. PATH 앞에 가짜 `docker`·`df` 를 놓고 인자 판정·여유 가드·종료 코드만 실측한다
# (conventions/blocks.md 5번 원칙 - 실제 인프라 없이 검증 가능).
#
# 실행: ./blocks/prune_images.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRUNE="$SCRIPT_DIR/prune_images.sh"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/bin"

# 가짜 docker: 호출 인자를 로그에 남기고 FAKE_DOCKER_EXIT 로 끝난다.
cat >"$WORKDIR/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DOCKER_LOG"
exit "${FAKE_DOCKER_EXIT:-0}"
FAKE

# 가짜 df: FAKE_FREE_MB 의 콤마 목록을 호출 순서대로 돌려준다(정리 전 -> 정리 후).
# FAKE_DF_FAIL=1 이면 df 자체가 실패하는 상황을 만든다.
cat >"$WORKDIR/bin/df" <<'FAKE'
#!/usr/bin/env bash
[ "${FAKE_DF_FAIL:-0}" = "1" ] && exit 1
n=0
[ -f "$FAKE_DF_COUNT" ] && n=$(cat "$FAKE_DF_COUNT")
n=$((n + 1))
echo "$n" >"$FAKE_DF_COUNT"
val=$(printf '%s' "$FAKE_FREE_MB" | cut -d, -f"$n")
[ -n "$val" ] || val=$(printf '%s' "$FAKE_FREE_MB" | cut -d, -f1)
echo "Filesystem 1M-blocks Used Available Capacity Mounted on"
echo "/dev/root 19000 18000 $val 95% /"
FAKE

chmod +x "$WORKDIR/bin/docker" "$WORKDIR/bin/df"
export PATH="$WORKDIR/bin:$PATH"
export FAKE_DOCKER_LOG="$WORKDIR/docker.log"
export FAKE_DF_COUNT="$WORKDIR/df.count"

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

# 케이스마다 가짜들의 상태를 초기화한다 - 안 하면 앞 케이스의 df 호출 횟수가 다음 케이스의
# "정리 전/후" 값을 밀어 엉뚱한 수치로 판정한다.
reset() {
  : >"$FAKE_DOCKER_LOG"
  rm -f "$FAKE_DF_COUNT"
  unset FAKE_DOCKER_EXIT FAKE_DF_FAIL
  export FAKE_FREE_MB="$1"
}

# --- 인자 오류 (exit 2) ---

reset "9000"
"$PRUNE" >/dev/null 2>&1
check "min-free-gb 없음 -> exit 2" 2 "$?"

"$PRUNE" --min-free-gb 2 --bogus x >/dev/null 2>&1
check "알 수 없는 인자 -> exit 2" 2 "$?"

"$PRUNE" --min-free-gb >/dev/null 2>&1
check "min-free-gb 값 누락 -> exit 2" 2 "$?"

"$PRUNE" --min-free-gb 2.5 >/dev/null 2>&1
check "min-free-gb 비정수 -> exit 2" 2 "$?"

"$PRUNE" --min-free-gb -1 >/dev/null 2>&1
check "min-free-gb 음수 -> exit 2" 2 "$?"

# --- 정상 경로 ---

# 정리 전 500MB(부족) -> 정리 후 5000MB(충분). 기준 2GB=2048MB.
reset "500,5000"
"$PRUNE" --min-free-gb 2 >/dev/null 2>&1
check "정리로 여유 확보 -> exit 0" 0 "$?"
if grep -qF -- "image prune -af" "$FAKE_DOCKER_LOG"; then
  echo "PASS: prune -af 를 실제로 호출한다"
else
  echo "FAIL: prune -af 호출 기록이 없다 ($(cat "$FAKE_DOCKER_LOG"))" >&2
  FAILURES=$((FAILURES + 1))
fi

# 정리해도 1000MB 뿐 -> 기준 2GB 미만이라 pull 앞에서 끊어야 한다.
reset "800,1000"
"$PRUNE" --min-free-gb 2 >/dev/null 2>&1
check "정리 후에도 부족 -> exit 1" 1 "$?"

# 경계: 정확히 기준과 같으면 통과한다(미만일 때만 실패).
reset "100,2048"
"$PRUNE" --min-free-gb 2 >/dev/null 2>&1
check "여유 == 기준 -> exit 0" 0 "$?"

# --- dry-run ---

reset "5000"
"$PRUNE" --min-free-gb 2 --dry-run >/dev/null 2>&1
check "dry-run 여유 충분 -> exit 0" 0 "$?"
if [ -s "$FAKE_DOCKER_LOG" ]; then
  echo "FAIL: dry-run 인데 docker 를 호출했다 ($(cat "$FAKE_DOCKER_LOG"))" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: dry-run 은 docker 를 호출하지 않는다"
fi

reset "500"
"$PRUNE" --min-free-gb 2 --dry-run >/dev/null 2>&1
check "dry-run 여유 부족 -> exit 1" 1 "$?"

# --- 실패 내성 ---

# prune 이 실패해도 여유가 충분하면 배포를 막지 않는다(판정의 근거는 공간이지 prune 성공이 아니다).
reset "5000,5000"
export FAKE_DOCKER_EXIT=1
"$PRUNE" --min-free-gb 2 >/dev/null 2>&1
check "prune 실패 + 여유 충분 -> exit 0" 0 "$?"

# df 를 못 읽으면 조용히 통과시키지 않는다.
reset "5000"
export FAKE_DF_FAIL=1
"$PRUNE" --min-free-gb 2 >/dev/null 2>&1
check "df 측정 실패 -> exit 1" 1 "$?"

if [ "$FAILURES" -gt 0 ]; then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "all prune_images cases passed"
