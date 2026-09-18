#!/usr/bin/env bash
#
# 공통 배포 블록: blue-green 슬롯 배포 조립
#
# 잎 블록(slot_decide·run_container·healthcheck·slot_switch)을 정해진 순서로 엮는다.
#   1. 슬롯 결정 (상태 파일이 source of truth)
#   2. 비활성 슬롯의 잔재 컨테이너 정리 (직전 teardown 이 끊긴 경우)
#   3. 새 버전을 비활성 슬롯에 기동
#   4. 슬롯 포트로 직접 헬스 판정
#   5. upstream 전환 (프론트 경유 검증까지 원복 경계 안)
#   6. 구 슬롯 종료
# 3·4·5 어디서 실패해도 새 슬롯 컨테이너를 정리하고 exit 1 이다. 그때까지 트래픽은 구 슬롯이 서빙한다.
#
# 값(슬롯 이름·포트·헬스 경로·간격·횟수·검증 명령)은 전부 호출자가 준다 (conventions/blocks.md 2번).
# 블록이 슬롯 값으로 채우는 run_container 인자는 셋뿐이다: --name, --publish, piki.metrics.port 라벨.
# 나머지 run_container 인자는 `--` 뒤에 그대로 넘긴다.
#
# 사용 예:
#   deploy_slot.sh --state-file /etc/nginx/piki-extractor-upstream.conf \
#     --slot-a blue:18090 --slot-b green:18091 --name-prefix piki-extractor --container-port 8090 \
#     --health-path /actuator/health --health-interval 5 --health-attempts 36 --health-expect-body '"status":"UP"' \
#     --verify-cmd "bash /tmp/piki-blocks/healthcheck.sh --url http://localhost:8090/actuator/health --interval 2 --attempts 10" \
#     -- --image "$IMAGE" --restart unless-stopped --env-file "$ENV_FILE" --pull --memory 640m
#
# 인자:
#   --state-file        (필수) upstream 상태 파일 경로
#   --slot-a / --slot-b (필수) NAME:PORT 둘. slot_decide 계약과 같다
#   --name-prefix       (필수) 컨테이너 이름 접두사. 실제 이름은 <접두사>-<슬롯 이름>
#   --container-port    (필수) 컨테이너 안 앱 포트. 슬롯 포트를 127.0.0.1 에서 여기로 publish 한다
#   --health-path       (필수) 슬롯 헬스 경로 (예: /actuator/health)
#   --health-interval   (필수) 슬롯 헬스 폴링 간격(초)
#   --health-attempts   (필수) 슬롯 헬스 최대 시도
#   --health-expect-body (선택) 슬롯 헬스 응답 본문에 있어야 할 문자열
#   --verify-cmd        (필수) 전환 후 프론트 경유 검증 명령. slot_switch 에 그대로 전달
#   --log-dir           (선택) 잔재 정리 전에 비활성 슬롯 로그를 이 디렉토리에 덤프. 7일 지난 로그는 지운다
#   --blocks-dir        형제 블록 위치. 기본은 이 스크립트의 디렉토리 (셀프 테스트가 가짜 블록으로 바꿔 끼운다)
#   -- ARGS...          run_container 에 그대로 넘길 인자 (--name·--publish 는 주지 않는다)
#
# 출력: 마지막 줄에 "DEPLOYED slot=<이름> port=<포트> previous=<이름 또는 none>"
# 종료 코드: 성공 0, 실패(새 슬롯 정리 후) 1, 인자 오류 2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_FILE=""
SLOT_A=""
SLOT_B=""
NAME_PREFIX=""
CONTAINER_PORT=""
HEALTH_PATH=""
HEALTH_INTERVAL=""
HEALTH_ATTEMPTS=""
HEALTH_EXPECT_BODY=""
VERIFY_CMD=""
LOG_DIR=""
BLOCKS_DIR="$SCRIPT_DIR"
RUN_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --state-file)         STATE_FILE="${2:-}"; shift 2;;
    --slot-a)             SLOT_A="${2:-}"; shift 2;;
    --slot-b)             SLOT_B="${2:-}"; shift 2;;
    --name-prefix)        NAME_PREFIX="${2:-}"; shift 2;;
    --container-port)     CONTAINER_PORT="${2:-}"; shift 2;;
    --health-path)        HEALTH_PATH="${2:-}"; shift 2;;
    --health-interval)    HEALTH_INTERVAL="${2:-}"; shift 2;;
    --health-attempts)    HEALTH_ATTEMPTS="${2:-}"; shift 2;;
    --health-expect-body) HEALTH_EXPECT_BODY="${2:-}"; shift 2;;
    --verify-cmd)         VERIFY_CMD="${2:-}"; shift 2;;
    --log-dir)            LOG_DIR="${2:-}"; shift 2;;
    --blocks-dir)         BLOCKS_DIR="${2:-}"; shift 2;;
    --) shift; RUN_ARGS=("$@"); break;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

for pair in "STATE_FILE:--state-file" "SLOT_A:--slot-a" "SLOT_B:--slot-b" "NAME_PREFIX:--name-prefix" \
            "CONTAINER_PORT:--container-port" "HEALTH_PATH:--health-path" "HEALTH_INTERVAL:--health-interval" \
            "HEALTH_ATTEMPTS:--health-attempts" "VERIFY_CMD:--verify-cmd"; do
  var="${pair%%:*}"; flag="${pair#*:}"
  [ -n "${!var}" ] || { echo "$flag is required" >&2; exit 2; }
done
case "$CONTAINER_PORT" in *[!0-9]*|"") echo "--container-port must be numeric (got: $CONTAINER_PORT)" >&2; exit 2;; esac
for a in "${RUN_ARGS[@]+"${RUN_ARGS[@]}"}"; do
  case "$a" in --name|--publish) echo "$a is owned by this block; do not pass it after --" >&2; exit 2;; esac
done
for b in slot_decide run_container healthcheck slot_switch; do
  [ -f "$BLOCKS_DIR/$b.sh" ] || { echo "sibling block not found: $BLOCKS_DIR/$b.sh" >&2; exit 2; }
done

phase() { echo "[deploy_slot] $*"; }

# 컨테이너 정리. 데몬 지연에 대비해 timeout 상한을 건다 - 상한이 없으면 이미 성공한 전환이
# 호출자의 command timeout 에 걸려 배포가 통째로 실패한다. timeout 이 없는 환경(macOS 셀프 테스트)은 상한 없이 실행.
with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}
remove_container() {
  with_timeout "$2" docker stop -t 30 "$1" >/dev/null 2>&1 || true
  with_timeout 30 docker rm -f "$1" >/dev/null 2>&1 || true
}

# 1. 슬롯 결정. 할당 후 eval 2단계는 slot_decide 헤더가 정한 소비 계약.
DECIDED=$(bash "$BLOCKS_DIR/slot_decide.sh" --state-file "$STATE_FILE" --slot-a "$SLOT_A" --slot-b "$SLOT_B") \
  || { echo "slot_decide failed" >&2; exit 1; }
eval "$DECIDED"
NEW="$NAME_PREFIX-$INACTIVE"
phase "decide active=${ACTIVE:-none}:${ACTIVE_PORT:-} inactive=$INACTIVE:$INACTIVE_PORT"

# 2. 잔재 정리
if [ -n "$LOG_DIR" ]; then
  mkdir -p "$LOG_DIR"
  docker logs "$NEW" > "$LOG_DIR/$NEW-$(date +%Y%m%d-%H%M%S).log" 2>&1 || true
  find "$LOG_DIR" -name "*.log" -mtime +7 -delete 2>/dev/null || true
fi
remove_container "$NEW" 40

# 3. 기동
phase "run $NEW"
if ! bash "$BLOCKS_DIR/run_container.sh" \
    --name "$NEW" --publish "127.0.0.1:$INACTIVE_PORT:$CONTAINER_PORT" \
    --label "piki.metrics.port=$INACTIVE_PORT" \
    "${RUN_ARGS[@]+"${RUN_ARGS[@]}"}"; then
  echo "run_container failed - cleaning up $NEW" >&2
  remove_container "$NEW" 40
  exit 1
fi

# 4. 슬롯 헬스
HEALTH_ARGS=(--url "http://127.0.0.1:$INACTIVE_PORT$HEALTH_PATH" --interval "$HEALTH_INTERVAL" --attempts "$HEALTH_ATTEMPTS")
[ -n "$HEALTH_EXPECT_BODY" ] && HEALTH_ARGS+=(--expect-body "$HEALTH_EXPECT_BODY")
phase "health $NEW"
if ! bash "$BLOCKS_DIR/healthcheck.sh" "${HEALTH_ARGS[@]}"; then
  echo "slot health failed - cleaning up $NEW (previous slot keeps serving)" >&2
  remove_container "$NEW" 40
  exit 1
fi

# 5. 전환. 실패 시 slot_switch 가 upstream 을 원복한다. 컨테이너 정리는 여기 몫.
phase "switch -> $INACTIVE"
if ! bash "$BLOCKS_DIR/slot_switch.sh" --state-file "$STATE_FILE" --server "127.0.0.1:$INACTIVE_PORT" --verify-cmd "$VERIFY_CMD"; then
  echo "slot switch failed (upstream restored) - cleaning up $NEW" >&2
  remove_container "$NEW" 40
  exit 1
fi

# 6. 구 슬롯 종료. 전환은 끝났으므로 best-effort. 부트스트랩이면 종료할 것이 없다.
if [ -n "$ACTIVE" ]; then
  phase "teardown $NAME_PREFIX-$ACTIVE"
  remove_container "$NAME_PREFIX-$ACTIVE" 60
fi

echo "DEPLOYED slot=$INACTIVE port=$INACTIVE_PORT previous=${ACTIVE:-none}"
