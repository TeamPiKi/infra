#!/usr/bin/env bash
#
# blocks/alloy/provision-alloy-ssm.sh 셀프 테스트
#
# 인자 검증과, 이 블록의 존재 이유인 두 계약을 실측한다:
#   (1) SSM 필수 5종 실패는 즉시 중단 - 부분 자격으로 기동하면 수집기는 살아 있는데 일부 신호만
#       유실되는, 가장 알아채기 어려운 상태가 된다. traces 2종만 빈 값 허용.
#   (2) provision-alloy.sh 로 넘어가는 인자가 정확할 것 - 특히 --version 은 미지정 시 넘기지 않는다
#       (운영 버전 핀의 SSOT 는 provision-alloy.sh 의 default 이고, 여기서 복제하면 두 곳이 어긋난다).
#
# docker·SSM 을 타지 않는다: 임시 디렉터리에 블록을 복사하고 형제 자리에 provision-alloy.sh 스텁을,
# PATH 앞에 docker 스텁을 둬 실제 호출을 가로챈다. conventions/blocks.md 5번 원칙(셀프 검증 가능)의 실행체.
#
# 실행: ./blocks/alloy/provision-alloy-ssm.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCK="$SCRIPT_DIR/provision-alloy-ssm.sh"

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

FAILURES=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# 블록 사본 + 형제 자리 스텁. 스텁은 받은 인자와 자격 env 를 파일로 기록만 한다.
BIN="$WORKDIR/bin"
mkdir -p "$BIN"
cp "$BLOCK" "$WORKDIR/provision-alloy-ssm.sh"
cat >"$WORKDIR/provision-alloy.sh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >"$ARGS_OUT"
{ echo "METRICS_URL=${GRAFANA_METRICS_URL:-}"; echo "TRACES_URL=${GRAFANA_TRACES_URL:-}"; } >"$ENV_OUT"
STUB
chmod +x "$WORKDIR/provision-alloy.sh"

# docker 스텁 - FAIL_PARAM 에 지정된 SSM 파라미터만 실패시키고 나머지는 값을 뱉는다.
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in /piki/observability/*) NAME="${a##*/}";; esac
done
if [ "${FAIL_PARAM:-}" = "$NAME" ]; then exit 1; fi
echo "value-of-$NAME"
STUB
chmod +x "$BIN/docker"

export PATH="$BIN:$PATH"
export ARGS_OUT="$WORKDIR/args.txt" ENV_OUT="$WORKDIR/env.txt"

run() { bash "$WORKDIR/provision-alloy-ssm.sh" "$@" >/dev/null 2>&1; echo $?; }

# 1. 인자 검증 (exit 2)
check "--config 누락 -> 2" "2" "$(run --environment dev --box piki-core)"
check "--environment 누락 -> 2" "2" "$(run --config /c --box piki-core)"
check "--box 누락 -> 2" "2" "$(run --config /c --environment dev)"
check "unknown arg -> 2" "2" "$(run --config /c --environment dev --box b --bogus x)"

# 2. 필수 자격 5종은 하나만 실패해도 즉시 중단 (exit 1)
for p in grafana-metrics-url grafana-metrics-user grafana-logs-url grafana-logs-user grafana-cloud-token; do
  check "필수 자격 $p 실패 -> 1" "1" "$(FAIL_PARAM=$p run --config /c --environment dev --box piki-core)"
done

# 3. traces 2종은 빈 값 허용 (성공)
check "traces-url 실패해도 성공" "0" "$(FAIL_PARAM=grafana-traces-url run --config /c --environment prod --box piki-extractor)"
check "traces 실패 시 빈 값으로 전달" "TRACES_URL=" "$(grep '^TRACES_URL=' "$WORKDIR/env.txt")"

# 4. 정상 경로: 인자 전달과 자격 주입
check "정상 실행 -> 0" "0" "$(run --config /tmp/c.alloy --environment prod --box piki-renderer)"
check "provision-alloy.sh 인자 (--version 없음)" \
  "--config /tmp/c.alloy --name piki-alloy --environment prod --box piki-renderer" \
  "$(cat "$WORKDIR/args.txt")"
check "자격이 env 로 주입됨" "METRICS_URL=value-of-grafana-metrics-url" "$(grep '^METRICS_URL=' "$WORKDIR/env.txt")"

# 5. --name·--version 을 주면 그대로 넘긴다 (version 은 명시했을 때만)
run --config /c --environment dev --box piki-core --name custom-alloy --version v9.9.9 >/dev/null
check "--name·--version pass-through" \
  "--config /c --name custom-alloy --environment dev --box piki-core --version v9.9.9" \
  "$(cat "$WORKDIR/args.txt")"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES case(s) failed" >&2
  exit 1
fi

echo "all provision-alloy-ssm.sh cases passed"
