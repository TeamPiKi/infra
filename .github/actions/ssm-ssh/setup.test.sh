#!/usr/bin/env bash
#
# .github/actions/ssm-ssh/setup.sh 셀프 테스트. aws·session-manager-plugin 은 PATH 앞의 가짜로 대신한다.
#
# 실행: ./.github/actions/ssm-ssh/setup.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/setup.sh"

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

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

# 러너에는 진짜 session-manager-plugin 이 있어 "없음" 경로를 보려면 PATH 를 이 디렉토리들로만 좁힌다.
TOOLS="$WORKDIR/tools"
FAKE="$WORKDIR/fake"
mkdir -p "$TOOLS" "$FAKE"
for t in bash wc tr mkdir cat; do ln -s "$(command -v "$t")" "$TOOLS/$t"; done
cat > "$FAKE/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_AWS_ARGS"
printf '%s\n' "$FAKE_IDS"
EOF
printf '#!/usr/bin/env bash\n' > "$FAKE/session-manager-plugin"
chmod +x "$FAKE/aws" "$FAKE/session-manager-plugin"

KEY='-----BEGIN OPENSSH PRIVATE KEY-----
TOPSECRET
-----END OPENSSH PRIVATE KEY-----'

RUN_HOME="$WORKDIR/home"
mkdir -p "$RUN_HOME"

run() {
  HOME="$RUN_HOME" PATH="$FAKE:$TOOLS" FAKE_AWS_ARGS="$WORKDIR/aws-args" "$TOOLS/bash" "$SETUP" "$@"
}

# 1. 인자 오류
SSH_KEY="$KEY" FAKE_IDS=i-1 run --user ubuntu >/dev/null 2>&1
check "--instance-name 없음 -> exit 2" 2 "$?"
SSH_KEY="$KEY" FAKE_IDS=i-1 run --instance-name box >/dev/null 2>&1
check "--user 없음 -> exit 2" 2 "$?"
SSH_KEY="" FAKE_IDS=i-1 run --instance-name box --user ubuntu >/dev/null 2>&1
check "SSH_KEY 없음 -> exit 2" 2 "$?"
SSH_KEY="$KEY" FAKE_IDS=i-1 run --instance-name box --user ubuntu --bogus x >/dev/null 2>&1
check "알 수 없는 인자 -> exit 2" 2 "$?"

# 2. 인스턴스가 정확히 하나가 아니면 실패
SSH_KEY="$KEY" FAKE_IDS="" run --instance-name box --user ubuntu >/dev/null 2>&1
check "실행 중 인스턴스 0개 -> exit 1" 1 "$?"
SSH_KEY="$KEY" FAKE_IDS=$'i-1\ti-2' run --instance-name box --user ubuntu >/dev/null 2>&1
check "실행 중 인스턴스 2개 -> exit 1" 1 "$?"

# 3. plugin 이 없으면 실패
rm "$FAKE/session-manager-plugin"
SSH_KEY="$KEY" FAKE_IDS=i-1 run --instance-name box --user ubuntu >/dev/null 2>&1
check "session-manager-plugin 없음 -> exit 1" 1 "$?"
printf '#!/usr/bin/env bash\n' > "$FAKE/session-manager-plugin"
chmod +x "$FAKE/session-manager-plugin"

# 4. 성공
OUT=$(SSH_KEY="$KEY" FAKE_IDS=i-0abc run --instance-name piki-box --user ubuntu 2>&1)
check "성공 -> stdout 은 인스턴스 id" i-0abc "$OUT"
check "Name 태그·running 으로 조회" \
  "ec2 describe-instances --filters Name=tag:Name,Values=piki-box Name=instance-state-name,Values=running --query Reservations[].Instances[].InstanceId --output text" \
  "$(cat "$WORKDIR/aws-args")"
CONFIG="$RUN_HOME/.ssh/config"
check "별칭 Host" "Host piki-box" "$(grep '^Host ' "$CONFIG")"
check "HostName 은 인스턴스 id" "HostName i-0abc" "$(grep -o 'HostName .*' "$CONFIG")"
check "User" "User ubuntu" "$(grep -o 'User .*' "$CONFIG")"
check "SSM 경유 ProxyCommand" \
  "ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p" \
  "$(grep -o 'ProxyCommand .*' "$CONFIG")"
check "키 파일 내용" "$KEY" "$(cat "$RUN_HOME/.ssh/piki-box.key")"
PERM=$(stat -c '%a' "$RUN_HOME/.ssh/piki-box.key" 2>/dev/null || stat -f '%Lp' "$RUN_HOME/.ssh/piki-box.key")
check "키 파일 권한 600" 600 "$PERM"
case "$OUT" in *TOPSECRET*) check "키 출력 누출 없음" no-leak leaked;; *) check "키 출력 누출 없음" no-leak no-leak;; esac

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "all passed"
