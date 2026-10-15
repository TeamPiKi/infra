#!/usr/bin/env bash
#
# ops 를 사람이 확인한 커밋 그대로 받는다. 사용법은 action.yml.
# 확인 뒤에 루틴이 같은 id 의 패치를 다시 써도 확인한 내용만 PR 로 올라간다.
#
# 인자:
#   --url   (필수) ops 원격 주소
#   --ref   (필수) 사람이 확인한 ops 커밋 sha (40자)
#   --dest  (필수) 받을 디렉토리. 아직 없어야 한다
#
# 종료 코드: 성공 0, 실패 1, 인자 오류 2.

set -euo pipefail

URL=""
REF=""
DEST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url)  URL="${2:-}"; shift 2;;
    --ref)  REF="${2:-}"; shift 2;;
    --dest) DEST="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$URL" ] || { echo "--url is required" >&2; exit 2; }
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "--ref must be a full commit sha" >&2; exit 2; }
if [ -z "$DEST" ] || [ -e "$DEST" ]; then
  echo "--dest must be a new path" >&2
  exit 2
fi

git init -q "$DEST"
# 심볼릭 링크를 일반 파일로 받아, 항목 파일이 이 repo 의 .git/config(토큰) 같은 곳을 가리키지 못하게 한다.
git -C "$DEST" config core.symlinks false
git -C "$DEST" fetch -q --depth 1 "$URL" "$REF" || { echo "fetch failed" >&2; exit 1; }
git -C "$DEST" checkout -q --detach FETCH_HEAD
