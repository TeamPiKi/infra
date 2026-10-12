#!/usr/bin/env bash
#
# Name 태그로 찾은 박스에 SSM Session Manager 를 거쳐 SSH 하도록 ~/.ssh 를 준비한다. 사용법은 action.yml.
#
# 인자:
#   --instance-name  (필수) 대상 인스턴스의 Name 태그. ssh 별칭으로도 쓴다
#   --user           (필수) 박스 로그인 사용자
# 환경 변수:
#   SSH_KEY          (필수) 개인 키 본문. argv 로 받으면 프로세스 목록에 보인다
#
# 종료 코드: 성공 0, 실패 1, 인자 오류 2. 성공 시 stdout 에 인스턴스 id 하나.

set -euo pipefail

NAME=""
LOGIN_USER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --instance-name) NAME="${2:-}"; shift 2;;
    --user)          LOGIN_USER="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$NAME" ] || { echo "--instance-name is required" >&2; exit 2; }
[ -n "$LOGIN_USER" ] || { echo "--user is required" >&2; exit 2; }
[ -n "${SSH_KEY:-}" ] || { echo "SSH_KEY is required" >&2; exit 2; }

command -v session-manager-plugin >/dev/null || { echo "session-manager-plugin not found" >&2; exit 1; }

IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
COUNT=$(wc -w <<<"$IDS" | tr -d ' ')
if [ "$COUNT" != 1 ]; then
  echo "running instance named $NAME: expected 1, got $COUNT${IDS:+ ($IDS)}" >&2
  exit 1
fi
INSTANCE_ID="${IDS//[[:space:]]/}"

umask 077
mkdir -p "$HOME/.ssh"
KEY_FILE="$HOME/.ssh/$NAME.key"
printf '%s\n' "$SSH_KEY" > "$KEY_FILE"

# accept-new: 접속 대상은 SSM 이 인스턴스 id 로 고정하므로 처음 보는 호스트 키를 받아들인다.
# ConnectTimeout: ProxyCommand 를 써도 SSH 핸드셰이크 대기에 걸려, 열리지 않는 SSM 채널을 끊는다.
# ServerAliveInterval: Session Manager 는 클라이언트 입력이 20분 없으면 세션을 끊는다.
cat >> "$HOME/.ssh/config" <<EOF
Host $NAME
  HostName $INSTANCE_ID
  User $LOGIN_USER
  IdentityFile $KEY_FILE
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ConnectTimeout 30
  ServerAliveInterval 30
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p
EOF

echo "$INSTANCE_ID"
