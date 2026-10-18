#!/usr/bin/env bash
#
# .github/actions/ops-pull/gate.sh 셀프 테스트. 이벤트 JSON 을 만들어 넣고, gh 는 PATH 앞의 가짜로 대신한다.
#
# 실행: ./.github/actions/ops-pull/gate.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/gate.sh"

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

# 쓰기 권한: owner 는 admin, dev 는 write, guest 는 read.
FAKE="$WORKDIR/fake"
mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/collaborators/owner/permission"*) echo admin;;
  *"/collaborators/dev/permission"*) echo write;;
  *"/collaborators/guest/permission"*) echo read;;
  *) echo "unexpected gh call: $*" >&2; exit 1;;
esac
EOF
chmod +x "$FAKE/gh"

SHA=0123456789abcdef0123456789abcdef01234567
MARK="<!-- ops-approval id=20261015-1 commit=$SHA -->"
UNCHECKED="$MARK
### ops 패치 \`20261015-1\`
- 커밋 \`$SHA\`

- [ ] 승인"
CHECKED="${UNCHECKED%- \[ \] 승인}- [x] 승인"

# event [jq 로 기본 이벤트를 바꾸는 식]
event() {
  jq -n --arg body "$CHECKED" --arg old "$UNCHECKED" '{
    action: "edited",
    issue: {state: "open", title: "ops 패치 20261015-1 승인", body: $body,
            user: {login: "github-actions[bot]", type: "Bot"}},
    changes: {body: {from: $old}},
    sender: {login: "owner", type: "User"}
  }' | jq "${1:-.}" > "$WORKDIR/event.json"
}

OUT=""
CODE=0
run() {
  OUT=$(PATH="$FAKE:$PATH" GITHUB_EVENT_PATH="$WORKDIR/event.json" GITHUB_REPOSITORY=o/extractor GH_TOKEN=x "$GATE" 2>/dev/null)
  CODE=$?
}

# 1. 승인
event; run
check "admin 이 체크" "0:20261015-1 $SHA" "$CODE:$OUT"
event '.sender.login = "dev"'; run
check "write 권한자가 체크" "0:20261015-1 $SHA" "$CODE:$OUT"
event '.issue.body |= gsub("\n"; "\r\n") | .changes.body.from |= gsub("\n"; "\r\n")'; run
check "웹 편집의 CRLF 본문" "0:20261015-1 $SHA" "$CODE:$OUT"
event '.issue.body |= sub("\\[x\\]"; "[X]")'; run
check "대문자 X" "0:20261015-1 $SHA" "$CODE:$OUT"

# 2. 승인 아님 (조용히 무시)
event '.action = "opened"'; run
check "편집 이벤트 아님" "0:" "$CODE:$OUT"
event '.issue.state = "closed"'; run
check "닫힌 이슈" "0:" "$CODE:$OUT"
event '.issue.user.login = "someone"'; run
check "봇이 만든 이슈 아님" "0:" "$CODE:$OUT"
event '.issue.user.type = "User"'; run
check "봇 이름을 흉내 낸 사용자 이슈" "0:" "$CODE:$OUT"
event '.issue.title = "ops 패치 20261015-1 승인 요청"'; run
check "제목 형식 다름" "0:" "$CODE:$OUT"
event '.issue.title = "ops 패치 20261015-2 승인"'; run
check "제목과 표식의 id 다름" "0:" "$CODE:$OUT"
event '.issue.body |= sub("commit=[0-9a-f]+"; "commit=abc")'; run
check "표식의 sha 가 40자 아님" "0:" "$CODE:$OUT"
event '.issue.body |= ("앞줄\n" + .)'; run
check "표식이 첫 줄 아님" "0:" "$CODE:$OUT"
event '.issue.body = .changes.body.from'; run
check "체크 안 됨" "0:" "$CODE:$OUT"
event '.changes.body.from = .issue.body'; run
check "이미 체크된 이슈의 다른 편집" "0:" "$CODE:$OUT"
event 'del(.changes)'; run
check "본문 변경 아님" "0:" "$CODE:$OUT"

# 3. 권한 없는 체크
event '.sender.login = "guest"'; run
check "read 권한자가 체크 -> exit 1" "1:" "$CODE:$(grep -v '^::warning' <<<"$OUT")"
event '.sender.type = "Bot"'; run
check "봇이 체크 -> exit 1" 1 "$CODE"
event '.sender.login = "owner/../x"'; run
check "이상한 로그인 -> exit 1" 1 "$CODE"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "all passed"
