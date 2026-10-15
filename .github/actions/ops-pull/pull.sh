#!/usr/bin/env bash
#
# 사람이 고른 ops patches 항목 하나를 autofix/<id> PR 로 열고 그 PR 의 승인 대기 CI 를 승인한다. 사용법은 action.yml.
# 현재 디렉토리는 이 repo 의 checkout 이어야 하고 origin 으로 push 할 수 있어야 한다.
#
# 인자:
#   --patches  (필수) ops 의 patches 디렉토리. 항목은 <id>/meta.json·patch.diff·pr.md
#   --id       (필수) 열 항목의 id. YYYYMMDD-N
#   --base     PR base 브랜치. 기본 main
# 환경 변수:
#   GITHUB_REPOSITORY (필수) owner/name. 항목의 meta.json repo 가 name 과 같아야 한다
#   GH_TOKEN          (필수) contents·pull-requests·actions 쓰기
#   DENY_PATTERN      공개 repo 면 필수. check.sh 로 넘어간다
#
# 종료 코드: PR 을 열었거나 이미 있음 0, 거부·실패 1, 인자 오류 2.
# 공개 repo 의 Actions 로그에 실리므로 id·PR 번호·사유 밖의 값을 출력하지 않는다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES=""
ID=""
BASE="main"

while [ $# -gt 0 ]; do
  case "$1" in
    --patches) PATCHES="${2:-}"; shift 2;;
    --id)      ID="${2:-}"; shift 2;;
    --base)    BASE="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -d "$PATCHES" ] || { echo "--patches must be a directory" >&2; exit 2; }
[[ "$ID" =~ ^[0-9]{8}-[0-9]{1,2}$ ]] || { echo "--id must be YYYYMMDD-N" >&2; exit 2; }
[ -n "$BASE" ] || { echo "--base is empty" >&2; exit 2; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "GITHUB_REPOSITORY is required" >&2; exit 2; }
[ -n "${GH_TOKEN:-}" ] || { echo "GH_TOKEN is required" >&2; exit 2; }

OWNER="${GITHUB_REPOSITORY%%/*}"
NAME="${GITHUB_REPOSITORY#*/}"
API="repos/$GITHUB_REPOSITORY"
ENTRY="$PATCHES/$ID"
BRANCH="autofix/$ID"

fail() { echo "::error::$ID: $1"; exit 1; }

# 공개 repo 는 PR 이 열리는 순간 공개되어 URL·금지어 검사를 켠다. 입력값이 아니라 repo 설정으로 정해 설정 실수에 닫힌다.
PRIVATE=$(gh api "$API" --jq .private)
GUARD=()
if [ "$PRIVATE" != true ]; then
  [ -n "${DENY_PATTERN:-}" ] || { echo "DENY_PATTERN is required for a public repository" >&2; exit 2; }
  GUARD=(--leak-guard)
fi

if [ -L "$ENTRY" ] || [ ! -d "$ENTRY" ]; then
  fail "not found"
fi
[ "$(jq -r '.repo // empty' "$ENTRY/meta.json" 2>/dev/null)" = "$NAME" ] || fail "not for this repository"

# 닫힌 PR 도 센다. 머지 뒤 브랜치를 지워도 같은 패치를 다시 열지 않는다.
COUNT=$(gh api "$API/pulls?state=all&head=$OWNER:$BRANCH&per_page=1" --jq length)
if [ "$COUNT" != 0 ]; then
  echo "$ID: PR exists"
  exit 0
fi

WORK=$(mktemp -d)
# 같은 job 의 뒤 step 이 패치가 적용된 트리를 실행하지 않게 base 로 되돌린다.
restore() {
  git checkout -q -f --detach "origin/$BASE" 2>/dev/null || true
  git clean -q -fdx || true
  rm -rf "$WORK"
}
trap restore EXIT

git fetch -q origin "$BASE"
git checkout -q -f -B "$BRANCH" "origin/$BASE"
git clean -q -fdx
git apply --index "$ENTRY/patch.diff" 2>/dev/null || fail "patch does not apply"

if ! REASON=$("$SCRIPT_DIR/check.sh" "$ENTRY" ${GUARD[@]+"${GUARD[@]}"}); then
  fail "rejected (${REASON:-check error})"
fi

TITLE=$(head -n 1 "$ENTRY/pr.md")
git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -q --no-verify -m "$TITLE"
SHA=$(git rev-parse HEAD)
git push -q -f origin "$BRANCH" 2>/dev/null || fail "push failed"
tail -n +3 "$ENTRY/pr.md" > "$WORK/body.md"
NUMBER=$(gh api "$API/pulls" -f title="$TITLE" -f head="$BRANCH" -f base="$BASE" -F body=@"$WORK/body.md" --jq .number) \
  || fail "could not open PR"
echo "$ID: opened #$NUMBER"

# GITHUB_TOKEN 이 연 PR 의 pull_request 실행은 승인 대기로 멈추고, 실행은 워크플로마다 시차를 두고 생긴다.
# 같은 이름의 fork 브랜치 실행을 승인하지 않게 push 한 커밋·이 repo·이벤트로 거른다.
SEEN=" "
APPROVED=0
FAILED=0
for _ in 1 2 3 4 5 6; do
  sleep 10
  if ! IDS=$(gh api "$API/actions/runs?branch=$BRANCH&event=pull_request&status=action_required" \
    | jq -r --arg sha "$SHA" --arg repo "$GITHUB_REPOSITORY" \
      '.workflow_runs[] | select(.head_sha == $sha and .head_repository.full_name == $repo and .event == "pull_request") | .id'); then
    FAILED=1
    continue
  fi
  for RUN in $IDS; do
    case "$SEEN" in *" $RUN "*) continue;; esac
    SEEN="$SEEN$RUN "
    if gh api -X POST "$API/actions/runs/$RUN/approve" >/dev/null 2>&1; then
      APPROVED=$((APPROVED + 1))
    else
      FAILED=1
    fi
  done
done
[ "$FAILED" = 0 ] || fail "CI approval failed"
[ "$APPROVED" -gt 0 ] || fail "no CI run approved"
