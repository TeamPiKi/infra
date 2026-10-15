#!/usr/bin/env bash
#
# .github/actions/ops-pull/check.sh 셀프 테스트. 시험 repo 에 패치를 git apply --index 로 적용한 뒤 판정을 본다.
#
# 실행: ./.github/actions/ops-pull/check.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check.sh"

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

# 개발자 PC 의 전역 훅·서명 설정이 시험 repo 에 끼어들지 않게 한다.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export DENY_PATTERN='topsecret|금지어'
g() { git -c user.name=t -c user.email=t@example.com "$@"; }

REPO="$WORKDIR/repo"
g init -q "$REPO"
mkdir -p "$REPO/src" "$REPO/.github/actions/a"
printf 'class Foo {\n  int a = 1;\n}\n' > "$REPO/src/Foo.java"
printf 'class Bar {\n  String u = "https://shop.co.kr/";\n}\n' > "$REPO/src/Bar.java"
printf 'name: a\n' > "$REPO/.github/actions/a/action.yml"
printf 'on: push\n' > "$REPO/ci.yml"
# 이 repo 자신의 속성 파일이 바이너리 판정을 바꾸지 못하는지 본다.
printf '*.bin diff\n' > "$REPO/.gitattributes"
g -C "$REPO" add -A
g -C "$REPO" commit -qm base
g -C "$REPO" tag base

PR_OK='Foo 값 변경

- 본문'

# verdict <patch 파일> <pr.md> [check.sh 인자...] -> "apply-failed" 또는 "<종료 코드>:<stdout>"
verdict() {
  local patch="$1" pr="$2" d
  shift 2
  d=$(mktemp -d "$WORKDIR/e.XXXXXX")
  printf '%s\n' '{"repo":"extractor"}' > "$d/meta.json"
  cp "$patch" "$d/patch.diff"
  printf '%s\n' "$pr" > "$d/pr.md"
  g -C "$REPO" reset -q --hard base
  g -C "$REPO" clean -qfdx
  if ! (cd "$REPO" && git apply --index "$d/patch.diff" 2>/dev/null); then
    echo apply-failed
    return
  fi
  local out code
  out=$(cd "$REPO" && "$CHECK" "$d" "$@" 2>/dev/null)
  code=$?
  echo "$code:$out"
}

P="$WORKDIR/p"
mkdir -p "$P"
patch_file() { printf '%s\n' "$2" > "$P/$1"; echo "$P/$1"; }
diff_of() {
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,3 +1,3 @@\n %s\n-%s\n+%s\n }' "$1" "$1" "$1" "$1" "$2" "$3" "$4"
}
foo_change() { patch_file "$1" "$(diff_of src/Foo.java 'class Foo {' '  int a = 1;' "$2")"; }

CLEAN=$(foo_change clean '  int a = 2;')

# 1. 인자·형식
OUT=$("$CHECK" 2>/dev/null); check "entry 없음 -> exit 2" 2 "$?"
OUT=$(DENY_PATTERN='' "$CHECK" "$WORKDIR" --leak-guard 2>/dev/null); check "leak-guard 에 금지어 없음 -> exit 2" 2 "$?"
check "깨끗한 패치" "0:" "$(verdict "$CLEAN" "$PR_OK")"
check "깨끗한 패치 leak-guard" "0:" "$(verdict "$CLEAN" "$PR_OK" --leak-guard)"
check "제목 빈 줄" "1:empty title" "$(verdict "$CLEAN" $'\n\n- 본문')"
D="$WORKDIR/nopr"; mkdir -p "$D"; printf '{}\n' > "$D/meta.json"; cp "$CLEAN" "$D/patch.diff"; ln -s "$REPO/.git/config" "$D/pr.md"
g -C "$REPO" reset -q --hard base
OUT=$(cd "$REPO" && git apply --index "$CLEAN" && "$CHECK" "$D" 2>/dev/null); check "심볼릭 링크 pr.md" "missing pr.md" "$OUT"
D="$WORKDIR/extra"; mkdir -p "$D"; printf '{}\n' > "$D/meta.json"; cp "$CLEAN" "$D/patch.diff"; printf '%s\n' "$PR_OK" > "$D/pr.md"; printf 'x\n' > "$D/README.md"
g -C "$REPO" reset -q --hard base
OUT=$(cd "$REPO" && git apply --index "$CLEAN" && "$CHECK" "$D" 2>/dev/null); check "항목에 다른 파일" "unexpected file in entry" "$OUT"
check "pr.md 의 HTML 주석" "1:html in pr.md" "$(verdict "$CLEAN" $'Foo 값 변경\n\n- 본문\n<!-- 숨긴 글 -->')"
check "pr.md 의 details" "1:html in pr.md" "$(verdict "$CLEAN" $'Foo 값 변경\n\n<details><summary>x</summary>숨김</details>')"
check "코드 안의 꺾쇠는 허용" "0:" "$(verdict "$CLEAN" $'Foo 값 변경\n\n- `Optional<Product>` 반환\n\n```java\nList<String> a = new ArrayList<>();\n```')"
D="$WORKDIR/noop"; mkdir -p "$D"; printf '{}\n' > "$D/meta.json"; cp "$CLEAN" "$D/patch.diff"; printf '%s\n' "$PR_OK" > "$D/pr.md"
g -C "$REPO" reset -q --hard base
OUT=$(cd "$REPO" && "$CHECK" "$D" 2>/dev/null); check "바뀐 것 없음" "empty patch" "$OUT"

# 2. .github
check ".github/workflows 새 파일" "1:touches .github" "$(verdict "$(patch_file gh1 'diff --git a/.github/workflows/x.yml b/.github/workflows/x.yml
new file mode 100644
--- /dev/null
+++ b/.github/workflows/x.yml
@@ -0,0 +1 @@
+name: x')" "$PR_OK")"
check ".github/actions 수정" "1:touches .github" "$(verdict "$(patch_file gh2 'diff --git a/.github/actions/a/action.yml b/.github/actions/a/action.yml
--- a/.github/actions/a/action.yml
+++ b/.github/actions/a/action.yml
@@ -1 +1 @@
-name: a
+name: b')" "$PR_OK")"
check ".github 로 rename" "1:touches .github" "$(verdict "$(patch_file gh3 'diff --git a/ci.yml b/.github/workflows/ci.yml
similarity index 100%
rename from ci.yml
rename to .github/workflows/ci.yml')" "$PR_OK")"
check "8진 이스케이프 경로" "1:touches .github" "$(verdict "$(patch_file gh4 'diff --git "a/\056github/workflows/x.yml" "b/\056github/workflows/x.yml"
new file mode 100644
--- /dev/null
+++ "b/\056github/workflows/x.yml"
@@ -0,0 +1 @@
+name: x')" "$PR_OK")"
check "옛 diff 형식" "1:touches .github" "$(verdict "$(patch_file gh5 '--- /dev/null
+++ b/.github/workflows/x.yml
@@ -0,0 +1 @@
+name: x')" "$PR_OK")"
MANY="$P/gh6"
{ printf 'diff --git a/.github/workflows/x.yml b/.github/workflows/x.yml\nnew file mode 100644\n--- /dev/null\n+++ b/.github/workflows/x.yml\n@@ -0,0 +1 @@\n+name: x\n'
  for i in $(seq 1 3000); do printf 'diff --git a/f%s b/f%s\nnew file mode 100644\n--- /dev/null\n+++ b/f%s\n@@ -0,0 +1 @@\n+x\n' "$i" "$i" "$i"; done; } > "$MANY"
check "뒤에 파일 3000개" "1:touches .github" "$(verdict "$MANY" "$PR_OK")"
NUL="$P/gh7"
{ printf 'junk\0\n'; cat "$P/gh1"; } > "$NUL"
case "$(verdict "$NUL" "$PR_OK")" in apply-failed|"1:touches .github") R=blocked;; *) R=passed;; esac
check "NUL 바이트 잡음 줄" blocked "$R"

# 3. 모드·바이너리
check "심볼릭 링크" "1:symlink or submodule" "$(verdict "$(patch_file m1 'diff --git a/src/l b/src/l
new file mode 120000
--- /dev/null
+++ b/src/l
@@ -0,0 +1 @@
+../ci.yml
\ No newline at end of file')" "$PR_OK")"
case "$(verdict "$(patch_file m2 'diff --git a/src/l b/src/l
new file mode 0120000
--- /dev/null
+++ b/src/l
@@ -0,0 +1 @@
+../ci.yml
\ No newline at end of file')" "$PR_OK")" in apply-failed|"1:symlink or submodule") R=blocked;; *) R=passed;; esac
check "모드 앞 0" blocked "$R"
BIN="$WORKDIR/bin"
g clone -q "$REPO" "$BIN"
printf 'a\0b' > "$BIN/blob.dat"
g -C "$BIN" add blob.dat
g -C "$BIN" diff --cached --binary > "$P/b1"
check "바이너리" "1:binary patch" "$(verdict "$P/b1" "$PR_OK")"
g -C "$BIN" reset -q --hard
printf 'a\0b' > "$BIN/blob.bin"
g -C "$BIN" add blob.bin
g -C "$BIN" -c attr.tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904 diff --cached --binary > "$P/b2"
check "repo 속성이 diff 라고 해도 바이너리" "1:binary patch" "$(verdict "$P/b2" "$PR_OK")"

# 4. 속성 파일·크기
check ".gitattributes 추가" "1:touches git config file" "$(verdict "$(patch_file a1 'diff --git a/.gitattributes b/.gitattributes
--- a/.gitattributes
+++ b/.gitattributes
@@ -1 +1,2 @@
 *.bin diff
+src/Foo.java linguist-generated=true')" "$PR_OK")"
check "하위 폴더 .gitmodules" "1:touches git config file" "$(verdict "$(patch_file a2 'diff --git a/src/.gitmodules b/src/.gitmodules
new file mode 100644
--- /dev/null
+++ b/src/.gitmodules
@@ -0,0 +1 @@
+x')" "$PR_OK")"
check ".lfsconfig" "1:touches git config file" "$(verdict "$(patch_file a3 'diff --git a/.lfsconfig b/.lfsconfig
new file mode 100644
--- /dev/null
+++ b/.lfsconfig
@@ -0,0 +1 @@
+x')" "$PR_OK")"
g -C "$BIN" reset -q --hard
printf '*.dat diff\n' > "$BIN/.gitattributes"
printf 'a\0b\n' > "$BIN/evil.dat"
g -C "$BIN" add .gitattributes evil.dat
g -C "$BIN" diff --cached --binary > "$P/a4"
case "$(verdict "$P/a4" "$PR_OK")" in apply-failed|"1:touches git config file") R=blocked;; *) R=passed;; esac
check "속성으로 바이너리를 글자로 위장" blocked "$R"
{ for i in $(seq 1 21); do printf 'diff --git a/src/f%s b/src/f%s\nnew file mode 100644\n--- /dev/null\n+++ b/src/f%s\n@@ -0,0 +1 @@\n+x\n' "$i" "$i" "$i"; done; } > "$P/big1"
check "파일 21개" "1:too large" "$(verdict "$P/big1" "$PR_OK")"
{ printf 'diff --git a/src/big b/src/big\nnew file mode 100644\n--- /dev/null\n+++ b/src/big\n@@ -0,0 +1,801 @@\n'; for i in $(seq 1 801); do printf '+%s\n' "$i"; done; } > "$P/big2"
check "줄 801개" "1:too large" "$(verdict "$P/big2" "$PR_OK")"

# 5. URL (leak-guard)
URL_PR=$'Foo 값 변경\n\n- 실패 URL https://Naver.ME/abc 재현'
check "본문 URL" "1:url" "$(verdict "$CLEAN" "$URL_PR" --leak-guard)"
check "본문 URL leak-guard 끔" "0:" "$(verdict "$CLEAN" "$URL_PR")"
check "추가 줄 URL" "1:url" "$(verdict "$(foo_change u1 '  String u = "http://shop.co.kr/p/1";')" "$PR_OK" --leak-guard)"
check "scheme 없는 host/path" "1:url" "$(verdict "$(foo_change u2 '  String u = "oy.run/x1";')" "$PR_OK" --leak-guard)"
check "대문자·포트" "1:url" "$(verdict "$(foo_change u3 '  String u = "HTTPS://Naver.ME:443/x";')" "$PR_OK" --leak-guard)"
check "userinfo 로 예시 도메인 위장" "1:url" "$(verdict "$(foo_change u4 '  String u = "https://shop.co.kr@example.com/";')" "$PR_OK" --leak-guard)"
check "IP 와 경로" "1:url" "$(verdict "$(foo_change u5 '  String u = "13.125.1.2/goods/1";')" "$PR_OK" --leak-guard)"
check "변형 scheme" "1:url" "$(verdict "$(foo_change u6 '  String u = "hxxp://naver.me/abc";')" "$PR_OK" --leak-guard)"
check "UTF-8 이 아닌 바이트가 섞인 줄" "1:url" "$(verdict "$(foo_change u7 $'  String u = "\xff https://naver.me/abc";')" "$PR_OK" --leak-guard)"
check "도메인 모양 경로의 새 파일" "1:url" "$(verdict "$(patch_file u8 'diff --git a/src/naver.me/x.html b/src/naver.me/x.html
new file mode 100644
--- /dev/null
+++ b/src/naver.me/x.html
@@ -0,0 +1 @@
+<html></html>')" "$PR_OK" --leak-guard)"
check "도메인과 포트·경로" "1:url" "$(verdict "$(foo_change u11 '  String u = "shop.co.kr:443/goods/1";')" "$PR_OK" --leak-guard)"
check "도메인과 쿼리" "1:url" "$(verdict "$(foo_change u12 '  String u = "shop.co.kr?goods=12345";')" "$PR_OK" --leak-guard)"
check "IP 와 포트·쿼리" "1:url" "$(verdict "$(foo_change u13 '  String u = "13.125.1.2:8080?q=1";')" "$PR_OK" --leak-guard)"
check "추가 줄 이메일" "1:email" "$(verdict "$(foo_change u14 '  // reporter kim.lee@gmail.com')" "$PR_OK" --leak-guard)"
check "이메일 leak-guard 끔" "0:" "$(verdict "$(foo_change u15 '  // reporter kim.lee@gmail.com')" "$PR_OK")"
check "자바 어노테이션은 이메일 아님" "0:" "$(verdict "$(foo_change u16 '  @Override public String a() { return null; }')" "$PR_OK" --leak-guard)"
check "파일명·줄 번호는 URL 아님" "0:" "$(verdict "$CLEAN" $'Foo 값 변경\n\n- 근거 src/Foo.java:2 와 Bar.java' --leak-guard)"
check "지우는 줄·문맥 줄의 URL" "0:" "$(verdict "$(patch_file u9 "$(diff_of src/Bar.java 'class Bar {' '  String u = "https://shop.co.kr/";' '  String u = null;')")" "$PR_OK" --leak-guard)"
check "예시 도메인·localhost 허용" "0:" "$(verdict "$(foo_change u10 '  String u = "https://shop.example.com/p http://localhost:8080/x";')" "$PR_OK" --leak-guard)"
OUT=$(verdict "$CLEAN" "$URL_PR" --leak-guard)
case "$OUT" in *[Nn]aver*) R=leaked;; *) R=no-leak;; esac
check "거부 사유에 URL 없음" no-leak "$R"

# 6. 금지어 (leak-guard)
check "추가 줄 금지어(대소문자 무시)" "1:deny word" "$(verdict "$(foo_change d1 '  // TopSecret path')" "$PR_OK" --leak-guard)"
check "본문 한글 금지어" "1:deny word" "$(verdict "$CLEAN" $'Foo 값 변경\n\n- 금지어 포함' --leak-guard)"
check "한글 경로의 금지어" "1:deny word" "$(verdict "$(patch_file d3 'diff --git a/src/금지어/a.txt b/src/금지어/a.txt
new file mode 100644
--- /dev/null
+++ b/src/금지어/a.txt
@@ -0,0 +1 @@
+x')" "$PR_OK" --leak-guard)"
check "leak-guard 끔이면 금지어 안 봄" "0:" "$(verdict "$(foo_change d2 '  // topsecret')" "$PR_OK")"
R=$(DENY_PATTERN='(' verdict "$CLEAN" "$PR_OK" --leak-guard)
check "잘못된 금지어 정규식 -> exit 2" "2:" "$R"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "all passed"
