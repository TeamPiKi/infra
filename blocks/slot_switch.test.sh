#!/usr/bin/env bash
#
# blocks/slot_switch.sh 셀프 테스트
#
# nginx·systemctl·sudo 를 PATH 스텁으로 대체해 전환·원복 계약(종료 코드 + 상태 파일 내용)을
# 실측한다. 이 블록의 존재 이유가 "실패 시 원복"이므로, 각 실패 지점(-t·reload·verify)마다
# 상태 파일이 이전 값으로 돌아오는지를 검사한다. conventions/blocks.md 5번 원칙의 실행체.
#
# 실행: ./blocks/slot_switch.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCH="$SCRIPT_DIR/slot_switch.sh"

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ── PATH 스텁: 실패 주입은 FAKE_DIR 의 마커 파일로 제어한다 ──
mkdir -p "$WORKDIR/bin"
export FAKE_DIR="$WORKDIR"
cat >"$WORKDIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"$WORKDIR/bin/nginx" <<'EOF'
#!/usr/bin/env bash
[ -f "$FAKE_DIR/nginx_t_fail" ] && exit 1
exit 0
EOF
cat >"$WORKDIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/systemctl.log"
[ -f "$FAKE_DIR/systemctl_fail" ] && exit 1
exit 0
EOF
chmod +x "$WORKDIR/bin/sudo" "$WORKDIR/bin/nginx" "$WORKDIR/bin/systemctl"
export PATH="$WORKDIR/bin:$PATH"

STATE="$WORKDIR/upstream.conf"

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

reset_fakes() {
  rm -f "$FAKE_DIR/nginx_t_fail" "$FAKE_DIR/systemctl_fail" "$FAKE_DIR/systemctl.log"
}

# 1. 필수 인자 누락 / 알 수 없는 인자
"$SWITCH" --server 127.0.0.1:18091 >/dev/null 2>&1
check "state-file 없음 -> exit 2" 2 "$?"
"$SWITCH" --state-file "$STATE" >/dev/null 2>&1
check "server 없음 -> exit 2" 2 "$?"
"$SWITCH" --state-file "$STATE" --server x --bogus y >/dev/null 2>&1
check "알 수 없는 인자 -> exit 2" 2 "$?"

# 2. 정상 전환: 상태 파일 갱신 + reload 수행
reset_fakes
echo "server 127.0.0.1:18090;" >"$STATE"
"$SWITCH" --state-file "$STATE" --server 127.0.0.1:18091 >/dev/null 2>&1
check "정상 전환 -> exit 0" 0 "$?"
check "정상 전환 -> 상태 파일 갱신" "server 127.0.0.1:18091;" "$(cat "$STATE")"
grep -q "reload nginx" "$FAKE_DIR/systemctl.log"
check "정상 전환 -> reload 호출" 0 "$?"

# 3. nginx -t 실패 -> 원복
reset_fakes
echo "server 127.0.0.1:18090;" >"$STATE"
touch "$FAKE_DIR/nginx_t_fail"
"$SWITCH" --state-file "$STATE" --server 127.0.0.1:18091 >/dev/null 2>&1
check "-t 실패 -> exit 1" 1 "$?"
check "-t 실패 -> 상태 파일 원복" "server 127.0.0.1:18090;" "$(cat "$STATE")"

# 4. reload·restart 모두 실패 -> 원복
reset_fakes
echo "server 127.0.0.1:18090;" >"$STATE"
touch "$FAKE_DIR/systemctl_fail"
"$SWITCH" --state-file "$STATE" --server 127.0.0.1:18091 >/dev/null 2>&1
check "reload/restart 실패 -> exit 1" 1 "$?"
check "reload/restart 실패 -> 상태 파일 원복" "server 127.0.0.1:18090;" "$(cat "$STATE")"

# 5. verify 실패 -> 원복 + 원복 반영 reload
reset_fakes
echo "server 127.0.0.1:18090;" >"$STATE"
"$SWITCH" --state-file "$STATE" --server 127.0.0.1:18091 --verify-cmd "false" >/dev/null 2>&1
check "verify 실패 -> exit 1" 1 "$?"
check "verify 실패 -> 상태 파일 원복" "server 127.0.0.1:18090;" "$(cat "$STATE")"
check "verify 실패 -> reload 2회(전환+원복)" 2 "$(grep -c "reload nginx" "$FAKE_DIR/systemctl.log")"

# 6. verify 성공 -> 전환 유지
reset_fakes
echo "server 127.0.0.1:18090;" >"$STATE"
"$SWITCH" --state-file "$STATE" --server 127.0.0.1:18091 --verify-cmd "true" >/dev/null 2>&1
check "verify 성공 -> exit 0" 0 "$?"
check "verify 성공 -> 상태 파일 유지" "server 127.0.0.1:18091;" "$(cat "$STATE")"

# 7. 부트스트랩(-t 실패, 이전 상태 없음) -> 원복 대상 없음, 새 값 유지 + exit 1
reset_fakes
rm -f "$STATE"
touch "$FAKE_DIR/nginx_t_fail"
"$SWITCH" --state-file "$STATE" --server 127.0.0.1:18090 >/dev/null 2>&1
check "부트스트랩 -t 실패 -> exit 1" 1 "$?"
check "부트스트랩 -t 실패 -> 새 값 유지(원복 대상 없음)" "server 127.0.0.1:18090;" "$(cat "$STATE")"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES case(s) failed" >&2
  exit 1
fi

echo "all slot_switch.sh cases passed"
