#!/usr/bin/env bash
#
# .github/actions/ops-pull/open.sh 셀프 테스트. origin 은 로컬 bare repo, gh·sleep 은 PATH 앞의 가짜로 대신한다.
#
# 실행: ./.github/actions/ops-pull/open.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPEN="$SCRIPT_DIR/open.sh"

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

# 개발자 PC 의 전역 훅·서명 설정이 시험 repo 커밋에 끼어들지 않게 한다.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=t -c user.email=t@example.com "$@"; }

ORIGIN="$WORKDIR/origin.git"
SEED="$WORKDIR/seed"
REPO="$WORKDIR/repo"
g init -q --bare "$ORIGIN"
g init -q "$SEED"
printf 'class Foo {\n  int a = 1;\n}\n' > "$SEED/Foo.java"
g -C "$SEED" add Foo.java
g -C "$SEED" commit -qm init
g -C "$SEED" push -q "$ORIGIN" HEAD:refs/heads/main
g clone -q -b main "$ORIGIN" "$REPO"
MAIN_SHA=$(g -C "$ORIGIN" rev-parse main)

# 승인 대기 실행 목록은 push 된 커밋을 따라 만든다. 201 은 다른 커밋, 202 는 fork, 203 은 다른 이벤트.
FAKE="$WORKDIR/fake"
mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
for a in "$@"; do
  case "$a" in body=@*) cp "${a#body=@}" "$FAKE_BODY";; esac
done
all="$*"
case "$all" in
  "api repos/o/extractor --jq .private") echo "$FAKE_PRIVATE";;
  *"/pulls?state=all&head=o:autofix/"*)
    b="${all#*head=o:autofix/}"; b="${b%%&*}"
    case " $FAKE_EXISTING " in *" $b "*) echo 1;; *) echo 0;; esac;;
  "api repos/o/extractor/pulls "*) echo 7;;
  *"status=action_required"*)
    if [ -n "$FAKE_NO_RUNS" ]; then echo '{"workflow_runs":[]}'; exit 0; fi
    b="${all#*branch=}"; b="${b%%&*}"
    sha=$(git --git-dir="$FAKE_ORIGIN" rev-parse "refs/heads/$b")
    cat <<JSON
{"workflow_runs":[
 {"id":101,"head_sha":"$sha","event":"pull_request","head_repository":{"full_name":"o/extractor"}},
 {"id":102,"head_sha":"$sha","event":"pull_request","head_repository":{"full_name":"o/extractor"}},
 {"id":201,"head_sha":"0000000","event":"pull_request","head_repository":{"full_name":"o/extractor"}},
 {"id":202,"head_sha":"$sha","event":"pull_request","head_repository":{"full_name":"x/extractor"}},
 {"id":203,"head_sha":"$sha","event":"push","head_repository":{"full_name":"o/extractor"}}]}
JSON
    ;;
  *"/approve") ;;
  *) echo "unexpected gh call: $all" >&2; exit 1;;
esac
EOF
printf '#!/usr/bin/env bash\n' > "$FAKE/sleep"
chmod +x "$FAKE/gh" "$FAKE/sleep"

PATCHES="$WORKDIR/patches"
PATCH_OK='diff --git a/Foo.java b/Foo.java
--- a/Foo.java
+++ b/Foo.java
@@ -1,3 +1,3 @@
 class Foo {
-  int a = 1;
+  int a = 2;
 }'
PATCH_STALE='diff --git a/Foo.java b/Foo.java
--- a/Foo.java
+++ b/Foo.java
@@ -1,3 +1,3 @@
 class Foo {
-  int a = 9;
+  int a = 2;
 }'
PATCH_GH='diff --git a/.github/actions/x/action.yml b/.github/actions/x/action.yml
new file mode 100644
--- /dev/null
+++ b/.github/actions/x/action.yml
@@ -0,0 +1 @@
+name: x'

# entry <id> <repo> <patch> <pr.md>
entry() {
  local d="$PATCHES/$1"
  mkdir -p "$d"
  printf '{"repo":"%s"}\n' "$2" > "$d/meta.json"
  printf '%s\n' "$3" > "$d/patch.diff"
  printf '%s\n' "$4" > "$d/pr.md"
}

PR_MD=$'Foo 값 변경\n\n## 왜\n\n- 본문 줄'
entry 20261015-1 extractor "$PATCH_OK"    "$PR_MD"
entry 20261015-2 renderer  "$PATCH_OK"    $'다른 repo 몫\n\n- 본문'
entry 20261015-3 extractor "$PATCH_OK"    $'이미 연 PR\n\n- 본문'
entry 20261015-4 extractor "$PATCH_GH"    $'액션 추가\n\n- 본문'
entry 20261015-5 extractor "$PATCH_STALE" $'안 맞는 패치\n\n- 본문'
entry 20261015-6 extractor "$PATCH_OK"    $'URL 포함\n\n- https://naver.me/abc'
entry 20261015-7 extractor "$PATCH_OK"    $'CI 없음\n\n- 본문'
entry 20261015-8 extractor "$PATCH_OK"    "$PR_MD"

OUT=""
CODE=0
# run <private 여부> <DENY_PATTERN> <open.sh 인자...>
run() {
  local private="$1" deny="$2"
  shift 2
  OUT=$(cd "$REPO" && PATH="$FAKE:$PATH" GITHUB_REPOSITORY=o/extractor GH_TOKEN=x DENY_PATTERN="$deny" \
    FAKE_PRIVATE="$private" FAKE_GH_LOG="$WORKDIR/gh.log" FAKE_BODY="$WORKDIR/body.md" \
    FAKE_EXISTING="20261015-3" FAKE_ORIGIN="$ORIGIN" FAKE_NO_RUNS="${NO_RUNS:-}" \
    "$OPEN" --patches "$PATCHES" "$@" 2>&1)
  CODE=$?
}
has() { case "$OUT" in *"$1"*) echo yes;; *) echo no;; esac; }

# 1. 인자 오류
run true '' --id 20261015 --mode pr
check "id 형식 오류 -> exit 2" 2 "$CODE"
run true '' --id '20261015-1/../x' --mode pr
check "경로가 섞인 id -> exit 2" 2 "$CODE"
run true '' --id 20261015-1 --mode push
check "모르는 mode -> exit 2" 2 "$CODE"
run false 'x' --id 20261015-1 --mode branch
check "공개 repo 에 branch -> exit 2" 2 "$CODE"
run false '' --id 20261015-1 --mode pr
check "공개 repo 에 금지어 없음 -> exit 2" 2 "$CODE"

# 2. pr: PR 개시와 CI 승인
: > "$WORKDIR/gh.log"
run true '' --id 20261015-1 --mode pr
check "PR 개시 exit 0" 0 "$CODE"
check "PR 개시 로그" yes "$(has '20261015-1: opened #7')"
check "패치 적용" "  int a = 2;" "$(g -C "$ORIGIN" show autofix/20261015-1:Foo.java | sed -n 2p)"
check "커밋 제목은 pr.md 첫 줄" "Foo 값 변경" "$(g -C "$ORIGIN" log -1 --format=%s autofix/20261015-1)"
check "커밋 본문의 마크다운 제목 유지" "## 왜" "$(g -C "$ORIGIN" log -1 --format=%b autofix/20261015-1 | head -n 1)"
check "base 는 main" "$MAIN_SHA" "$(g -C "$ORIGIN" rev-parse autofix/20261015-1~1)"
check "PR 생성 인자(draft 아님)" yes \
  "$(grep -qx 'api repos/o/extractor/pulls -f title=Foo 값 변경 -f head=autofix/20261015-1 -f base=main -F body=@.* --jq .number' "$WORKDIR/gh.log" && echo yes || echo no)"
check "PR 본문은 pr.md 셋째 줄부터" $'## 왜\n\n- 본문 줄' "$(cat "$WORKDIR/body.md")"
check "승인한 실행" "101 102" "$(grep -oE 'runs/[0-9]+/approve' "$WORKDIR/gh.log" | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "승인은 실행마다 1회" 2 "$(grep -c '/approve' "$WORKDIR/gh.log")"
check "checkout 은 base 로 복귀" "$MAIN_SHA" "$(g -C "$REPO" rev-parse HEAD)"
check "작업 트리 깨끗함" "" "$(g -C "$REPO" status --porcelain)"

# 3. branch: 브랜치만 올림
: > "$WORKDIR/gh.log"
run true '' --id 20261015-8 --mode branch
check "branch exit 0" "0 yes" "$CODE $(has '20261015-8: branch pushed')"
check "branch 는 PR 을 만들지 않음" 0 "$(grep -c '^api repos/o/extractor/pulls ' "$WORKDIR/gh.log")"
check "branch 는 CI 를 승인하지 않음" 0 "$(grep -c 'approve' "$WORKDIR/gh.log")"
check "branch 커밋 본문 유지" "## 왜" "$(g -C "$ORIGIN" log -1 --format=%b autofix/20261015-8 | head -n 1)"
run true '' --id 20261015-8 --mode branch
check "이미 올린 브랜치 -> exit 0" "0 yes" "$CODE $(has '20261015-8: branch exists')"

# 4. 올리지 않는 경우
run true '' --id 20261015-3 --mode pr
check "이미 연 PR -> exit 0" "0 yes" "$CODE $(has '20261015-3: PR exists')"
run true '' --id 20261015-2 --mode pr
check "다른 repo 몫 -> exit 1" "1 yes" "$CODE $(has '20261015-2: not for this repository')"
run true '' --id 20261015-9 --mode pr
check "없는 id -> exit 1" "1 yes" "$CODE $(has '20261015-9: not found')"
run true '' --id 20261015-4 --mode branch
check ".github 패치 거부" "1 yes" "$CODE $(has '20261015-4: rejected (touches .github)')"
run true '' --id 20261015-5 --mode branch
check "안 맞는 패치" "1 yes" "$CODE $(has '20261015-5: patch does not apply')"
check "거부 뒤 checkout 은 base 로 복귀" "$MAIN_SHA" "$(g -C "$REPO" rev-parse HEAD)"
NO_RUNS=1 run true '' --id 20261015-7 --mode pr
check "승인한 CI 0건 -> exit 1" "1 yes yes" "$CODE $(has '20261015-7: opened #7') $(has '20261015-7: no CI run approved')"

# 5. 공개 repo 는 URL 검사
run false 'topsecret' --id 20261015-6 --mode pr
check "공개 repo 는 URL 거부" "1 yes" "$CODE $(has '20261015-6: rejected (url)')"
check "로그에 URL 없음" no "$(has 'naver')"

BRANCHES=$(g -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/autofix | tr '\n' ' ')
check "origin 의 autofix 브랜치" "autofix/20261015-1 autofix/20261015-7 autofix/20261015-8 " "$BRANCHES"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "all passed"
