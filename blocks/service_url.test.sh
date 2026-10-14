#!/usr/bin/env bash
#
# blocks/service_url.sh 셀프 테스트. aws CLI 를 가짜로 바꿔 끼워 정본 읽기와 인스턴스 개수 판정을 본다.
#
# 실행: ./blocks/service_url.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCK="$SCRIPT_DIR/service_url.sh"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
BIN="$WORKDIR/bin"
mkdir -p "$BIN"

# 가짜 aws: 받은 인자를 기록하고 FAKE_IPS 를 text 출력처럼 내보낸다. FAKE_AWS_FAIL=1 이면 실패.
cat > "$BIN/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$AWS_ARGS"
[ "${FAKE_AWS_FAIL:-0}" = "1" ] && exit 255
printf '%s\n' "${FAKE_IPS:-}"
EOF
chmod +x "$BIN/aws"
export PATH="$BIN:$PATH" AWS_ARGS="$WORKDIR/aws.args"

PORTS="$WORKDIR/ports.json"
cat > "$PORTS" <<'EOF'
{ "core": { "port": 8080 }, "renderer": { "port": 8082, "box": "piki-headless-browser" } }
EOF

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

OUT=$(FAKE_IPS="10.0.1.230" "$BLOCK" --ports-file "$PORTS" --service renderer --region ap-northeast-2)
check "인스턴스 하나 -> exit 0" 0 "$?"
check "주소" "http://10.0.1.230:8082" "$OUT"
check "Name 태그·실행 중 필터·리전" \
  "ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=piki-headless-browser Name=instance-state-name,Values=running --query Reservations[].Instances[].PrivateIpAddress --output text" \
  "$(cat "$AWS_ARGS")"

FAKE_IPS="" "$BLOCK" --ports-file "$PORTS" --service renderer >/dev/null 2>&1
check "인스턴스 0개 -> exit 1" 1 "$?"

FAKE_IPS=$'10.0.1.230\t10.0.1.231' "$BLOCK" --ports-file "$PORTS" --service renderer >/dev/null 2>&1
check "인스턴스 2개 -> exit 1" 1 "$?"

FAKE_AWS_FAIL=1 "$BLOCK" --ports-file "$PORTS" --service renderer >/dev/null 2>&1
check "aws 실패 -> exit 1" 1 "$?"

"$BLOCK" --ports-file "$PORTS" --service nope >/dev/null 2>&1
check "정본에 없는 서비스 -> exit 2" 2 "$?"

"$BLOCK" --ports-file "$PORTS" --service core >/dev/null 2>&1
check "box 없는 서비스 -> exit 2" 2 "$?"

"$BLOCK" --service renderer >/dev/null 2>&1
check "--ports-file 누락 -> exit 2" 2 "$?"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAILURES FAILED" >&2
  exit 1
fi
