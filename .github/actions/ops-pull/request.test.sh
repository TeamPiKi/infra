#!/usr/bin/env bash
#
# .github/actions/ops-pull/request.sh 셀프 테스트. gh 는 PATH 앞의 가짜로 대신한다.
#
# 실행: ./.github/actions/ops-pull/request.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUEST="$SCRIPT_DIR/request.sh"

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

FAKE="$WORKDIR/fake"
mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
for a in "$@"; do
  case "$a" in body=@*) cp "${a#body=@}" "$FAKE_BODY";; esac
done
[ -z "$FAKE_FAIL" ] || exit 1
echo 42
EOF
chmod +x "$FAKE/gh"

SHA=0123456789abcdef0123456789abcdef01234567
run() {
  PATH="$FAKE:$PATH" GITHUB_REPOSITORY=o/extractor GH_TOKEN=x FAKE_GH_LOG="$WORKDIR/gh.log" \
    FAKE_BODY="$WORKDIR/body.md" FAKE_FAIL="${FAIL:-}" "$REQUEST" "$@" 2>/dev/null
}

# 1. 인자 오류
run --id 2026 --commit "$SHA" --ops-repo O/ops >/dev/null
check "id 형식 오류 -> exit 2" 2 "$?"
run --id 20261015-1 --commit abc --ops-repo O/ops >/dev/null
check "짧은 sha -> exit 2" 2 "$?"
run --id 20261015-1 --commit "$SHA" --ops-repo 'O/ops x' >/dev/null
check "ops repo 형식 오류 -> exit 2" 2 "$?"

# 2. 이슈 생성
OUT=$(run --id 20261015-1 --commit "$SHA" --ops-repo O/ops)
check "exit 0 과 이슈 번호" "0 42" "$? $OUT"
check "제목" yes "$(grep -q '^api repos/o/extractor/issues -f title=ops 패치 20261015-1 승인 -F body=@' "$WORKDIR/gh.log" && echo yes || echo no)"
check "첫 줄은 판정용 표식" "<!-- ops-approval id=20261015-1 commit=$SHA -->" "$(head -n 1 "$WORKDIR/body.md")"
check "pr.md 는 그 커밋의 원문 링크" yes "$(grep -qF "(https://github.com/O/ops/blob/$SHA/patches/20261015-1/pr.md?plain=1)" "$WORKDIR/body.md" && echo yes || echo no)"
check "패치는 그 커밋의 링크" yes "$(grep -qF "(https://github.com/O/ops/blob/$SHA/patches/20261015-1/patch.diff)" "$WORKDIR/body.md" && echo yes || echo no)"
check "체크박스는 체크 안 된 상태" "- [ ] 승인" "$(tail -n 1 "$WORKDIR/body.md")"

# 3. 실패
FAIL=1 run --id 20261015-1 --commit "$SHA" --ops-repo O/ops >/dev/null
check "이슈 생성 실패 -> exit 1" 1 "$?"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "all passed"
