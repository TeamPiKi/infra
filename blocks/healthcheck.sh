#!/usr/bin/env bash
#
# 공통 배포 블록: 헬스체크 폴링
#
# 대상 URL 을 "준비 완료(HTTP 200)"까지 폴링한다.
# 실행 위치 중립 - 순수 bash + curl 만 쓰므로 SSH runner 에서든 SSM in-box 에서든
# 같은 스크립트가 그대로 돈다. transport 는 이 블록을 호출하는 쪽이 책임진다.
#
# 계약: 각 서비스는 준비되면 헬스 경로에 HTTP 200 을 반환한다 (contracts/health.md).
#       200 이면 통과, 그 외(4xx/5xx/연결 실패)는 아직 준비 안 됨 -> 재시도.
#
# 사용 예:
#   healthcheck.sh --url http://localhost:8081/health --interval 5 --attempts 60
#   healthcheck.sh --url http://localhost:8000/health --interval 3 --attempts 20 --expect-body '"ok":true'
#   healthcheck.sh --url http://localhost:8090/actuator/health --interval 5 --attempts 24 --expect-body '"status":"UP"'
#
# 인자:
#   --url          (필수) 헬스 엔드포인트 전체 URL
#   --interval     (필수) 폴링 간격(초)
#   --attempts     (필수) 최대 시도 횟수
#   --timeout      각 요청 curl 타임아웃(초). 기본 5 (서비스 무관 공통값)
#   --expect-body  (선택) 응답 본문에 포함돼야 할 문자열. 없으면 HTTP 200 만으로 판정
#
# interval·attempts 는 서비스 기동 특성(JVM+DB vs 브라우저)에 따라 다르므로 default 를 두지
# 않는다. default 를 두면 특정 서비스 값과 우연히 겹쳐(예: server 5x60) 명시 세팅을 빠뜨려도
# 조용히 통과해버린다. 값의 출처는 호출부(서비스별 배포 설정)가 유일하게 책임진다.
#
# 종료 코드: 성공 0, 모든 시도 소진 후 실패 1, 인자 오류 2

set -euo pipefail

URL=""
INTERVAL=""
ATTEMPTS=""
TIMEOUT=5
EXPECT_BODY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url)         URL="${2:-}"; shift 2;;
    --interval)    INTERVAL="${2:-}"; shift 2;;
    --attempts)    ATTEMPTS="${2:-}"; shift 2;;
    --timeout)     TIMEOUT="${2:-}"; shift 2;;
    --expect-body) EXPECT_BODY="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$URL" ]      || { echo "--url is required" >&2; exit 2; }
[ -n "$INTERVAL" ] || { echo "--interval is required" >&2; exit 2; }
[ -n "$ATTEMPTS" ] || { echo "--attempts is required" >&2; exit 2; }

for i in $(seq 1 "$ATTEMPTS"); do
  # body 와 http_code 를 한 번에 받아 분리한다 (expect-body 판정 때문에 body 도 캡처).
  RESP=$(curl -sS -m "$TIMEOUT" -w $'\n%{http_code}' "$URL" 2>/dev/null || printf '\n000')
  CODE="${RESP##*$'\n'}"
  BODY="${RESP%$'\n'*}"

  if [ "$CODE" = "200" ]; then
    if [ -z "$EXPECT_BODY" ] || printf '%s' "$BODY" | grep -qF -- "$EXPECT_BODY"; then
      echo "health OK (attempt $i/$ATTEMPTS, code=$CODE) $URL"
      exit 0
    fi
  fi

  echo "waiting... (attempt $i/$ATTEMPTS, code=$CODE)"
  [ "$i" -lt "$ATTEMPTS" ] && sleep "$INTERVAL"
done

echo "health FAILED after $ATTEMPTS attempts: $URL" >&2
exit 1
