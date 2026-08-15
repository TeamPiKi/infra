#!/usr/bin/env bash
#
# 공통 배포 블록: SSM 자격 로드 + Alloy 프로비저닝
#
# provision-alloy.sh 는 자격증명을 env 로 받는다(ps 노출 방지). 그 env 를 어디서 채우느냐가
# 세 서비스 공통인데도 각자 복제돼 있었다 - core 는 provision-runtime.sh 4절에 인라인,
# extractor·renderer 는 각자의 provision-observability.sh 에. 셋 다 같은 SSM 경로를 읽고 같은
# 필수/선택 구분을 하며 다른 건 --box·--environment 값뿐이라, 경로나 실패 정책이 바뀌면 세 곳을
# 함께 고쳐야 하고 하나만 빠뜨리면 그 박스만 조용히 어긋난다. 이 블록이 그 로직의 SSOT 다.
#
# 자격의 정본은 SSM 공유 경로 `/piki/observability/grafana-*` 다 - 세 서비스 박스가 같은 경로를
# 읽으므로 토큰 회전이 1곳 put-parameter 로 끝난다(TeamPiKi/core#771). 박스는 instance profile
# 권한으로 직접 읽고, 러너(GH secrets)는 자격을 경유하지 않는다.
#
# 실행 위치 중립 - 순수 bash + docker 만 쓴다(박스엔 aws cli 가 없어 dockerized aws-cli 를 쓴다).
# transport(SSH·SSM run-command)는 이 블록을 호출하는 쪽이 책임진다.
#
# 사용 예:
#   provision-alloy-ssm.sh --config /tmp/piki-obs/config.alloy \
#                          --environment prod --box piki-extractor
#
# 인자:
#   --config       (필수) 박스 위 config.alloy 경로 - 그대로 provision-alloy.sh 에 넘긴다
#   --environment  (필수) 환경 라벨 (dev/prod)
#   --box          (필수) 박스 주인 서비스 (piki-core·piki-extractor·piki-renderer)
#   --name         Alloy 컨테이너명. 기본 piki-alloy
#   --region       SSM 리전. 기본 ap-northeast-2
#   --version      Alloy 이미지 태그 - 미지정 시 provision-alloy.sh 의 default 를 따른다(핀 SSOT 유지)
#
# 종료 코드: 성공 0, 필수 자격 조회 실패 1, 인자 오류 2, 그 외 provision-alloy.sh 의 코드를 그대로 전달
#
# 주의: 필수 5종(metrics·logs 의 URL/USER, token) 실패는 즉시 중단한다 - 부분 자격으로 기동하면
#       수집기가 살아는 있는데 일부 신호만 유실되는, 가장 알아채기 어려운 상태가 된다.
#       traces 2종은 빈 값을 허용한다(provision-alloy.sh 가 더미 endpoint 로 무해 처리).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG=""
ENVIRONMENT=""
BOX=""
NAME="piki-alloy"
REGION="ap-northeast-2"
VERSION=""
# 박스엔 aws cli 가 없어 컨테이너로 쓴다. 이미지 핀은 소비 repo 의 SSM pull 과 같은 버전을 유지한다.
AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.35.21"

while [ $# -gt 0 ]; do
  case "$1" in
    --config)      CONFIG="${2:-}"; shift 2;;
    --environment) ENVIRONMENT="${2:-}"; shift 2;;
    --box)         BOX="${2:-}"; shift 2;;
    --name)        NAME="${2:-}"; shift 2;;
    --region)      REGION="${2:-}"; shift 2;;
    --version)     VERSION="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$CONFIG" ]      || { echo "--config is required" >&2; exit 2; }
[ -n "$ENVIRONMENT" ] || { echo "--environment is required" >&2; exit 2; }
[ -n "$BOX" ]         || { echo "--box is required" >&2; exit 2; }

obs_param() {
  docker run --rm --network host "$AWSCLI_IMAGE" ssm get-parameter \
    --name "/piki/observability/$1" --with-decryption \
    --region "$REGION" --query Parameter.Value --output text
}

GRAFANA_METRICS_URL="$(obs_param grafana-metrics-url)" || { echo "[alloy] SSM grafana-metrics-url 조회 실패 - IAM(app_ssm_read)·파라미터 존재 확인" >&2; exit 1; }
GRAFANA_METRICS_USER="$(obs_param grafana-metrics-user)" || { echo "[alloy] SSM grafana-metrics-user 조회 실패" >&2; exit 1; }
GRAFANA_LOGS_URL="$(obs_param grafana-logs-url)" || { echo "[alloy] SSM grafana-logs-url 조회 실패" >&2; exit 1; }
GRAFANA_LOGS_USER="$(obs_param grafana-logs-user)" || { echo "[alloy] SSM grafana-logs-user 조회 실패" >&2; exit 1; }
GRAFANA_CLOUD_TOKEN="$(obs_param grafana-cloud-token)" || { echo "[alloy] SSM grafana-cloud-token 조회 실패" >&2; exit 1; }
# traces 미등록 박스도 정상이다 - 빈 값이면 provision-alloy.sh 가 더미 endpoint 로 넘긴다.
GRAFANA_TRACES_URL="$(obs_param grafana-traces-url)" || GRAFANA_TRACES_URL=""
GRAFANA_TRACES_USER="$(obs_param grafana-traces-user)" || GRAFANA_TRACES_USER=""

export GRAFANA_METRICS_URL GRAFANA_METRICS_USER GRAFANA_LOGS_URL GRAFANA_LOGS_USER
export GRAFANA_TRACES_URL GRAFANA_TRACES_USER GRAFANA_CLOUD_TOKEN
echo "[alloy] Grafana 자격 SSM 로드 완료 (/piki/observability/grafana-*)"

# --version 은 미지정 시 넘기지 않는다 - provision-alloy.sh 의 default 가 운영 버전 핀의 SSOT 라,
# 여기서 기본값을 복제하면 두 곳이 어긋날 수 있다.
set -- --config "$CONFIG" --name "$NAME" --environment "$ENVIRONMENT" --box "$BOX"
[ -n "$VERSION" ] && set -- "$@" --version "$VERSION"

exec bash "$SCRIPT_DIR/provision-alloy.sh" "$@"
