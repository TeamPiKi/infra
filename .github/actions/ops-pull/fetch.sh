#!/usr/bin/env bash
#
# ops 를 받는다. 사용법은 action.yml.
#
# 인자:
#   --url     (필수) ops 원격 주소
#   --ref     사람이 확인한 ops 커밋 sha (40자). 그 커밋 하나만 받는다
#   --branch  이 브랜치를 전체 이력으로 받는다. 항목이 커밋 하나로 만들어졌는지 보려면 이력이 필요하다
#   --dest    (필수) 받을 디렉토리. 아직 없어야 한다
#   --ref 와 --branch 중 하나만 준다.
#
# 종료 코드: 성공 0, 실패 1, 인자 오류 2.

set -euo pipefail

URL=""
REF=""
BRANCH=""
DEST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url)    URL="${2:-}"; shift 2;;
    --ref)    REF="${2:-}"; shift 2;;
    --branch) BRANCH="${2:-}"; shift 2;;
    --dest)   DEST="${2:-}"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$URL" ] || { echo "--url is required" >&2; exit 2; }
if [ -n "$REF" ] && [ -n "$BRANCH" ]; then
  echo "give only one of --ref and --branch" >&2
  exit 2
fi
if [ -n "$REF" ]; then
  [[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "--ref must be a full commit sha" >&2; exit 2; }
elif [ -n "$BRANCH" ]; then
  [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "--branch is not a branch name" >&2; exit 2; }
else
  echo "--ref or --branch is required" >&2
  exit 2
fi
if [ -z "$DEST" ] || [ -e "$DEST" ]; then
  echo "--dest must be a new path" >&2
  exit 2
fi

git init -q "$DEST"
# 심볼릭 링크를 일반 파일로 받아, 항목 파일이 이 repo 의 .git/config(토큰) 같은 곳을 가리키지 못하게 한다.
git -C "$DEST" config core.symlinks false
if [ -n "$REF" ]; then
  git -C "$DEST" fetch -q --depth 1 "$URL" "$REF" || { echo "fetch failed" >&2; exit 1; }
else
  git -C "$DEST" fetch -q "$URL" "refs/heads/$BRANCH" || { echo "fetch failed" >&2; exit 1; }
fi
# ops 의 .gitattributes 를 읽지 않는다. filter=lfs 와 .lfsconfig 로 러너가 외부에 요청하고 그 응답이 공개 로그에 찍힌다.
git -C "$DEST" -c attr.tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904 checkout -q --detach FETCH_HEAD
