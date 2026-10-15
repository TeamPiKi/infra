#!/usr/bin/env bash
#
# ops 에서 이 repo 에 아직 승인을 요청하지 않은 패치 항목을 찾는다. 사용법은 action.yml.
# 현재 디렉토리는 이 repo 의 checkout 이어야 한다. origin 의 autofix 브랜치를 본다.
# 승인 이슈가 한 번 생긴 항목은 이슈가 닫혀도 다시 찾지 않는다. 거절은 이슈를 닫는 것이다.
#
# 인자:
#   --ops          (필수) ops 브랜치의 전체 이력 클론
#   --window-days  만든 지 이 일수가 지난 항목은 보지 않는다. 기본 2
# 환경 변수:
#   GITHUB_REPOSITORY (필수) owner/name. 항목의 meta.json repo 가 name 과 같은 것만 본다
#   GH_TOKEN          (필수) pull-requests·issues 읽기
#
# 출력: 대상마다 "<id> <항목을 만든 커밋 sha>" 한 줄.
# 종료 코드: 성공 0, 인자 오류 2.
# 공개 repo 의 Actions 로그에 실리므로 id 밖의 값을 출력하지 않는다.

set -euo pipefail

OPS=""
WINDOW_DAYS=2

while [ $# -gt 0 ]; do
  case "$1" in
    --ops)         OPS="${2:-}"; shift 2;;
    --window-days) WINDOW_DAYS="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -d "$OPS/.git" ] || { echo "--ops must be a git clone" >&2; exit 2; }
[[ "$WINDOW_DAYS" =~ ^[0-9]+$ ]] || { echo "--window-days must be a number" >&2; exit 2; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "GITHUB_REPOSITORY is required" >&2; exit 2; }
[ -n "${GH_TOKEN:-}" ] || { echo "GH_TOKEN is required" >&2; exit 2; }

OWNER="${GITHUB_REPOSITORY%%/*}"
NAME="${GITHUB_REPOSITORY#*/}"
API="repos/$GITHUB_REPOSITORY"
# 전체 페이지를 본다. 일부만 보면 이슈가 많이 쌓였을 때 닫힌(거절된) 승인 이슈를 놓쳐 같은 항목을 다시 요청한다.
REQUESTED=$(gh api --paginate "$API/issues?state=all&per_page=100" \
  --jq '.[] | select(.user.login == "github-actions[bot]" and .pull_request == null) | .title')
NOW=$(date +%s)
SINCE=$(( NOW - WINDOW_DAYS * 86400 ))
UNTIL=$(( NOW + 3600 ))

for dir in "$OPS"/patches/*/; do
  dir="${dir%/}"
  id="${dir##*/}"
  [ ! -L "$dir" ] || continue
  [[ "$id" =~ ^[0-9]{8}-[0-9]{1,2}$ ]] || continue
  [ "$(jq -r '.repo // empty' "$dir/meta.json" 2>/dev/null)" = "$NAME" ] || continue

  # 사람이 확인한 내용과 올라가는 내용이 같으려면 항목이 커밋 하나로 만들어지고 그 뒤로 바뀌지 않아야 한다.
  COMMITS=$(git -C "$OPS" log --format=%H -- "patches/$id")
  if [ "$(wc -l <<<"$COMMITS" | tr -d ' ')" != 1 ]; then
    echo "::warning::$id: changed after creation, skipped" >&2
    continue
  fi
  # 미래 날짜 커밋은 기간이 끝나지 않아 사람이 지운 브랜치가 계속 되살아난다.
  CREATED=$(git -C "$OPS" log -1 --format=%ct "$COMMITS")
  if [ "$CREATED" -gt "$UNTIL" ]; then
    echo "::warning::$id: committed in the future, skipped" >&2
    continue
  fi
  [ "$CREATED" -ge "$SINCE" ] || continue

  if grep -qxF "ops 패치 $id 승인" <<<"$REQUESTED"; then
    continue
  fi
  if git ls-remote --exit-code --heads origin "autofix/$id" >/dev/null 2>&1; then
    continue
  fi
  COUNT=$(gh api "$API/pulls?state=all&head=$OWNER:autofix/$id&per_page=1" --jq length)
  [ "$COUNT" = 0 ] || continue

  echo "$id $COMMITS"
done
