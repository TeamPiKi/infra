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
PULL=0
REPLACE=0
VERIFY_WAIT=2
CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="${2:-}"; shift 2;;
    --image)       IMAGE="${2:-}"; shift 2;;
    --restart)     RESTART="${2:-}"; shift 2;;
    --publish)     PUBLISH+=("${2:-}"); shift 2;;
    --env-file)    ENV_FILE="${2:-}"; shift 2;;
    --network)     NETWORK="${2:-}"; shift 2;;
    --pull)        PULL=1; shift;;
    --replace)     REPLACE=1; shift;;
    --verify-wait) VERIFY_WAIT="${2:-}"; shift 2;;
    --)            shift; CMD=("$@"); break;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$NAME" ]    || { echo "--name is required" >&2; exit 2; }
[ -n "$IMAGE" ]   || { echo "--image is required" >&2; exit 2; }
[ -n "$RESTART" ] || { echo "--restart is required" >&2; exit 2; }
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
