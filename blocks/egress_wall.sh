#!/usr/bin/env bash
#
# 공통 배포 블록: 컨테이너의 내부망 연결 차단 (서버 벽)
#
# 컨테이너가 내부 대역(contracts/internal-ranges.txt)으로 여는 새 연결을 이 서버의 iptables 에서 거절한다.
# 앱 검사가 못 보는 경로(브라우저 worker·WebRTC, 검사 뒤 이름 해석이 바뀐 요청)도 연결 단계에서 막힌다.
# SG 는 허용 규칙만 있어 "내부만 막고 인터넷은 허용" 을 표현할 수 없어 서버에서 막는다.
# 컨테이너 자기 loopback 은 서버 iptables 를 지나지 않아 막지 못한다 - 그건 앱 검사 몫이다. 같은 bridge 의 옆
# 컨테이너(같은 서비스의 다른 슬롯)도 br_netfilter 가 없는 서버(두 운영 서버 실측)에서는 iptables 를 지나지 않아 같은 취급이다.
#
# 함대 공통 예외는 블록이 갖는다 (conventions/blocks.md 2번 원칙):
#   - DNS: Docker 가 컨테이너 resolv.conf 를 만드는 원본의 nameserver
#   - 인스턴스 메타데이터 169.254.169.254:80: 앱의 AWS 자격. IMDSv2 필수라 브라우저는 토큰을 못 얻는다
#   - 서버 Alloy OTLP 4318: contracts/observability.md
#
# 규칙은 /etc 에 남아 systemd 가 부팅 때 Docker 보다 먼저 다시 건다. 적용 뒤 bridge 에 잠깐 붙인 시험용 netns 에서
# 예외 목적지와 차단 목적지를 찔러 그 출발 주소의 거절 횟수로 확인하고, 어긋나면 벽을 걷고 exit 1 (서비스는 계속 돈다).
#
# 실행: root. 사용 예:
#   bash egress_wall.sh --ranges-file shared-infra/contracts/internal-ranges.txt
#   bash egress_wall.sh --ranges-file shared-infra/contracts/internal-ranges.txt --allow-tcp 10.0.1.230:8082
#   bash egress_wall.sh --remove        # 벽과 부팅 재적용 단위를 걷는다
#
# 인자:
#   --ranges-file (필수) 내부 대역 정본
#   --allow-tcp   (선택, 반복) 이 서비스만 쓰는 내부 목적지 IPv4:PORT
#   --remove      (단독) 벽을 걷고 끝낸다
#
# 종료 코드: 성공 0, 적용·검증 실패 1, 인자 오류 2

set -euo pipefail

STATE_DIR=/etc/piki
RULES_FILE="$STATE_DIR/egress-wall.rules"
APPLY_BIN=/usr/local/sbin/piki-egress-wall
UNIT_NAME=piki-egress-wall.service
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
METADATA_IP=169.254.169.254
OTLP_PORT=4318
# docker0 은 기본 bridge, br-+ 는 사용자 정의 bridge. 어느 쪽에 붙은 컨테이너든 같은 벽을 지난다.
BRIDGES=(docker0 br-+)
PROBE_NS=piki-wall-probe
PROBE_LINK=pwprobe0
IPV4='([0-9]{1,3}\.){3}[0-9]{1,3}'

require_value() {
  [ "$2" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
}

remove_wall() {
  iptables -F DOCKER-USER 2>/dev/null || true
  for bridge in "${BRIDGES[@]}"; do
    while iptables -D INPUT -i "$bridge" -j PIKI-WALL-HOST 2>/dev/null; do :; done
  done
  for chain in PIKI-WALL-OUT PIKI-WALL-HOST PIKI-WALL-DENY; do
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || true
  done
  if [ -d /run/systemd/system ]; then
    systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  rm -f "$RULES_FILE" "$APPLY_BIN" "$UNIT_FILE"
}

RANGES_FILE=""
ALLOW_TCP=()
REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ranges-file) require_value "$1" "$#"; RANGES_FILE="$2"; shift 2;;
    --allow-tcp)   require_value "$1" "$#"; ALLOW_TCP+=("$2"); shift 2;;
    --remove)      REMOVE=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [ "$REMOVE" -eq 1 ]; then
  if [ -n "$RANGES_FILE" ] || [ "${#ALLOW_TCP[@]}" -gt 0 ]; then
    echo "--remove takes no other argument" >&2
    exit 2
  fi
  remove_wall
  echo "[wall] 벽을 걷었다"
  exit 0
fi

[ -n "$RANGES_FILE" ] || { echo "--ranges-file is required" >&2; exit 2; }
[ -f "$RANGES_FILE" ] || { echo "ranges file not found: $RANGES_FILE" >&2; exit 2; }
for target in "${ALLOW_TCP[@]+"${ALLOW_TCP[@]}"}"; do
  [[ "$target" =~ ^$IPV4:[0-9]{1,5}$ ]] || { echo "--allow-tcp must be IPv4:PORT: $target" >&2; exit 2; }
done

# IPv6 줄은 건너뛴다. 컨테이너 네트워크의 IPv6 가 꺼져 있는지는 아래에서 확인한다.
RANGES=()
while IFS= read -r line || [ -n "$line" ]; do
  entry="${line%%#*}"
  entry="${entry//[[:space:]]/}"
  [ -n "$entry" ] || continue
  [[ "$entry" == *:* ]] && continue
  [[ "$entry" =~ ^$IPV4/[0-9]{1,2}$ ]] || { echo "invalid IPv4 range in $RANGES_FILE: $entry" >&2; exit 2; }
  RANGES+=("$entry")
done <"$RANGES_FILE"
[ "${#RANGES[@]}" -gt 0 ] || { echo "no IPv4 range in $RANGES_FILE" >&2; exit 2; }

# 출력을 먼저 받아 둔다. pipefail 아래서 grep -q 가 일찍 끝나면 앞 명령의 SIGPIPE 로 판정이 뒤집힌다.
IPV6_FLAGS=$(docker network ls --filter driver=bridge -q | xargs -r docker network inspect -f '{{.EnableIPv6}}')
if [[ "$IPV6_FLAGS" == *true* ]]; then
  echo "[wall] IPv6 가 켜진 bridge 가 있다 - 벽은 IPv4 만 막는다" >&2
  exit 1
fi

# Docker 와 같은 원본을 읽는다. 서버 resolv.conf 가 loopback 리졸버(systemd-resolved)만 가리키면
# Docker 는 그 상류 목록을 컨테이너에 준다.
nameservers() {
  awk '$1 == "nameserver" {print $2}' "$1" | grep -E "^$IPV4$" | grep -Ev '^127\.' || true
}
DNS_SERVERS=$(nameservers /etc/resolv.conf)
if [ -z "$DNS_SERVERS" ] && [ -f /run/systemd/resolve/resolv.conf ]; then
  DNS_SERVERS=$(nameservers /run/systemd/resolve/resolv.conf)
fi
[ -n "$DNS_SERVERS" ] || { echo "[wall] 컨테이너가 쓰는 IPv4 nameserver 를 찾지 못했다" >&2; exit 1; }

render_rules() {
  echo '*filter'
  # DOCKER-USER 는 이 블록이 통째로 갖는다. 선언하면 restore 가 비우고 다시 채워 몇 번을 돌려도 같다.
  echo ':DOCKER-USER - [0:0]'
  echo ':PIKI-WALL-OUT - [0:0]'
  echo ':PIKI-WALL-HOST - [0:0]'
  echo ':PIKI-WALL-DENY - [0:0]'
  for bridge in "${BRIDGES[@]}"; do
    echo "-A DOCKER-USER -i $bridge -j PIKI-WALL-OUT"
  done
  # Docker 의 ESTABLISHED 허용은 DOCKER-USER 뒤에 있어 여기서 새 연결만 고른다.
  echo '-A PIKI-WALL-OUT -m conntrack ! --ctstate NEW -j RETURN'
  for ns in $DNS_SERVERS; do
    echo "-A PIKI-WALL-OUT -d $ns/32 -p udp -m udp --dport 53 -j RETURN"
    echo "-A PIKI-WALL-OUT -d $ns/32 -p tcp -m tcp --dport 53 -j RETURN"
  done
  echo "-A PIKI-WALL-OUT -d $METADATA_IP/32 -p tcp -m tcp --dport 80 -j RETURN"
  for target in "${ALLOW_TCP[@]+"${ALLOW_TCP[@]}"}"; do
    echo "-A PIKI-WALL-OUT -d ${target%:*}/32 -p tcp -m tcp --dport ${target##*:} -j RETURN"
  done
  for range in "${RANGES[@]}"; do
    echo "-A PIKI-WALL-OUT -d $range -j PIKI-WALL-DENY"
  done
  # 컨테이너가 서버 자신에게 여는 연결은 FORWARD 가 아니라 INPUT 을 지난다.
  echo '-A PIKI-WALL-HOST -m conntrack ! --ctstate NEW -j RETURN'
  echo "-A PIKI-WALL-HOST -p tcp -m tcp --dport $OTLP_PORT -j RETURN"
  echo '-A PIKI-WALL-HOST -j PIKI-WALL-DENY'
  echo '-A PIKI-WALL-DENY -m limit --limit 6/min -j LOG --log-prefix "piki-wall: "'
  # TCP 는 RST 로 돌려준다. ICMP 거절은 커널이 초당 1개로 묶어 연달아 막히면 SYN 재전송(1초)을 기다린다.
  echo '-A PIKI-WALL-DENY -p tcp -j REJECT --reject-with tcp-reset'
  echo '-A PIKI-WALL-DENY -j REJECT'
  echo 'COMMIT'
}

ip2int() {
  local IFS=.
  read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

int2ip() {
  echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"
}

probe_down() {
  ip netns del "$PROBE_NS" 2>/dev/null || true
  ip link del "$PROBE_LINK" 2>/dev/null || true
  if [ -n "${PROBE_IP:-}" ]; then
    iptables -D PIKI-WALL-DENY -s "$PROBE_IP/32" 2>/dev/null || true
  fi
}

fail() {
  echo "[wall] $1 - 벽을 걷는다" >&2
  probe_down
  remove_wall
  exit 1
}

STAGED=$(mktemp)
trap 'rm -f "$STAGED"; probe_down' EXIT
render_rules >"$STAGED"
iptables-restore --test --noflush <"$STAGED" || { echo "[wall] iptables-restore 가 규칙을 거부했다" >&2; exit 1; }

mkdir -p "$STATE_DIR"
install -m 0644 "$STAGED" "$RULES_FILE"
cat >"$APPLY_BIN" <<EOF
#!/bin/sh
# TeamPiKi/infra blocks/egress_wall.sh 가 설치한다. 배포 때는 블록이, 부팅 때는 $UNIT_NAME 이 이 파일로 건다.
set -eu
iptables-restore --noflush $RULES_FILE
for bridge in ${BRIDGES[*]}; do
  iptables -C INPUT -i "\$bridge" -j PIKI-WALL-HOST 2>/dev/null || iptables -I INPUT 1 -i "\$bridge" -j PIKI-WALL-HOST
done
EOF
chmod 0755 "$APPLY_BIN"
"$APPLY_BIN" || fail "규칙 적용 실패"

if [ -d /run/systemd/system ]; then
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=piki container egress wall (TeamPiKi/infra blocks/egress_wall.sh)
# Docker 가 재시작 정책으로 컨테이너를 되살리기 전에 건다.
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$APPLY_BIN

[Install]
WantedBy=multi-user.target
EOF
  { systemctl daemon-reload && systemctl enable "$UNIT_NAME" >/dev/null 2>&1; } || fail "$UNIT_NAME 등록 실패"
else
  echo "[wall] systemd 가 없어 부팅 재적용 단위를 건너뛴다"
fi

[[ "$(iptables -S FORWARD)" == *"-j DOCKER-USER"* ]] || fail "FORWARD 가 DOCKER-USER 를 거치지 않는다"

# 동작 확인은 운영 컨테이너가 아니라 docker0 에 잠깐 붙인 netns 에서 한다. 그 출발 주소만 세야 운영 트래픽이 벽에
# 걸려도 판정이 흔들리지 않는다. Docker 는 bridge 대역 앞에서부터 주소를 나눠 주므로 끝쪽에서 빈 주소를 고른다.
SUBNET=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
GATEWAY=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
USED=$(docker network inspect bridge -f '{{range .Containers}}{{.IPv4Address}} {{end}}')
PREFIX_LEN=${SUBNET#*/}
LAST=$(($(ip2int "${SUBNET%/*}") + (1 << (32 - PREFIX_LEN)) - 2))
PROBE_IP=""
for offset in 0 1 2 3 4 5 6 7; do
  candidate=$(int2ip $((LAST - offset)))
  [[ " $USED " == *" $candidate/"* ]] || { PROBE_IP="$candidate"; break; }
done
[ -n "$PROBE_IP" ] || fail "시험용 주소를 고르지 못했다"

ip netns add "$PROBE_NS" || fail "시험용 netns 를 만들지 못했다"
ip link add "$PROBE_LINK" type veth peer name eth0 netns "$PROBE_NS" || fail "시험용 veth 를 만들지 못했다"
ip link set "$PROBE_LINK" master docker0 up || fail "시험용 veth 를 docker0 에 붙이지 못했다"
ip netns exec "$PROBE_NS" sh -c "ip addr add $PROBE_IP/$PREFIX_LEN dev eth0 && ip link set eth0 up && ip link set lo up && ip route add default via $GATEWAY" \
  || fail "시험용 netns 주소를 잡지 못했다"
iptables -I PIKI-WALL-DENY 1 -s "$PROBE_IP/32"

probe_rejects() {
  iptables -v -S PIKI-WALL-DENY | awk -v src="-s $PROBE_IP/32" 'index($0, src) && $0 !~ / -j / {print $(NF - 1)}'
}

# 성패가 아니라 시험 주소의 거절 횟수로 판정하므로 목적지가 꺼져 있어도 된다.
poke() {
  local proto="$1" ip="$2" port="$3"
  if [ "$proto" = udp ]; then
    ip netns exec "$PROBE_NS" timeout 2 bash -c "printf x >/dev/udp/$ip/$port" 2>/dev/null || true
  else
    ip netns exec "$PROBE_NS" timeout 2 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null || true
  fi
}

for ns in $DNS_SERVERS; do
  poke udp "$ns" 53
  poke tcp "$ns" 53
done
poke tcp "$METADATA_IP" 80
poke tcp "$GATEWAY" "$OTLP_PORT"
for target in "${ALLOW_TCP[@]+"${ALLOW_TCP[@]}"}"; do
  poke tcp "${target%:*}" "${target##*:}"
done
[ "$(probe_rejects)" = 0 ] || fail "예외 목적지가 벽에 걸렸다"

poke tcp "$METADATA_IP" 1
poke tcp "$GATEWAY" 1
[ "$(probe_rejects)" -ge 2 ] || fail "내부 목적지가 벽에 걸리지 않았다"

echo "[wall] OK: 내부 대역 ${#RANGES[@]}개 차단, DNS $(echo "$DNS_SERVERS" | tr '\n' ' ')· 메타데이터 · OTLP $OTLP_PORT${ALLOW_TCP[*]:+ · ${ALLOW_TCP[*]}} 허용"
