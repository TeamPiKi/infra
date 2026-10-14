#!/usr/bin/env bash
#
# blocks/egress_wall.sh 셀프 테스트
#
# 인자 오류는 어디서나 돈다. 벽 동작은 실제 커널 규칙으로 봐야 해서 privileged dind 컨테이너 안에 운영 서버를
# 흉내 낸다: dind 가 서버, 안쪽 docker 의 컨테이너가 앱, 별도 netns 가 VPC·인터넷이다. docker 가 없으면
# 건너뛰고 REQUIRE_DOCKER=1 이면 실패로 본다 (run_container.test.sh 와 같은 규칙).
#
# 실행: ./blocks/egress_wall.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
BLOCK="$SCRIPT_DIR/egress_wall.sh"
RANGES="$INFRA_DIR/contracts/internal-ranges.txt"
# 운영 서버와 같은 Docker 버전이어야 DOCKER-USER 를 다루는 방식까지 같다.
DIND_IMAGE="docker:29.8.1-dind"

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

# --- 인자 오류 (exit 2) ---

"$BLOCK" >/dev/null 2>&1
check "ranges-file 누락 -> exit 2" 2 "$?"

"$BLOCK" --ranges-file >/dev/null 2>&1
check "ranges-file 값 누락 -> exit 2" 2 "$?"

"$BLOCK" --ranges-file /nonexistent >/dev/null 2>&1
check "없는 ranges-file -> exit 2" 2 "$?"

"$BLOCK" --ranges-file "$RANGES" --bogus x >/dev/null 2>&1
check "알 수 없는 인자 -> exit 2" 2 "$?"

"$BLOCK" --ranges-file "$RANGES" --allow-tcp 10.0.1.230 >/dev/null 2>&1
check "allow-tcp 포트 누락 -> exit 2" 2 "$?"

"$BLOCK" --ranges-file "$RANGES" --allow-tcp renderer:8082 >/dev/null 2>&1
check "allow-tcp 이름 -> exit 2" 2 "$?"

BAD_RANGES=$(mktemp)
trap 'rm -f "$BAD_RANGES"' EXIT
printf '10.0.0.0/8\nnot-a-range\n' >"$BAD_RANGES"
"$BLOCK" --ranges-file "$BAD_RANGES" >/dev/null 2>&1
check "ranges 에 깨진 줄 -> exit 2" 2 "$?"

printf '# only comments\n::1/128\n' >"$BAD_RANGES"
"$BLOCK" --ranges-file "$BAD_RANGES" >/dev/null 2>&1
check "IPv4 대역 0개 -> exit 2" 2 "$?"

# --- 실제 커널 ---

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  if [ "${REQUIRE_DOCKER:-0}" = "1" ]; then
    echo "FAIL: REQUIRE_DOCKER=1 인데 docker 데몬에 닿지 못한다" >&2
    exit 1
  fi
  echo "SKIP: docker 없음 - 벽 동작 시험을 건너뛴다"
  [ "$FAILURES" -eq 0 ] || exit 1
  exit 0
fi

NAME="piki-wall-test-$$"
# 안쪽 docker 의 기본 bridge(172.17.0.0/16)와 겹치지 않는 대역에 dind 를 둔다.
docker network create --subnet 192.168.234.0/24 "$NAME" >/dev/null
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker network rm "$NAME" >/dev/null 2>&1
  rm -f "$BAD_RANGES"
}
trap cleanup EXIT

docker run -d --privileged --name "$NAME" --network "$NAME" -e DOCKER_TLS_CERTDIR= \
  -v "$INFRA_DIR:/infra:ro" --entrypoint sleep "$DIND_IMAGE" infinity >/dev/null

# 시나리오는 파일로 넘겨 실행한다. stdin 으로 흘리면 안의 명령이 남은 스크립트를 읽어 삼킬 수 있다.
docker exec -i "$NAME" sh -c 'cat >/tmp/scenario.sh' <<'SCENARIO'
set -uo pipefail
FAILURES=0
pass() { echo "PASS: $1"; }
failed() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
expect() { local desc="$1" want="$2"; shift 2; if "$@" >/dev/null 2>&1; then got=0; else got=1; fi; [ "$got" = "$want" ] && pass "$desc" || failed "$desc"; }
reach() { docker exec probe nc -z -w 2 "$1" "$2"; }

start_dockerd() {
  dockerd-entrypoint.sh dockerd >>/var/log/dockerd.log 2>&1 &
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && return 0; sleep 1; done
  echo "dockerd 기동 실패" >&2; tail -20 /var/log/dockerd.log >&2; exit 1
}
stop_dockerd() {
  kill "$(pidof dockerd)" 2>/dev/null
  for _ in $(seq 1 60); do pidof dockerd >/dev/null || return 0; sleep 1; done
}
wait_running() {
  for _ in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] && return 0; sleep 1; done
  return 1
}
apply() { bash /infra/blocks/egress_wall.sh --ranges-file /infra/contracts/internal-ranges.txt --allow-tcp 10.0.1.230:8082; }
snapshot() { for c in DOCKER-USER PIKI-WALL-OUT PIKI-WALL-HOST PIKI-WALL-DENY INPUT; do iptables -S "$c" 2>&1; done; }

start_dockerd
docker pull -q alpine:3 >/dev/null

# VPC·인터넷 역할 netns. 목적지 주소를 lo 에 두고 모든 주소에서 같은 포트로 응답한다.
ip netns add vpc
ip link add vpc0 type veth peer name vpc1
ip link set vpc1 netns vpc
ip addr add 192.0.2.1/30 dev vpc0 && ip link set vpc0 up
ip netns exec vpc sh -c 'ip addr add 192.0.2.2/30 dev vpc1 && ip link set vpc1 up && ip link set lo up && ip route add default via 192.0.2.1'
for a in 10.0.0.2 10.0.1.230 10.0.1.45 169.254.169.254 169.254.169.253 203.0.113.10; do ip netns exec vpc ip addr add "$a/32" dev lo; done
for r in 10.0.0.0/16 169.254.169.0/24 203.0.113.10/32; do ip route add "$r" via 192.0.2.2; done
cat >/tmp/listen.py <<'PY'
import socket, sys, threading
def tcp(port):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0", port)); s.listen(64)
    while True:
        c, _ = s.accept(); c.close()
def udp(port):
    # 0.0.0.0 에 묶으면 답의 출발 주소가 라우팅으로 바뀌어 conntrack 이 짝을 못 찾는다.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("10.0.0.2", port))
    while True:
        d, a = s.recvfrom(512); s.sendto(d, a)
for p in sys.argv[1].split(","):
    threading.Thread(target=tcp, args=(int(p),), daemon=True).start()
if len(sys.argv) > 2:
    threading.Thread(target=udp, args=(int(sys.argv[2]),), daemon=True).start()
threading.Event().wait()
PY
ip netns exec vpc python3 /tmp/listen.py 53,80,443,3306,8082 53 &
# 서버 자신의 포트: Alloy OTLP(4318) 와 sshd(22) 역할.
python3 /tmp/listen.py 4318,22 &
sleep 1

# 이후 만드는 컨테이너는 이 nameserver 를 받는다 (운영 서버의 VPC 리졸버 10.0.0.2 와 같은 자리).
echo 'nameserver 10.0.0.2' >/etc/resolv.conf

docker run -d --name probe --restart unless-stopped -p 127.0.0.1:18081:8081 alpine:3 sh -c \
  'nc -lk -p 8081 -e echo ok & nc -lk -s 127.0.0.1 -p 7000 -e echo ok & exec sleep infinity' >/dev/null
docker run -d --name peer --restart unless-stopped alpine:3 sh -c 'nc -lk -p 9000 -e echo ok & exec sleep infinity' >/dev/null
wait_running probe && wait_running peer
PEER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' peer)
GW=172.17.0.1
sleep 1

echo "--- 벽 전 (테스트 장치 확인)"
expect "벽 전: VPC 의 다른 서버 10.0.1.45:3306 에 닿음" 0 reach 10.0.1.45 3306
expect "벽 전: 서버 sshd 172.17.0.1:22 에 닿음" 0 reach "$GW" 22
expect "벽 전: 옆 컨테이너에 닿음" 0 reach "$PEER_IP" 9000

echo "--- 벽 적용"
apply; [ $? -eq 0 ] && pass "블록 exit 0 (동작 확인 포함)" || failed "블록 exit 0"
[ -f /etc/piki/egress-wall.rules ] && [ -x /usr/local/sbin/piki-egress-wall ] && pass "규칙 파일·적용 스크립트 설치" || failed "규칙 파일·적용 스크립트 설치"

echo "--- 허용"
expect "인터넷 203.0.113.10:443" 0 reach 203.0.113.10 443
expect "DNS 10.0.0.2:53/tcp" 0 reach 10.0.0.2 53
# 답이 오기 전에 stdin 이 닫히면 nc 가 먼저 끝나 1초 붙들어 둔다.
expect "DNS 10.0.0.2:53/udp 왕복" 0 sh -c 'docker exec probe sh -c "(echo hi; sleep 1) | nc -u -w 2 10.0.0.2 53" | grep -q hi'
expect "메타데이터 169.254.169.254:80" 0 reach 169.254.169.254 80
expect "서비스 예외 10.0.1.230:8082" 0 reach 10.0.1.230 8082
expect "서버 Alloy OTLP 172.17.0.1:4318" 0 reach "$GW" 4318
expect "서버 Alloy OTLP 를 서버 다른 주소로 192.0.2.1:4318" 0 reach 192.0.2.1 4318
expect "서버에서 컨테이너 공개 포트로 들어오는 연결" 0 nc -z -w 2 127.0.0.1 18081
expect "컨테이너 자기 loopback 은 벽 밖 (막지 못함을 확인)" 0 docker exec probe nc -z -w 2 127.0.0.1 7000

echo "--- 차단"
expect "예외 서버의 다른 포트 10.0.1.230:3306" 1 reach 10.0.1.230 3306
expect "VPC 의 다른 서버 10.0.1.45:3306" 1 reach 10.0.1.45 3306
expect "링크 로컬의 다른 주소 169.254.169.253:53" 1 reach 169.254.169.253 53
expect "메타데이터의 다른 포트 169.254.169.254:8082" 1 reach 169.254.169.254 8082
expect "서버 sshd 172.17.0.1:22" 1 reach "$GW" 22
expect "서버 sshd 를 서버 다른 주소로 192.0.2.1:22" 1 reach 192.0.2.1 22
expect "옆 컨테이너" 1 reach "$PEER_IP" 9000
# docker exec 지연이 섞이지 않게 컨테이너 안에서 잰다. 버리기(DROP)였다면 -w 3 을 다 기다린다.
real=$(docker exec probe sh -c 'time nc -z -w 3 10.0.1.45 3306' 2>&1 | awk '/^real/ {print $2 $3}')
[[ "$real" == 0m0.* ]] && pass "거절이 즉시 돌아옴 (${real})" || failed "거절이 즉시 돌아옴 (${real})"
journal=$(dmesg 2>/dev/null | grep -c 'piki-wall: ' || true)
echo "INFO: 커널 로그의 piki-wall 줄 ${journal}개 (컨테이너 커널 정책에 따라 0 일 수 있음)"

echo "--- 멱등"
before=$(snapshot); apply >/dev/null; after=$(snapshot)
[ "$before" = "$after" ] && pass "두 번 적용해도 규칙 동일" || { failed "두 번 적용해도 규칙 동일"; diff <(echo "$before") <(echo "$after") >&2; }

echo "--- Docker 재시작"
stop_dockerd; start_dockerd; wait_running probe
expect "재시작 뒤 VPC 의 다른 서버 차단 유지" 1 reach 10.0.1.45 3306
expect "재시작 뒤 인터넷 허용 유지" 0 reach 203.0.113.10 443

echo "--- 재부팅 흉내 (규칙 전부 비움, 적용 스크립트를 Docker 보다 먼저)"
stop_dockerd
iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X
/usr/local/sbin/piki-egress-wall && pass "적용 스크립트가 Docker 없이 걸림" || failed "적용 스크립트가 Docker 없이 걸림"
start_dockerd; wait_running probe
[ "$(iptables -S FORWARD | sed -n 2p)" = "-A FORWARD -j DOCKER-USER" ] && pass "Docker 가 FORWARD 첫 줄로 DOCKER-USER 를 건다" || failed "Docker 가 FORWARD 첫 줄로 DOCKER-USER 를 건다"
expect "재부팅 뒤 VPC 의 다른 서버 차단" 1 reach 10.0.1.45 3306
expect "재부팅 뒤 서버 sshd 차단" 1 reach "$GW" 22
expect "재부팅 뒤 인터넷 허용" 0 reach 203.0.113.10 443
expect "재부팅 뒤 DNS 허용" 0 reach 10.0.0.2 53

echo "--- 검증 실패 시 벽을 걷음"
iptables -D FORWARD -j DOCKER-USER
apply >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "FORWARD 가 벽을 거치지 않으면 exit 1" || failed "FORWARD 가 벽을 거치지 않으면 exit 1 (rc=$rc)"
[ -z "$(iptables -S DOCKER-USER | grep -v '^-N')" ] && ! iptables -S PIKI-WALL-OUT >/dev/null 2>&1 \
  && [ -z "$(iptables -S INPUT | grep PIKI-WALL)" ] && [ ! -f /etc/piki/egress-wall.rules ] \
  && pass "규칙·파일을 남기지 않음" || failed "규칙·파일을 남기지 않음"
stop_dockerd; start_dockerd; wait_running probe

echo "--- IPv6 bridge 거부"
docker network create --ipv6 --subnet fd00:5a1e::/64 v6net >/dev/null
apply >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "IPv6 가 켜진 bridge 가 있으면 exit 1" || failed "IPv6 가 켜진 bridge 가 있으면 exit 1 (rc=$rc)"
docker network rm v6net >/dev/null

echo "--- 실행 중인 컨테이너 없음"
docker rm -f probe peer >/dev/null
out=$(apply 2>&1); rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"건너뛴다"* ]] && pass "동작 확인을 건너뛰고 exit 0" || failed "동작 확인을 건너뛰고 exit 0 (rc=$rc)"

exit "$FAILURES"
SCENARIO
docker exec "$NAME" sh -c 'apk add --no-cache -q bash python3 iproute2 util-linux coreutils >/dev/null && bash /tmp/scenario.sh'
INNER=$?
[ "$INNER" -eq 0 ] || FAILURES=$((FAILURES + INNER))

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAILURES FAILURE(S)" >&2
  exit 1
fi
