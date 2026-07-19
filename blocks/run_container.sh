#!/usr/bin/env bash
#
# 공통 배포 블록: 컨테이너 기동
#
# 이미지 하나를 지정 이름의 컨테이너로 기동하고, 기동 직후 상태(Running, 재시작 없음)까지
# 검증한다. 실행 위치 중립 - 순수 bash + docker CLI 만 쓰므로 SSH runner 에서든 박스 안에서든
# 같은 스크립트가 그대로 돈다. transport 는 호출자 소관 (conventions/blocks.md 1번 원칙).
#
# 교체식(replace)·blue-green 슬롯식 모두 이 블록으로 표현한다: 슬롯 이름·포트 계산은
# 호출자가 하고, 블록은 "이 이름·이 이미지로 기동하라"만 책임진다. 트래픽 전환(nginx)과
# 헬스 판정은 별도 블록(healthcheck.sh)과 호출자 몫이다.
#
# 사용 예:
#   run_container.sh --name piki-extractor --image <user>/piki-extractor:abc123 \
#     --restart unless-stopped --publish 8090:8090 --env-file /tmp/app.env --pull --replace
#   run_container.sh --name team3-green --image <user>/piki-core:abc123 \
#     --restart unless-stopped --publish 127.0.0.1:8081:8080 --env-file /tmp/app.env --pull
#
# 인자:
#   --name         (필수) 컨테이너 이름
#   --image        (필수) 이미지 ref (tag 포함)
#   --restart      (필수) docker restart 정책 (unless-stopped 등). 서비스 결정이라 default 없음
#   --publish      (선택, 반복 가능) 포트 바인딩. docker -p 와 같은 형식
#   --env-file     (선택) docker --env-file 로 넘길 KEY=VALUE 파일 (시크릿을 argv 에 노출하지 않기 위한 유일 통로)
#   --network      (선택) docker --network 값
#   --label        (선택, 반복 가능) 컨테이너 라벨. docker --label 과 같은 KEY=VALUE 형식
#                  (관측 opt-in 라벨 piki.* 이 대표 소비자 - contracts/observability.md)
#   --add-host     (선택, 반복 가능) 호스트 항목. docker --add-host 와 같은 HOST:TARGET 형식
#                  (앱 -> 박스 로컬 Alloy OTLP push 의 host-gateway 배선이 대표 소비자)
#   --shm-size     (선택) docker --shm-size (Chrome 류 브라우저 컨테이너의 /dev/shm 확장이 대표 소비자)
#   --env          (선택, 반복 가능) 컨테이너에 넘길 env 키 이름. docker 의 '-e KEY' passthrough 형식으로,
#                  값은 호출자 셸에 export 된 것을 docker 가 직접 읽는다 - 값이 argv 에 안 실려 ps 노출이 없고,
#                  --env-file 이 못 싣는 다중행 값(PEM 등)도 바이트 그대로 전달된다
#   --memory       (선택) docker --memory (cgroup 메모리 한도 - OOM 폭발 반경을 컨테이너로 가둔다)
#   --memory-swap  (선택) docker --memory-swap (--memory 와 짝: 부팅 스파이크를 swap 으로 흘리는 쿠션)
#   --pull         (선택 플래그) 기동 전에 docker pull
#   --replace      (선택 플래그) 같은 이름 컨테이너가 있으면 rm -f 후 기동 (없으면 이름 충돌은 실패)
#   --verify-wait  기동 후 상태 검증 전 대기 초. 기본 2 (서비스 무관 공통값 - 즉사 크래시를 잡는 최소 대기)
#   -- CMD...      (선택) 이미지 CMD 오버라이드 (셀프테스트 포함 특수 용도)
#
# name·image·restart 는 서비스마다 다른 값이라 default 없는 필수 인자다 — 블록은 값을
# 소유하지 않는다 (conventions/blocks.md 2번 원칙).
#
# 종료 코드: 성공 0, 기동/검증 실패 1, 인자 오류 2

set -euo pipefail

NAME=""
IMAGE=""
RESTART=""
PUBLISH=()
ENV_FILE=""
NETWORK=""
LABELS=()
ADDHOSTS=()
SHM_SIZE=""
ENV_KEYS=()
MEMORY=""
MEMORY_SWAP=""
PULL=0
REPLACE=0
VERIFY_WAIT=2
CMD=()

# 값을 받는 옵션이 마지막 인자로 끝나면(값 누락) shift 2 가 set -e 로 exit 1 이 되어
# 계약(인자 오류=2)이 깨진다 - 값 존재를 먼저 검사한다.
require_value() {
  [ "$2" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        require_value "$1" "$#"; NAME="$2"; shift 2;;
    --image)       require_value "$1" "$#"; IMAGE="$2"; shift 2;;
    --restart)     require_value "$1" "$#"; RESTART="$2"; shift 2;;
    --publish)     require_value "$1" "$#"; PUBLISH+=("$2"); shift 2;;
    --env-file)    require_value "$1" "$#"; ENV_FILE="$2"; shift 2;;
    --network)     require_value "$1" "$#"; NETWORK="$2"; shift 2;;
    --label)       require_value "$1" "$#"; LABELS+=("$2"); shift 2;;
    --add-host)    require_value "$1" "$#"; ADDHOSTS+=("$2"); shift 2;;
    --shm-size)    require_value "$1" "$#"; SHM_SIZE="$2"; shift 2;;
    --env)         require_value "$1" "$#"; ENV_KEYS+=("$2"); shift 2;;
    --memory)      require_value "$1" "$#"; MEMORY="$2"; shift 2;;
    --memory-swap) require_value "$1" "$#"; MEMORY_SWAP="$2"; shift 2;;
    --pull)        PULL=1; shift;;
    --replace)     REPLACE=1; shift;;
    --verify-wait) require_value "$1" "$#"; VERIFY_WAIT="$2"; shift 2;;
    --)            shift; CMD=("$@"); break;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$NAME" ]    || { echo "--name is required" >&2; exit 2; }
[ -n "$IMAGE" ]   || { echo "--image is required" >&2; exit 2; }
[ -n "$RESTART" ] || { echo "--restart is required" >&2; exit 2; }
# 비숫자 verify-wait 는 sleep 단계에서 exit 1 로 위장되므로 인자 오류(2)로 앞당겨 끊는다.
case "$VERIFY_WAIT" in
  ''|*[!0-9]*) echo "--verify-wait must be a non-negative integer" >&2; exit 2;;
esac
if [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; then
  echo "--env-file not found: $ENV_FILE" >&2
  exit 2
fi

if [ "$PULL" -eq 1 ]; then
  docker pull "$IMAGE" || { echo "image pull FAILED: $IMAGE" >&2; exit 1; }
fi

if [ "$REPLACE" -eq 1 ] && docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "replacing existing container: $NAME"
  docker rm -f "$NAME" >/dev/null
fi

RUN_ARGS=(-d --name "$NAME" --restart "$RESTART")
for P in ${PUBLISH[@]+"${PUBLISH[@]}"}; do RUN_ARGS+=(-p "$P"); done
[ -n "$ENV_FILE" ] && RUN_ARGS+=(--env-file "$ENV_FILE")
[ -n "$NETWORK" ]  && RUN_ARGS+=(--network "$NETWORK")
[ -n "$SHM_SIZE" ] && RUN_ARGS+=(--shm-size "$SHM_SIZE")
[ -n "$MEMORY" ]      && RUN_ARGS+=(--memory "$MEMORY")
[ -n "$MEMORY_SWAP" ] && RUN_ARGS+=(--memory-swap "$MEMORY_SWAP")
for K in ${ENV_KEYS[@]+"${ENV_KEYS[@]}"}; do RUN_ARGS+=(-e "$K"); done
for L in ${LABELS[@]+"${LABELS[@]}"}; do RUN_ARGS+=(--label "$L"); done
for H in ${ADDHOSTS[@]+"${ADDHOSTS[@]}"}; do RUN_ARGS+=(--add-host "$H"); done

docker run "${RUN_ARGS[@]}" "$IMAGE" ${CMD[@]+"${CMD[@]}"} >/dev/null \
  || { echo "container start FAILED: $NAME" >&2; exit 1; }

# 즉사 크래시 검증 - docker run -d 는 프로세스가 바로 죽어도 성공을 반환하므로, 잠깐 기다린 뒤
# "Running 이고 재시작이 없었는가"를 본다. restart 정책이 크래시 루프를 가리는 경우는
# RestartCount 로 잡힌다. 애플리케이션 수준 준비 판정은 이 블록이 아니라 healthcheck.sh 소관.
sleep "$VERIFY_WAIT"
RUNNING=$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)
RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$NAME" 2>/dev/null || echo -1)

if [ "$RUNNING" != "true" ] || [ "$RESTARTS" != "0" ]; then
  echo "container verify FAILED: $NAME (running=$RUNNING restarts=$RESTARTS)" >&2
  echo "--- last logs ---" >&2
  docker logs --tail 20 "$NAME" >&2 2>&1 || true
  exit 1
fi

echo "container OK: $NAME ($IMAGE)"
