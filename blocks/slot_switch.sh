#!/usr/bin/env bash
#
# 공통 배포 블록: blue-green upstream 전환 (실패 시 원복)
#
# upstream 상태 파일을 새 슬롯으로 갱신하고 nginx 검증(-t)·reload 를 수행한다.
# 어느 단계가 실패해도(구성 검증, reload, 사후 검증) 이전 상태 파일을 원복해
# "상태 파일만 새 슬롯을 가리키고 실제 서빙은 옛 슬롯"인 괴리를 남기지 않는다.
# 이 괴리는 다음 배포의 슬롯 판정(slot_decide.sh)을 뒤집어, 실제 서빙 중인 슬롯을
# 비활성으로 오판·제거하게 만든다 (extractor 이행 배포 실사고의 일반화).
#
# 실행 위치 중립 - root 가 아니면 sudo 를 앞에 붙인다 (SSH runner 비루트 / SSM root 양쪽).
# reload 는 systemctl reload -> 실패 시 restart 폴백이라 nginx 가 정지 상태여도 전환된다.
#
# 사용 예:
#   slot_switch.sh --state-file /etc/nginx/piki-extractor-upstream.conf --server 127.0.0.1:18091 \
#     --verify-cmd "bash /tmp/piki-blocks/healthcheck.sh --url http://localhost:8090/actuator/health --interval 2 --attempts 10"
#
# 인자:
#   --state-file  (필수) upstream 상태 파일 경로. "server <값>;" 한 줄로 덮어쓴다
#   --server      (필수) 새 upstream server 값 (예: 127.0.0.1:18091)
#   --verify-cmd  (선택) reload 후 실행할 검증 명령(bash -c 로 실행). 비-0 이면 원복 후 실패.
#                 전환 후 프론트 경유 헬스체크(healthcheck.sh 호출)가 대표 소비자 - 검증까지
#                 원복 경계 안에 있어야 "전환됐지만 안 서빙되는" 상태가 남지 않는다
#
# 부트스트랩(이전 상태 파일 없음)은 원복 대상이 없다 - 실패해도 새 값이 남고 exit 1 로만
# 알린다 (되돌아갈 서빙 슬롯 자체가 없는 1회성 창이라 호출자·운영자가 수동 개입).
#
# 종료 코드: 성공 0, 전환 실패(가능하면 원복 수행) 1, 인자 오류 2

set -euo pipefail

STATE_FILE=""
SERVER=""
VERIFY_CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --state-file) STATE_FILE="${2:-}"; shift 2;;
    --server)     SERVER="${2:-}"; shift 2;;
    --verify-cmd) VERIFY_CMD="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$STATE_FILE" ] || { echo "--state-file is required" >&2; exit 2; }
[ -n "$SERVER" ]     || { echo "--server is required" >&2; exit 2; }

run_priv() {
  if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi
}

PREV=""
[ -f "$STATE_FILE" ] && PREV=$(cat "$STATE_FILE")

restore() {
  local stage="$1"
  if [ -z "$PREV" ]; then
    echo "switch FAILED at $stage - no previous state to restore (bootstrap)" >&2
    return 0
  fi
  printf '%s\n' "$PREV" | run_priv tee "$STATE_FILE" >/dev/null
  run_priv systemctl reload nginx 2>/dev/null || true
  echo "switch FAILED at $stage - restored previous upstream" >&2
}

printf 'server %s;\n' "$SERVER" | run_priv tee "$STATE_FILE" >/dev/null

if ! run_priv nginx -t; then
  restore "nginx -t"
  exit 1
fi
if ! { run_priv systemctl reload nginx || run_priv systemctl restart nginx; }; then
  restore "reload/restart"
  exit 1
fi
if [ -n "$VERIFY_CMD" ] && ! bash -c "$VERIFY_CMD"; then
  restore "verify"
  exit 1
fi

echo "switched upstream -> server $SERVER; ($STATE_FILE)"
exit 0
