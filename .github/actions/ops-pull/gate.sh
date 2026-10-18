#!/usr/bin/env bash
#
# 이슈 편집 이벤트가 승인 이슈의 승인 체크인지 판정한다. 사용법은 action.yml.
# 승인은 이 repo 에 쓰기 권한이 있는 사람만 할 수 있다. 루틴은 이 repo 에 접근하지 못해 대신 체크할 수 없다.
#
# 환경 변수:
#   GITHUB_EVENT_PATH (필수) issues edited 이벤트 JSON
#   GITHUB_REPOSITORY (필수), GH_TOKEN (필수)
#
# 출력: 승인이면 "<id> <커밋 sha>" 한 줄. 승인이 아니면 아무것도 내지 않는다.
# 종료 코드: 판정 끝 0, 쓰기 권한 없는 사람의 체크 1, 인자·실행 오류 2.

set -euo pipefail

[ -f "${GITHUB_EVENT_PATH:-}" ] || { echo "GITHUB_EVENT_PATH is required" >&2; exit 2; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "GITHUB_REPOSITORY is required" >&2; exit 2; }
[ -n "${GH_TOKEN:-}" ] || { echo "GH_TOKEN is required" >&2; exit 2; }

ev() { jq -r "$1 // empty" "$GITHUB_EVENT_PATH"; }

[ "$(ev .action)" = edited ] || exit 0
[ "$(ev .issue.state)" = open ] || exit 0
[ "$(ev .issue.user.login)" = "github-actions[bot]" ] || exit 0
[ "$(ev .issue.user.type)" = Bot ] || exit 0

TITLE_RE='^ops 패치 ([0-9]{8}-[0-9]{1,2}) 승인$'
MARK_RE='^<!-- ops-approval id=([0-9]{8}-[0-9]{1,2}) commit=([0-9a-f]{40}) -->$'

[[ "$(ev .issue.title)" =~ $TITLE_RE ]] || exit 0
ID="${BASH_REMATCH[1]}"

# 웹에서 편집한 본문은 줄 끝이 CRLF 가 된다.
BODY=$(ev .issue.body | tr -d '\r')
OLD=$(ev .changes.body.from | tr -d '\r')
[[ "$(head -n 1 <<<"$BODY")" =~ $MARK_RE ]] || exit 0
[ "${BASH_REMATCH[1]}" = "$ID" ] || exit 0
COMMIT="${BASH_REMATCH[2]}"

# 체크하지 않은 상태에서 체크한 편집만 승인으로 본다. 이미 체크된 이슈의 다른 편집은 무시한다.
grep -qE '^- \[[xX]\] 승인$' <<<"$BODY" || exit 0
grep -qE '^- \[ \] 승인$' <<<"$OLD" || exit 0

SENDER=$(ev .sender.login)
if [ "$(ev .sender.type)" != User ] || ! [[ "$SENDER" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "::warning::$ID: approval by a non-user ignored"
  exit 1
fi
PERMISSION=$(gh api "repos/$GITHUB_REPOSITORY/collaborators/$SENDER/permission" --jq .permission)
case "$PERMISSION" in
  admin|write) ;;
  *) echo "::warning::$ID: approval by a user without write access ignored"; exit 1;;
esac

echo "$ID $COMMIT"
