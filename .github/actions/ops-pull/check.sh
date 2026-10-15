#!/usr/bin/env bash
#
# ops patches 항목 하나를 PR 로 열어도 되는지 판정한다. 사용법은 action.yml.
# 현재 디렉토리는 그 항목의 patch.diff 를 git apply --index 로 적용한 checkout 이어야 한다.
# 패치 글자가 아니라 git 이 실제로 바꾼 경로·모드로 판정한다. 이스케이프 경로·옛 diff 형식·모드 표기의 해석 차이를 정규식이 따라가지 못한다.
#
# 인자:
#   <entry>       (필수) patches 항목 디렉토리. meta.json·patch.diff·pr.md 를 담는다
#   --leak-guard  PR 본문과 추가 줄에 URL·금지어가 있으면 거부한다. 공개 repo 용
# 환경 변수:
#   DENY_PATTERN  --leak-guard 면 필수. 금지어 확장 정규식(대소문자 무시). 단어 목록이 공개 코드에 남지 않게 시크릿으로 받는다
#
# 종료 코드: 통과 0, 거부 1(stdout 에 사유 하나), 인자·실행 오류 2.
# 공개 repo 의 Actions 로그에 실리므로 사유에 패치 내용을 넣지 않는다.

set -euo pipefail

ENTRY=""
LEAK_GUARD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --leak-guard) LEAK_GUARD=1; shift;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) ENTRY="$1"; shift;;
  esac
done

[ -n "$ENTRY" ] || { echo "entry is required" >&2; exit 2; }
if [ -n "$LEAK_GUARD" ] && [ -z "${DENY_PATTERN:-}" ]; then
  echo "DENY_PATTERN is required with --leak-guard" >&2
  exit 2
fi

reject() { echo "$1"; exit 1; }

for f in meta.json patch.diff pr.md; do
  if [ ! -f "$ENTRY/$f" ] || [ -L "$ENTRY/$f" ]; then
    reject "missing $f"
  fi
done
[ -n "$(head -n 1 "$ENTRY/pr.md" | tr -d '[:space:]')" ] || reject "empty title"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
# quotePath 를 끄지 않으면 한글 경로가 8진 이스케이프로 찍혀 금지어 검사를 빠져나간다.
# attr.tree 를 빈 트리로 두어 작업 트리의 .gitattributes 가 바이너리 판정(diff·binary 속성)을 바꾸지 못하게 한다.
DIFF=(git -c core.quotePath=false -c attr.tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904
  diff --cached --no-renames --no-ext-diff --no-textconv --no-color)
MAX_FILES=20
MAX_LINES=800

status=0
"${DIFF[@]}" --quiet || status=$?
case "$status" in
  0) reject "empty patch";;
  1) ;;
  *) echo "git diff failed" >&2; exit 2;;
esac

# --raw -z 레코드: ":<옛 모드> <새 모드> <옛 sha> <새 sha> <상태>" NUL "<경로>" NUL
"${DIFF[@]}" --raw -z > "$TMP"
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  case "$path" in .github|.github/*) reject "touches .github";; esac
  # 속성 파일은 리뷰 화면에서 diff 를 접게(linguist-generated) 하거나 필터·서브모듈을 끌어들인다.
  case "/$path" in */.gitattributes|*/.lfsconfig|*/.gitmodules) reject "touches git config file";; esac
  read -r old_mode new_mode _ <<<"${meta#:}"
  case " $old_mode $new_mode " in *" 120000 "*|*" 160000 "*) reject "symlink or submodule";; esac
done < "$TMP"

# 큰 diff 는 GitHub 이 리뷰 화면에서 접어 사람의 확인을 비켜 간다. 루틴의 패치는 작은 것만 받는다.
"${DIFF[@]}" --numstat -z > "$TMP"
FILES=0
LINES=0
while IFS= read -r -d '' rec; do
  case "$rec" in -$'\t'-$'\t'*) reject "binary patch";; esac
  IFS=$'\t' read -r added deleted _ <<<"$rec"
  FILES=$((FILES + 1))
  LINES=$((LINES + added + deleted))
done < "$TMP"
if [ "$FILES" -gt "$MAX_FILES" ] || [ "$LINES" -gt "$MAX_LINES" ]; then
  reject "too large"
fi

[ -n "$LEAK_GUARD" ] || exit 0

# 지우는 줄·문맥 줄은 이미 공개된 내용이라 새로 드러나는 것(본문·추가 줄·경로)만 본다.
"${DIFF[@]}" --text -U0 > "$TMP"
TEXT=$(cat "$ENTRY/pr.md"; LC_ALL=C grep -aE '^(\+|diff --git )' "$TMP" || true)

# extractor 로그의 url 필드는 scheme 없이 host/path 로 찍혀 scheme 없는 형태도 잡는다.
# 뒤에 경로·쿼리·조각이 없는 도메인 단독은 사용자 데이터가 아니고 파일명(Foo.java)과 구분되지 않아 보지 않는다.
HOSTS=$(LC_ALL=C grep -oaiE '[a-z][a-z0-9+.-]*://[^/?#[:space:]"'\''<>)]*|([a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}|([0-9]{1,3}\.){3}[0-9]{1,3})(:[0-9]+)?[/?#]' <<<"$TEXT" || true)
while IFS= read -r h; do
  [ -n "$h" ] || continue
  h=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$h")
  h=${h#*://}
  h=${h%[/?#]}
  case "$h" in *@*) reject "url";; esac
  h=${h%%:*}
  if ! [[ "$h" =~ ^(.+\.)?example\.(com|org|net)$ || "$h" = localhost ]]; then
    reject "url"
  fi
done <<<"$HOSTS"

status=0
LC_ALL=C grep -qaiE -- "$DENY_PATTERN" <<<"$TEXT" || status=$?
case "$status" in
  0) reject "deny word";;
  1) ;;
  *) echo "invalid DENY_PATTERN" >&2; exit 2;;
esac

exit 0
