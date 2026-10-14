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

# 5. 옛 슬롯: 옛 blue(8090)가 서빙 중이면 green 새 포트로 배포하고 옛 blue 를 내린다
echo "server 127.0.0.1:8090;" > "$STATE"
OUT=$(run_block --legacy-slot blue:8090 --legacy-slot green:8091 -- --image img:1)
check "옛 슬롯 -> exit 0" 0 "$?"
check "옛 슬롯 결과 줄" "DEPLOYED slot=green port=18091 previous=blue" "$(printf '%s\n' "$OUT" | tail -1)"
check "옛 슬롯: 서빙 중인 blue 는 전환 뒤에만 내림" \
  "docker stop -t 30 piki-x-green|docker rm -f piki-x-green|docker stop -t 30 piki-x-blue|docker rm -f piki-x-blue" \
  "$(grep '^docker' "$CALLS" | tr '\n' '|' | sed 's/|$//')"

# 6. 옛 슬롯 인자 없이 같은 상태면 부트스트랩이라 서빙 중인 blue 를 기동 전에 지운다 (이 인자가 막는 사고)
echo "server 127.0.0.1:8090;" > "$STATE"
OUT=$(run_block -- --image img:1)
check "옛 슬롯 인자 없음: 서빙 중인 blue 를 기동 전에 정리" "docker stop -t 30 piki-x-blue" "$(line_of docker)"

# 7. --service-port: 슬롯·컨테이너 포트·PORT env 를 블록이 계산
run_service_port() {
  : > "$CALLS"
  "$BLOCK" --state-file "$STATE" --name-prefix piki-x \
    --health-path /health --health-interval 5 --health-attempts 3 \
    --verify-cmd "verify-front" --blocks-dir "$FAKES" "$@"
}
echo "server 127.0.0.1:28082;" > "$STATE"
OUT=$(run_service_port --service-port 8082 -- --image img:1)
check "서비스 포트 -> exit 0" 0 "$?"
check "서비스 포트 결과 줄 (green 서빙 중이라 blue)" "DEPLOYED slot=blue port=18082 previous=green" "$(printf '%s\n' "$OUT" | tail -1)"
check "서비스 포트: publish·라벨·PORT env 를 블록이 채움" \
  "run_container --name piki-x-blue --publish 127.0.0.1:18082:8082 --label piki.metrics.port=18082 --env PORT --image img:1" \
  "$(line_of run_container)"

# 기록용 가짜는 인자만 남기므로, 블록이 export 한 PORT 값은 env 를 찍는 가짜로 따로 본다
cat > "$WORKDIR/env_probe.sh" <<'EOF'
#!/usr/bin/env bash
echo "PORT=${PORT:-}" >> "$CALLS"
EOF
cp "$FAKES/run_container.sh" "$WORKDIR/run_container.orig"
cp "$WORKDIR/env_probe.sh" "$FAKES/run_container.sh"
run_service_port --service-port 8082 -- --image img:1 >/dev/null 2>&1
check "서비스 포트: run_container 가 PORT 값을 받음" "PORT=8082" "$(line_of PORT=)"
cp "$WORKDIR/run_container.orig" "$FAKES/run_container.sh"

run_service_port --service-port 8082 --slot-a blue:18082 -- --image img:1 >/dev/null 2>&1
check "서비스 포트와 옛 슬롯 인자 동시 사용 -> exit 2" 2 "$?"
run_service_port --service-port 80820 -- --image img:1 >/dev/null 2>&1
check "다섯 자리 서비스 포트 -> exit 2" 2 "$?"

echo "server 127.0.0.1:18090;" > "$STATE"
OUT=$(run_service_port --service-port 8081 --legacy-slot blue:18090 --legacy-slot green:18091 -- --image img:1)
check "서비스 포트 + 옛 슬롯 -> 옛 blue 서빙 중이면 새 green" "DEPLOYED slot=green port=28081 previous=blue" "$(printf '%s\n' "$OUT" | tail -1)"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAILURES FAILED" >&2
  exit 1
fi
