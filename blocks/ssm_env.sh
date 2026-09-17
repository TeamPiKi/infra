#!/usr/bin/env bash
#
# 공통 배포 블록: SSM 파라미터 JSON -> docker --env-file 용 KEY=VALUE 파일
#
# `aws ssm get-parameters-by-path --output json` 의 출력을 stdin 으로 받아, 각 파라미터의
# 마지막 경로 조각(kebab-case)을 UPPER_SNAKE 로 복원해 --out 파일에 KEY=VALUE 한 줄씩 쓴다.
# aws-cli 를 어디서 어떻게 실행하나(박스 설치본·컨테이너·프로파일)는 호출자 소관이라 이 블록은
# 네트워크·자격을 만지지 않는다 (conventions/blocks.md 1번).
#
# 사용 예:
#   aws ssm get-parameters-by-path --path /piki-x/app/ --recursive --with-decryption --output json \
#     | bash ssm_env.sh --out "$ENV_FILE" --reserve IMAGE_TAG --reserve ENVIRONMENT
#
# 실패로 끊는 것 (exit 1):
#   - 파라미터 0개: 경로 오타·권한 누락이 빈 env 로 조용히 배포되는 것을 막는다
#   - 값에 실제 개행: docker --env-file 은 줄 단위라 둘째 줄부터 다른 변수로 읽힌다. 문자 그대로의
#     백슬래시-n 두 글자는 개행이 아니므로 그대로 통과한다 (PEM 은 그 형식으로 저장한다)
#   - --reserve 로 지정한 이름과 충돌: 호출자가 -e 로 따로 넘기는 배포 제어 값을 SSM 키가 덮는 것을 막는다
#
# 값은 stdout·stderr 에 절대 쓰지 않는다. 파일은 umask 077 로 만든다. 값의 형식(따옴표·$·=·공백)은
# 해석 없이 바이트 그대로 둔다 - docker --env-file 도 해석하지 않는다.
#
# 인자:
#   --out      (필수) 출력 파일 경로. 있으면 덮어쓴다
#   --reserve  (선택, 반복) SSM 키가 가지면 안 되는 UPPER_SNAKE 이름
#
# 종료 코드: 성공 0, 실패 1, 인자 오류 2. 성공 시 stdout 에 기록한 줄 수 하나.

set -euo pipefail

OUT=""
RESERVED=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out)     OUT="${2:-}"; shift 2;;
    --reserve) [ -n "${2:-}" ] || { echo "--reserve needs a name" >&2; exit 2; }; RESERVED+=("$2"); shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

umask 077
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# 예약 이름은 공백 구분 한 줄로 넘긴다. 값은 이 스크립트를 거치지 않고 python 이 파일에 직접 쓴다.
# 코드는 -c 로 넘긴다 - heredoc 으로 주면 그것이 stdin 을 차지해 JSON 이 들어올 자리가 없다.
RESERVED_LIST="${RESERVED[*]+"${RESERVED[*]}"}"
PY_CODE=$(cat <<'PY'
import json, os, sys

reserved = set(os.environ.get("RESERVED_LIST", "").split())
try:
    params = json.load(sys.stdin).get("Parameters", [])
except json.JSONDecodeError as e:
    sys.exit(f"stdin is not aws ssm JSON: {e}")
if not params:
    sys.exit("no parameters in input")

lines = []
for p in params:
    key = p["Name"].rsplit("/", 1)[-1].replace("-", "_").upper()
    value = p["Value"]
    if key in reserved:
        sys.exit(f"reserved name collision: {key} ({p['Name']})")
    if "\n" in value or "\r" in value:
        sys.exit(f"multi-line value not supported by --env-file: {key}")
    lines.append(f"{key}={value}")

with open(os.environ["OUT_FILE"], "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(len(lines))
PY
)
if ! COUNT="$(RESERVED_LIST="$RESERVED_LIST" OUT_FILE="$TMP" python3 -c "$PY_CODE")"; then
  exit 1
fi

mv -f "$TMP" "$OUT"
trap - EXIT
echo "$COUNT"
