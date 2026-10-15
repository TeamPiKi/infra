#!/usr/bin/env bash
#
# 패치 항목 하나의 승인 이슈를 이 repo 에 만든다. 사용법은 action.yml.
# 이슈의 링크가 가리키는 커밋이 곧 승인 뒤 PR 로 올라가는 커밋이라, 사람이 sha 를 맞춰 볼 필요가 없다.
# pr.md 는 렌더링하면 HTML 주석 같은 숨은 글이 안 보여 원문(plain) 링크를 준다.
# 공개 repo 에도 실리므로 id·sha·비공개 ops 링크만 적는다.
#
# 인자:
#   --id        (필수) 항목 id. YYYYMMDD-N
#   --commit    (필수) 항목을 만든 ops 커밋 sha (40자)
#   --ops-repo  (필수) ops repo (owner/name)
# 환경 변수:
#   GITHUB_REPOSITORY (필수), GH_TOKEN (필수) issues 쓰기
#
# 종료 코드: 성공 0(stdout 에 이슈 번호), 실패 1, 인자 오류 2.

set -euo pipefail

ID=""
COMMIT=""
OPS_REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --id)       ID="${2:-}"; shift 2;;
    --commit)   COMMIT="${2:-}"; shift 2;;
    --ops-repo) OPS_REPO="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ "$ID" =~ ^[0-9]{8}-[0-9]{1,2}$ ]] || { echo "--id must be YYYYMMDD-N" >&2; exit 2; }
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "--commit must be a full commit sha" >&2; exit 2; }
[[ "$OPS_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "--ops-repo must be owner/name" >&2; exit 2; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "GITHUB_REPOSITORY is required" >&2; exit 2; }
[ -n "${GH_TOKEN:-}" ] || { echo "GH_TOKEN is required" >&2; exit 2; }

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
cat > "$BODY" <<EOF
<!-- ops-approval id=$ID commit=$COMMIT -->
### ops 패치 \`$ID\`
- [PR 제목·본문 원문](https://github.com/$OPS_REPO/blob/$COMMIT/patches/$ID/pr.md?plain=1)
- [패치](https://github.com/$OPS_REPO/blob/$COMMIT/patches/$ID/patch.diff)
- 커밋 \`$COMMIT\`
- 두 링크의 내용이 그대로 PR 이 됨

- [ ] 승인
EOF

gh api "repos/$GITHUB_REPOSITORY/issues" -f title="ops 패치 $ID 승인" -F body=@"$BODY" --jq .number \
  || { echo "::error::$ID: could not open approval issue"; exit 1; }
