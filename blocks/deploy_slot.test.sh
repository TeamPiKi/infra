#!/usr/bin/env bash
#
# blocks/deploy_slot.sh 셀프 테스트
#
# 형제 블록과 docker 를 가짜로 바꿔 끼워 조립 논리만 실측한다: 호출 순서, 블록이 채우는 인자,
# 실패 지점별 정리, 부트스트랩. 잎 블록 각각의 동작은 그 블록의 셀프 테스트가 맡는다.
# conventions/blocks.md 5번 원칙(셀프 검증 가능)의 실행체.
#
# 실행: ./blocks/deploy_slot.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCK="$SCRIPT_DIR/deploy_slot.sh"

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

FAKES="$WORKDIR/blocks"
BIN="$WORKDIR/bin"
CALLS="$WORKDIR/calls.log"
mkdir -p "$FAKES" "$BIN"

# 가짜 형제 블록: 이름과 인자를 기록하고, 환경변수 FAIL_<이름>=1 이면 exit 1
for b in run_container healthcheck slot_switch; do
  cat > "$FAKES/$b.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "$b" >> "\$CALLS"; for a in "\$@"; do printf ' %s' "\$a" >> "\$CALLS"; done; echo >> "\$CALLS"
[ "\${FAIL_$b:-0}" = "1" ] && exit 1
exit 0
EOF
  chmod +x "$FAKES/$b.sh"
done
# slot_decide 는 진짜 블록을 쓴다 (상태 파일 -> 판정이 이 조립의 입력이라 실제 계약으로 검증)
cp "$SCRIPT_DIR/slot_decide.sh" "$FAKES/slot_decide.sh"

# 가짜 docker: 호출을 기록만 한다
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker' >> "$CALLS"; for a in "$@"; do printf ' %s' "$a" >> "$CALLS"; done; echo >> "$CALLS"
exit 0
EOF
chmod +x "$BIN/docker"
export PATH="$BIN:$PATH" CALLS

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
calls_of() { grep -c "^$1" "$CALLS" 2>/dev/null || true; }
line_of() { grep -m1 "^$1" "$CALLS" 2>/dev/null || true; }

STATE="$WORKDIR/upstream.conf"
run_block() {
  : > "$CALLS"
  "$BLOCK" --state-file "$STATE" --slot-a blue:18090 --slot-b green:18091 \
    --name-prefix piki-x --container-port 8090 \
    --health-path /actuator/health --health-interval 5 --health-attempts 3 --health-expect-body '"status":"UP"' \
    --verify-cmd "verify-front" --blocks-dir "$FAKES" "$@"
}

# 1. 인자 오류
"$BLOCK" --slot-a blue:18090 >/dev/null 2>&1
check "필수 인자 누락 -> exit 2" 2 "$?"
"$BLOCK" --state-file "$STATE" --slot-a blue:18090 --slot-b green:18091 --name-prefix x --container-port 80x0 \
  --health-path /h --health-interval 1 --health-attempts 1 --verify-cmd v --blocks-dir "$FAKES" >/dev/null 2>&1
check "비숫자 container-port -> exit 2" 2 "$?"
run_block -- --image img --name mine >/dev/null 2>&1
check "-- 뒤 --name 은 거부 -> exit 2" 2 "$?"
run_block --blocks-dir "$WORKDIR/nowhere" -- --image img >/dev/null 2>&1
check "형제 블록 없음 -> exit 2" 2 "$?"

# 2. 성공 경로 (green 이 서빙 중 -> blue 로 배포)
echo "server 127.0.0.1:18091;" > "$STATE"
OUT=$(run_block --log-dir "$WORKDIR/logs" -- --image img:1 --restart unless-stopped --env-file /tmp/e --memory 640m)
check "성공 -> exit 0" 0 "$?"
check "결과 줄" "DEPLOYED slot=blue port=18090 previous=green" "$(printf '%s\n' "$OUT" | tail -1)"
check "호출 순서 (logs·잔재 stop·rm, 기동, 헬스, 전환, 구 슬롯 stop·rm)" "docker docker docker run_container healthcheck slot_switch docker docker" \
  "$(awk '{print $1}' "$CALLS" | tr '\n' ' ' | sed 's/ $//')"
check "run_container 에 이름·publish·메트릭 라벨을 블록이 채움 + passthrough 보존" \
  "run_container --name piki-x-blue --publish 127.0.0.1:18090:8090 --label piki.metrics.port=18090 --image img:1 --restart unless-stopped --env-file /tmp/e --memory 640m" \
  "$(line_of run_container)"
check "슬롯 헬스 URL·값" \
  'healthcheck --url http://127.0.0.1:18090/actuator/health --interval 5 --attempts 3 --expect-body "status":"UP"' \
  "$(line_of healthcheck)"
check "slot_switch 인자" "slot_switch --state-file $STATE --server 127.0.0.1:18090 --verify-cmd verify-front" "$(line_of slot_switch)"
check "잔재 정리는 새 슬롯, teardown 은 구 슬롯" \
  "docker logs piki-x-blue|docker stop -t 30 piki-x-blue|docker rm -f piki-x-blue|docker stop -t 30 piki-x-green|docker rm -f piki-x-green" \
  "$(grep '^docker' "$CALLS" | tr '\n' '|' | sed 's/|$//')"
check "로그 덤프 파일 생성" 1 "$(find "$WORKDIR/logs" -name 'piki-x-blue-*.log' | wc -l | tr -d ' ')"

# 3. 부트스트랩: 상태 파일 없음 -> slot-a 로 배포, teardown 없음
rm -f "$STATE"
OUT=$(run_block -- --image img:1)
check "부트스트랩 -> exit 0" 0 "$?"
check "부트스트랩 결과 줄" "DEPLOYED slot=blue port=18090 previous=none" "$(printf '%s\n' "$OUT" | tail -1)"
check "부트스트랩은 docker logs 없이 잔재 정리 2회뿐" 2 "$(calls_of docker)"

# 4. 실패 경로: 각 단계 실패 시 새 슬롯 정리, 이전 슬롯은 건드리지 않음, exit 1
echo "server 127.0.0.1:18091;" > "$STATE"
FAIL_run_container=1 run_block -- --image img:1 >/dev/null 2>&1
check "기동 실패 -> exit 1" 1 "$?"
check "기동 실패: healthcheck·switch 호출 없음" 0 "$(( $(calls_of healthcheck) + $(calls_of slot_switch) ))"
check "기동 실패: 새 슬롯 정리, 구 슬롯 무접촉" 0 "$(grep -c 'piki-x-green' "$CALLS")"

FAIL_healthcheck=1 run_block -- --image img:1 >/dev/null 2>&1
check "슬롯 헬스 실패 -> exit 1" 1 "$?"
check "헬스 실패: switch 호출 없음" 0 "$(calls_of slot_switch)"
check "헬스 실패: 새 슬롯 rm 2회(잔재+정리), 구 슬롯 무접촉" "2 0" "$(grep -c 'rm -f piki-x-blue' "$CALLS") $(grep -c 'piki-x-green' "$CALLS")"

FAIL_slot_switch=1 run_block -- --image img:1 >/dev/null 2>&1
check "전환 실패 -> exit 1" 1 "$?"
check "전환 실패: 새 슬롯 정리, 구 슬롯 무접촉" "2 0" "$(grep -c 'rm -f piki-x-blue' "$CALLS") $(grep -c 'piki-x-green' "$CALLS")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAILURES FAILED" >&2
  exit 1
fi
