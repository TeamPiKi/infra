#!/usr/bin/env bash
#
# blocks/healthcheck.sh 셀프 테스트
#
# python3 http.server 로 로컬 서버를 띄워 healthcheck.sh 의 계약(종료 코드)을
# 실측한다. conventions/blocks.md 5번 원칙(셀프 검증 가능)의 실행체이며,
# CI(shellcheck job 과 별개 job) 와 로컬에서 같은 스크립트로 돈다.
#
# 실행: ./blocks/healthcheck.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTHCHECK="$SCRIPT_DIR/healthcheck.sh"

WORKDIR=$(mktemp -d)
SERVER_PID=""
TLS_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ -n "$TLS_PID" ] && kill "$TLS_PID" 2>/dev/null
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

PORT=$((20000 + RANDOM % 20000))

# 정적 파일: 200 + 본문 매칭 케이스용. 존재하지 않는 경로는 http.server 가 자동 404.
printf '{"status":"ok"}' >"$WORKDIR/ok.json"

python3 -m http.server "$PORT" --directory "$WORKDIR" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER_PID=$!

# 서버 기동 실패(포트 충돌 등)를 여기서 명시적으로 끊는다 - 안 끊으면 아래 케이스들이
# 연결 실패로 인한 "expected N, got M" 로 위장되어 원인 추적이 어려워진다.
STARTED=0
for _ in $(seq 1 20); do
  curl -sS -m 1 "http://127.0.0.1:$PORT/ok.json" >/dev/null 2>&1 && { STARTED=1; break; }
  sleep 0.2
done
if [ "$STARTED" -ne 1 ]; then
  echo "local http server failed to start on port $PORT" >&2
  exit 1
fi

# ── TLS·Host 헤더 케이스용 커스텀 서버 ──
# 정적 http.server 로는 "Host 가 맞을 때만 200"(헤더가 실제 전송되는지의 증명)과 자가서명 TLS
# (--insecure 의 존재 이유)를 표현할 수 없어, 자가서명 cert 를 물린 인라인 핸들러를 띄운다.
TLS_PORT=$((20000 + RANDOM % 20000))
openssl req -x509 -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -days 1 -nodes -subj "/CN=localhost" >/dev/null 2>&1
python3 - "$TLS_PORT" "$WORKDIR" <<'PYEOF' &
import http.server, ssl, sys
port, work = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.headers.get('Host', '').startswith('piki.test')
        self.send_response(200 if ok else 421)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}' if ok else b'wrong host')
    def log_message(self, *args): pass
srv = http.server.HTTPServer(('127.0.0.1', port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(work + '/cert.pem', work + '/key.pem')
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PYEOF
TLS_PID=$!

TLS_STARTED=0
for _ in $(seq 1 20); do
  curl -skS -m 1 "https://127.0.0.1:$TLS_PORT/" >/dev/null 2>&1 && { TLS_STARTED=1; break; }
  sleep 0.2
done
if [ "$TLS_STARTED" -ne 1 ]; then
  echo "local https server failed to start on port $TLS_PORT" >&2
  exit 1
fi

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

BASE_URL="http://127.0.0.1:$PORT/ok.json"
MISSING_URL="http://127.0.0.1:$PORT/missing.json"

# 1. 필수 인자 누락 - url 없음
"$HEALTHCHECK" --interval 1 --attempts 1 >/dev/null 2>&1
check "url 없음 -> exit 2" 2 "$?"

# 1b. 필수 인자 누락 - interval 없음
"$HEALTHCHECK" --url "$BASE_URL" --attempts 1 >/dev/null 2>&1
check "interval 없음 -> exit 2" 2 "$?"

# 2. 알 수 없는 인자
"$HEALTHCHECK" --url "$BASE_URL" --interval 1 --attempts 1 --bogus foo >/dev/null 2>&1
check "알 수 없는 인자 -> exit 2" 2 "$?"

# 3. 200 응답
"$HEALTHCHECK" --url "$BASE_URL" --interval 1 --attempts 1 >/dev/null 2>&1
check "200 응답 -> exit 0" 0 "$?"

# 4. 비-200 으로 attempts 소진 (interval 1, attempts 2 로 빠르게)
"$HEALTHCHECK" --url "$MISSING_URL" --interval 1 --attempts 2 >/dev/null 2>&1
check "404 로 attempts 소진 -> exit 1" 1 "$?"

# 5a. --expect-body 매칭
"$HEALTHCHECK" --url "$BASE_URL" --interval 1 --attempts 1 --expect-body '"status":"ok"' >/dev/null 2>&1
check "expect-body 매칭 -> exit 0" 0 "$?"

# 5b. --expect-body 불일치 (interval 1, attempts 2 로 빠르게)
"$HEALTHCHECK" --url "$BASE_URL" --interval 1 --attempts 2 --expect-body '"status":"down"' >/dev/null 2>&1
check "expect-body 불일치 -> exit 1" 1 "$?"

TLS_URL="https://127.0.0.1:$TLS_PORT/health"

# 6a. 자가서명 TLS 를 --insecure 없이 -> 인증서 검증 실패로 소진
"$HEALTHCHECK" --url "$TLS_URL" --interval 1 --attempts 1 --host-header piki.test >/dev/null 2>&1
check "자가서명 TLS + insecure 없음 -> exit 1" 1 "$?"

# 6b. --insecure + --host-header 매칭 -> 200 (서버가 Host 일치 때만 200 이라 헤더 전송의 증명)
"$HEALTHCHECK" --url "$TLS_URL" --interval 1 --attempts 1 --insecure --host-header piki.test --expect-body '"status":"ok"' >/dev/null 2>&1
check "insecure + host-header 매칭 -> exit 0" 0 "$?"

# 6c. --insecure 만 (Host 미지정 -> 서버 421) -> 소진
"$HEALTHCHECK" --url "$TLS_URL" --interval 1 --attempts 2 --insecure >/dev/null 2>&1
check "insecure + host-header 없음(서버 421) -> exit 1" 1 "$?"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES case(s) failed" >&2
  exit 1
fi

echo "all healthcheck.sh cases passed"
