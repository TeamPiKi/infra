#!/usr/bin/env bash
#
# .github/actions/ops-pull/scan.sh 셀프 테스트. ops·origin 은 로컬 repo, gh 는 PATH 앞의 가짜로 대신한다.
#
# 실행: ./.github/actions/ops-pull/scan.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/scan.sh"
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

# ops 이력: 항목마다 커밋 하나. 20261015-3 은 만든 뒤 고쳐짐, 20261001-1 은 오래됨.
OPS_SRC="$WORKDIR/ops-src"
g init -q -b main "$OPS_SRC"
add_entry() {
  mkdir -p "$OPS_SRC/patches/$1"
  printf '{"repo":"%s"}\n' "$2" > "$OPS_SRC/patches/$1/meta.json"
  printf 'x\n' > "$OPS_SRC/patches/$1/pr.md"
  g -C "$OPS_SRC" add -A
  g -C "$OPS_SRC" commit -qm "$1"
}
add_entry 20261015-1 extractor
FRESH=$(g -C "$OPS_SRC" rev-parse HEAD)
add_entry 20261015-2 renderer
add_entry 20261015-3 extractor
printf 'y\n' > "$OPS_SRC/patches/20261015-3/pr.md"
g -C "$OPS_SRC" commit -qam "edit 20261015-3"
OLD_DATE="$(( $(date +%s) - 10 * 86400 )) +0000"
mkdir -p "$OPS_SRC/patches/20261001-1"
printf '{"repo":"extractor"}\n' > "$OPS_SRC/patches/20261001-1/meta.json"
g -C "$OPS_SRC" add -A
GIT_COMMITTER_DATE="$OLD_DATE" g -C "$OPS_SRC" commit -qm old
mkdir -p "$OPS_SRC/patches/20261015-7"
printf '{"repo":"extractor"}\n' > "$OPS_SRC/patches/20261015-7/meta.json"
g -C "$OPS_SRC" add -A
GIT_COMMITTER_DATE="$(( $(date +%s) + 10 * 86400 )) +0000" g -C "$OPS_SRC" commit -qm future
add_entry 20261015-4 extractor
add_entry 20261015-5 extractor
add_entry bad.id extractor
ln -s 20261015-1 "$OPS_SRC/patches/20261015-6"
g -C "$OPS_SRC" add -A
g -C "$OPS_SRC" commit -qm link
OPS_BARE="$WORKDIR/ops.git"
g clone -q --bare "$OPS_SRC" "$OPS_BARE"
OPS="$WORKDIR/ops"
"$FETCH" --url "$OPS_BARE" --branch main --dest "$OPS" >/dev/null 2>&1

# 이 repo: origin 에 autofix/20261015-4 가 이미 있음. 20261015-5 는 PR 이 있음(가짜 gh).
ORIGIN="$WORKDIR/origin.git"
REPO="$WORKDIR/repo"
g init -q --bare "$ORIGIN"
g clone -q "$ORIGIN" "$REPO" 2>/dev/null
g -C "$REPO" commit -q --allow-empty -m init
g -C "$REPO" push -q origin HEAD:refs/heads/main HEAD:refs/heads/autofix/20261015-4

FAKE="$WORKDIR/fake"
mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
all="$*"
case "$all" in
  *"/pulls?state=all&head=o:autofix/20261015-5&"*) echo 1;;
  *"/pulls?state=all&head=o:autofix/"*) echo 0;;
  *) echo "unexpected gh call: $all" >&2; exit 1;;
esac
EOF
chmod +x "$FAKE/gh"

run() {
  (cd "$REPO" && PATH="$FAKE:$PATH" GITHUB_REPOSITORY=o/extractor GH_TOKEN=x "$SCAN" "$@")
}

# 1. 인자 오류
run --ops "$WORKDIR/none" >/dev/null 2>&1
check "ops 클론 아님 -> exit 2" 2 "$?"
run --ops "$OPS" --window-days x >/dev/null 2>&1
check "기간이 숫자 아님 -> exit 2" 2 "$?"

# 2. 찾기
OUT=$(run --ops "$OPS" 2>"$WORKDIR/err")
check "exit 0" 0 "$?"
check "새 항목 하나와 만든 커밋" "20261015-1 $FRESH" "$OUT"
check "만든 뒤 고친 항목은 경고" yes "$(grep -q '20261015-3: changed after creation' "$WORKDIR/err" && echo yes || echo no)"
check "미래 날짜 항목은 경고" yes "$(grep -q '20261015-7: committed in the future' "$WORKDIR/err" && echo yes || echo no)"
OUT=$(run --ops "$OPS" --window-days 30 2>/dev/null)
check "기간을 늘리면 오래된 항목도 찾음" "20261001-1 20261015-1" "$(cut -d' ' -f1 <<<"$OUT" | sort | tr '\n' ' ' | sed 's/ $//')"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "all passed"
