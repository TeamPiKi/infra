#!/usr/bin/env bash
#
# 공통 배포 블록: Grafana Alloy 프로비저닝
#
# 박스 위 config.alloy 로 Alloy 수집기 컨테이너를 (재)기동한다. 수집기는 박스를 따라가므로
# 박스마다 이 블록이 한 번 돈다(수집기 하나).
# 실행 위치 중립 - 순수 bash + docker 만 쓰므로 SSH runner 에서든 SSM in-box 에서든 같은
# 스크립트가 그대로 돈다. transport 는 이 블록을 호출하는 쪽이 책임진다.
#
# 계약: config·기동의 SSOT 는 이 repo(blocks/alloy), 값(환경·자격증명)은 호출부/SSM 이 주입한다
#       (contracts/observability.md). 자격증명은 인자가 아니라 env 로 받는다 — ps 노출 방지.
#
# 사용 예:
#   GRAFANA_METRICS_URL=... GRAFANA_METRICS_USER=... GRAFANA_CLOUD_TOKEN=... (외 4종) \
#     provision-alloy.sh --config /etc/piki-alloy/config.alloy --name piki-alloy \
#                        --environment prod --box piki-extractor
#
# 인자:
#   --config       (필수) 박스 위 config.alloy 경로
#   --name         (필수) Alloy 컨테이너명
#   --environment  (필수) 환경 라벨 (dev/staging/prod) — 컨테이너에 ENVIRONMENT 로 주입
#   --box          (필수) 박스 주인 서비스 (piki-core·piki-extractor …) — PIKI_BOX 로 주입
#   --version      Alloy 이미지 태그. 기본 v1.16.1 — 운영 버전 핀의 SSOT 는 이 default
#   --listen-addr  debug UI(HTTP) bind 주소. 기본 127.0.0.1:12345 — 루프백에만 노출
#
# 환경변수 (자격증명 — 필수는 GRAFANA_METRICS_*; 나머지는 있으면 주입):
#   GRAFANA_METRICS_URL / GRAFANA_METRICS_USER   메트릭 remote_write
#   GRAFANA_LOGS_URL    / GRAFANA_LOGS_USER       로그 loki.write
#   GRAFANA_TRACES_URL  / GRAFANA_TRACES_USER     트레이스 otlphttp
#   GRAFANA_CLOUD_TOKEN                           메트릭·로그·트레이스 공유 토큰
#
# --environment·--box 는 박스마다 다른 값이라 default 없는 필수 인자다 — 블록은 값을 소유하지
# 않는다 (conventions/blocks.md 2번 원칙). --version·--listen-addr 은 서비스 정체성과 무관한
# 공통값이라 default 를 둔다.
#
# 종료 코드: 성공 0, 실행 실패(validate 실패·기동 실패) 1, 인자 오류 2
#           (GRAFANA_METRICS_URL 미주입 시 skip 은 성공 0 — secret 미등록 박스는 정상 상황)

set -euo pipefail

CONFIG=""
NAME=""
ENVIRONMENT=""
BOX=""
VERSION="v1.16.1"
LISTEN_ADDR="127.0.0.1:12345"

while [ $# -gt 0 ]; do
  case "$1" in
    --config)      CONFIG="${2:-}"; shift 2;;
    --name)        NAME="${2:-}"; shift 2;;
    --environment) ENVIRONMENT="${2:-}"; shift 2;;
    --box)         BOX="${2:-}"; shift 2;;
    --version)     VERSION="${2:-}"; shift 2;;
    --listen-addr) LISTEN_ADDR="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$CONFIG" ]      || { echo "--config is required" >&2; exit 2; }
[ -n "$NAME" ]        || { echo "--name is required" >&2; exit 2; }
[ -n "$ENVIRONMENT" ] || { echo "--environment is required" >&2; exit 2; }
[ -n "$BOX" ]         || { echo "--box is required" >&2; exit 2; }
[ -f "$CONFIG" ]      || { echo "config not found: $CONFIG" >&2; exit 2; }

# 자격증명 env (set -u 하에서 미설정 참조를 막으려 기본값으로 받는다).
METRICS_URL="${GRAFANA_METRICS_URL:-}"
METRICS_USER="${GRAFANA_METRICS_USER:-}"
LOGS_URL="${GRAFANA_LOGS_URL:-}"
LOGS_USER="${GRAFANA_LOGS_USER:-}"
TRACES_URL="${GRAFANA_TRACES_URL:-}"
TRACES_USER="${GRAFANA_TRACES_USER:-}"
CLOUD_TOKEN="${GRAFANA_CLOUD_TOKEN:-}"

# secret 미주입(metrics endpoint 없음) → skip. 빈 endpoint 로 부팅하면 remote_write 가 crash loop 하므로,
# 아예 기동하지 않고 성공으로 빠진다(secret 미등록 박스는 정상 상황 — core provision-runtime.sh 가드 패리티).
if [ -z "$METRICS_URL" ]; then
  echo "skip: GRAFANA_METRICS_URL 미주입 (secret 미등록 박스) — Alloy 기동 생략"
  exit 0
fi

IMAGE="grafana/alloy:$VERSION"

# ── 기동 전 validate 게이트 ──
# 잘못된 config 로 산 수집기를 죽이지 않는다. 기존 컨테이너를 건드리기 전에 같은 이미지·같은 env 로
# config 를 검증하고, 실패하면 기존 컨테이너를 그대로 둔 채 exit 1.
echo "validate: $IMAGE validate (config=$CONFIG)"
if ! docker run --rm -v "$CONFIG":/etc/alloy/config.alloy:ro \
      -e ENVIRONMENT="$ENVIRONMENT" \
      -e PIKI_BOX="$BOX" \
      -e GRAFANA_METRICS_URL="$METRICS_URL" \
      -e GRAFANA_METRICS_USER="$METRICS_USER" \
      -e GRAFANA_LOGS_URL="$LOGS_URL" \
      -e GRAFANA_LOGS_USER="$LOGS_USER" \
      -e GRAFANA_TRACES_URL="$TRACES_URL" \
      -e GRAFANA_TRACES_USER="$TRACES_USER" \
      -e GRAFANA_CLOUD_TOKEN="$CLOUD_TOKEN" \
      "$IMAGE" validate /etc/alloy/config.alloy; then
  echo "validate 실패 — 기존 수집기를 건드리지 않고 중단" >&2
  exit 1
fi

# ── config 설치 (고정 경로) ──
# /tmp 등 임시 경로를 직접 마운트하면 재부팅 후 restart 정책으로 되살아난 컨테이너가 사라진 파일을
# 마운트하려다 깨진다. 재부팅에도 남는 고정 경로(/etc/piki-alloy)에 설치한다.
SUDO=""
if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
fi
INSTALL_DIR="/etc/piki-alloy"
INSTALLED="$INSTALL_DIR/config.alloy"
$SUDO mkdir -p "$INSTALL_DIR"
$SUDO cp "$CONFIG" "$INSTALLED"

# ── (재)기동 ──
# --network host: 앱 포트가 127.0.0.1 바인딩이라 호스트 루프백으로 scrape 하고, host-gateway 로 들어오는
#   앱 OTLP push 를 받는다. 마운트: docker.sock(컨테이너 SD)·/proc·/sys·/(호스트 메트릭). :ro 로 읽기 전용.
echo "run: $IMAGE (name=$NAME, network=host, listen=$LISTEN_ADDR)"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --restart unless-stopped --network host \
  -v "$INSTALLED":/etc/alloy/config.alloy:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /proc:/host/proc:ro,rslave \
  -v /sys:/host/sys:ro,rslave \
  -v /:/host/root:ro,rslave \
  -e ENVIRONMENT="$ENVIRONMENT" \
  -e PIKI_BOX="$BOX" \
  -e GRAFANA_METRICS_URL="$METRICS_URL" \
  -e GRAFANA_METRICS_USER="$METRICS_USER" \
  -e GRAFANA_LOGS_URL="$LOGS_URL" \
  -e GRAFANA_LOGS_USER="$LOGS_USER" \
  -e GRAFANA_TRACES_URL="$TRACES_URL" \
  -e GRAFANA_TRACES_USER="$TRACES_USER" \
  -e GRAFANA_CLOUD_TOKEN="$CLOUD_TOKEN" \
  "$IMAGE" \
  run --server.http.listen-addr="$LISTEN_ADDR" /etc/alloy/config.alloy >/dev/null

# ── 기동 확인 ──
# 즉시 죽는 config/런타임 오류를 잡는다. validate 를 통과해도 런타임에서 죽을 수 있으니 실제 상태를 본다.
sleep 3
if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ]; then
  echo "Alloy 기동 성공 (name=$NAME, image=$IMAGE)"
  exit 0
fi

echo "Alloy 기동 실패 (name=$NAME) — 마지막 로그:" >&2
docker logs --tail 20 "$NAME" 2>&1 | sed 's/^/  /' >&2 || true
exit 1
