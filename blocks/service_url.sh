#!/usr/bin/env bash
#
# 공통 배포 블록: 다른 서비스의 사설 주소 계산
#
# 포트 정본(contracts/ports.json)에서 서비스의 포트와 서버 Name 태그를 읽고, 그 태그로 실행 중인
# 인스턴스의 사설 IP 를 찾아 http://IP:PORT 를 만든다. 주소를 시크릿·SSM 에 적어 두면 포트나 박스가
# 바뀔 때 조용히 낡는다 - 호출자 배포가 매번 이 블록으로 다시 계산한다.
#
# 실행 위치: AWS 자격(ec2:DescribeInstances)과 jq 가 있는 러너.
#
# 사용 예:
#   RENDERER_URL=$(bash shared-infra/blocks/service_url.sh \
#     --ports-file shared-infra/contracts/ports.json --service renderer)
#
# 인자:
#   --ports-file (필수) contracts/ports.json 경로
#   --service    (필수) 정본의 서비스 키 (box 가 있어야 한다)
#   --region     (선택) AWS 리전. 없으면 AWS_REGION·AWS_DEFAULT_REGION 을 aws CLI 가 읽는다
#
# 출력: http://<사설 IP>:<포트> 한 줄 (stdout)
# 종료 코드: 성공 0, 조회 실패(실행 중 인스턴스가 정확히 하나가 아님) 1, 인자·정본 오류 2

set -euo pipefail

PORTS_FILE=""
SERVICE=""
REGION_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --ports-file) PORTS_FILE="${2:-}"; shift 2;;
    --service)    SERVICE="${2:-}"; shift 2;;
    --region)     REGION_ARGS=(--region "${2:-}"); shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$PORTS_FILE" ] || { echo "--ports-file is required" >&2; exit 2; }
[ -f "$PORTS_FILE" ] || { echo "ports file not found: $PORTS_FILE" >&2; exit 2; }
[ -n "$SERVICE" ]    || { echo "--service is required" >&2; exit 2; }

PORT=$(jq -er --arg s "$SERVICE" '.[$s].port' "$PORTS_FILE") \
  || { echo "service not in ports file: $SERVICE" >&2; exit 2; }
BOX=$(jq -er --arg s "$SERVICE" '.[$s].box' "$PORTS_FILE") \
  || { echo "service has no box in ports file: $SERVICE" >&2; exit 2; }

IPS=$(aws ec2 describe-instances "${REGION_ARGS[@]+"${REGION_ARGS[@]}"}" \
  --filters "Name=tag:Name,Values=$BOX" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' --output text) \
  || { echo "describe-instances failed for $BOX" >&2; exit 1; }

# 둘 이상이면 어느 쪽을 부를지 모른다. 교체 중 겹침도 조용히 고르지 않고 멈춘다.
read -r -a IP_LIST <<< "$IPS"
if [ "${#IP_LIST[@]}" -ne 1 ]; then
  echo "expected exactly one running instance named $BOX (got: ${#IP_LIST[@]})" >&2
  exit 1
fi

echo "http://${IP_LIST[0]}:$PORT"
