#!/usr/bin/env bash
#
# .github/actions/ops-pull/fetch.sh 셀프 테스트. ops 는 로컬 bare repo 로 대신한다.
#
# 실행: ./.github/actions/ops-pull/fetch.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH="$SCRIPT_DIR/fetch.sh"

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

FAILURES=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (expected=[$expected] actual=[$actual])" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=t -c user.email=t@example.com "$@"; }

# GitHub 은 광고하지 않은 커밋도 sha 로 받게 해 준다. 로컬 서버는 이 설정이 있어야 같다.
OPS="$WORKDIR/ops.git"
SRC="$WORKDIR/src"
g init -q --bare "$OPS"
g -C "$OPS" config uploadpack.allowAnySHA1InWant true
g init -q "$SRC"
mkdir -p "$SRC/patches/20261015-1"
printf 'v1\n' > "$SRC/patches/20261015-1/pr.md"
ln -s ../../.git/config "$SRC/patches/20261015-1/meta.json"
g -C "$SRC" add -A
g -C "$SRC" commit -qm v1
REVIEWED=$(g -C "$SRC" rev-parse HEAD)
printf 'v2\n' > "$SRC/patches/20261015-1/pr.md"
# ops 의 속성 파일이 필터를 켜는지 본다. 필터 정의는 러너의 시스템 설정에 있다고 가정해 환경 변수로 넣는다.
printf 'patches/** filter=probe\n' > "$SRC/.gitattributes"
g -C "$SRC" add .gitattributes
g -C "$SRC" commit -qam v2
g -C "$SRC" push -q "$OPS" HEAD:refs/heads/main

# 1. 인자 오류
"$FETCH" --url "$OPS" --ref abc123 --dest "$WORKDIR/d0" >/dev/null 2>&1
check "짧은 sha -> exit 2" 2 "$?"
"$FETCH" --url "$OPS" --ref main --dest "$WORKDIR/d0" >/dev/null 2>&1
check "브랜치 이름 -> exit 2" 2 "$?"
mkdir "$WORKDIR/exists"
"$FETCH" --url "$OPS" --ref "$REVIEWED" --dest "$WORKDIR/exists" >/dev/null 2>&1
check "이미 있는 dest -> exit 2" 2 "$?"
"$FETCH" --url "$OPS" --ref "$REVIEWED" --branch main --dest "$WORKDIR/d0" >/dev/null 2>&1
check "ref 와 branch 둘 다 -> exit 2" 2 "$?"
"$FETCH" --url "$OPS" --dest "$WORKDIR/d0" >/dev/null 2>&1
check "ref 도 branch 도 없음 -> exit 2" 2 "$?"
"$FETCH" --url "$OPS" --branch 'main;x' --dest "$WORKDIR/d0" >/dev/null 2>&1
check "브랜치 이름이 아님 -> exit 2" 2 "$?"

# 2. 없는 커밋
"$FETCH" --url "$OPS" --ref "$(printf '0%.0s' $(seq 1 40))" --dest "$WORKDIR/d1" >/dev/null 2>&1
check "없는 커밋 -> exit 1" 1 "$?"

# 3. 확인한 커밋 그대로
"$FETCH" --url "$OPS" --ref "$REVIEWED" --dest "$WORKDIR/d2" >/dev/null 2>&1
check "성공 exit 0" 0 "$?"
check "main 이 아니라 확인한 커밋의 내용" v1 "$(cat "$WORKDIR/d2/patches/20261015-1/pr.md")"
if [ -L "$WORKDIR/d2/patches/20261015-1/meta.json" ]; then R="link"; else R="regular"; fi
check "심볼릭 링크는 일반 파일로" regular "$R"

# 4. 브랜치 전체 이력
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=filter.probe.smudge GIT_CONFIG_VALUE_0="touch $WORKDIR/smudged; cat" \
  "$FETCH" --url "$OPS" --branch main --dest "$WORKDIR/d3" >/dev/null 2>&1
check "브랜치 받기 exit 0" 0 "$?"
if [ -e "$WORKDIR/smudged" ]; then R="ran"; else R="skipped"; fi
check "ops 의 속성 파일로 필터가 돌지 않음" skipped "$R"
check "브랜치 끝 내용" v2 "$(cat "$WORKDIR/d3/patches/20261015-1/pr.md")"
check "이력 전체" 2 "$(git -C "$WORKDIR/d3" rev-list --count HEAD)"
if [ -L "$WORKDIR/d3/patches/20261015-1/meta.json" ]; then R="link"; else R="regular"; fi
check "브랜치 받기도 심볼릭 링크는 일반 파일로" regular "$R"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "all passed"
