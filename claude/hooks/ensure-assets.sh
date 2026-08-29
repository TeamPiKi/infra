#!/bin/bash
# 공통 자산 자가치유 — 세션 도중 옮긴 워크트리·다른 소비 repo 에 install.sh 산출물을 채운다.
#
# 왜 필요한가: SessionStart 부트스트랩은 **세션 시작 시점의 repo 한 곳**에만 자산을 깐다
# (install.sh 가 repo_root 를 그때의 `git rev-parse --show-toplevel` 로 잡는다). 그래서
# EnterWorktree 로 워크트리를 옮기거나, core 세션에서 extractor·renderer 를 만지면 그곳엔
# 스킬(.claude/commands)·규약(.claude/rules)·계약 카탈로그(shared-infra/contracts)가 없다.
# 워크트리가 특히 잘 걸린다: `git worktree add` 는 git 이 추적하는 파일만 체크아웃하는데
# 이 자산들은 gitignore 대상이라 따라오지 않는다.
#
# 그 상태로 테스트를 돌리면 카탈로그를 읽는 메타 테스트가 깨지는데, 증상이 코드 문제처럼 보여
# 오진하기 쉽다 (TeamPiKi/core#950 작업 중 실제로 겪었다). 그 테스트는 파일이 없으면 skip 하지
# 않고 일부러 실패시키므로 — 없다고 넘어가면 계약 강제가 조용히 사라진다 — 계속 같은 자리에서 걸린다.
#
# 왜 매 프롬프트가 아닌가: 평소 비용을 0 으로 두려고 **문제가 드러나는 두 순간에만** 건다.
#   PostToolUse EnterWorktree      — 폴더가 바뀌는 그 순간이 곧 자산이 없어지는 순간이다.
#   PreToolUse Bash(gradlew 포함)  — 위를 안 거치고 들어온 경우(수동 cd·resume 등)의 안전망.
#
# 실패 안전: 어떤 이유로든 exit 0 한다. 자산을 못 깔아도 사용자의 명령을 막지 않는다.

set -u

payload=$(cat 2>/dev/null || true)

# ---- B 트리거의 조기 종료: 프로세스를 하나도 안 띄우고 거른다 ----
# PreToolUse 는 툴 이름(Bash)으로만 매칭되므로 ls·git status 같은 잦은 호출에도 전부 붙는다.
# 그 대다수를 여기서 bash 내장 패턴 매칭만으로 끊는다 (jq 를 부르면 그것만으로 약 5ms 를 쓴다).
# payload 전체를 문자열로 보는 게 정밀도는 낮지만, 여기서 통과해도 아래 sentinel 검사가 다시
# 거르므로 과통과의 대가는 몇 ms 뿐이다. 반대로 과차단은 없다: 명령에 gradlew 가 있으면 반드시 남는다.
case "$payload" in
  *'"hook_event_name":"PreToolUse"'*)
    case "$payload" in
      *gradlew*) : ;;
      *) exit 0 ;;
    esac
    ;;
esac

# ---- 작업 위치를 얻는다 ----
# 훅 입력(JSON)의 cwd 를 쓰고, 없으면 프로세스 cwd 로 물러선다. jq 가 없는 환경도 마찬가지다.
cwd=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd="$PWD"
[ -d "$cwd" ] || exit 0

# ---- repo 루트를 프로세스 없이 찾는다 ----
# `git rev-parse` 를 부르면 프로세스가 하나 더 떠 약 8ms 를 쓴다(실측). 상위로 올라가며 .git 을
# 찾는 것으로 충분하다 — 워크트리의 .git 은 디렉터리가 아니라 파일이라 -e 로 본다.
root="$cwd"
while [ "$root" != "/" ]; do
  [ -e "$root/.git" ] && break
  root=$(dirname "$root")
done
[ "$root" != "/" ] || exit 0

# ---- 이미 다 깔려 있으면 여기서 끝 (정상 경로) ----
# 자산 하나만 보면 **부분 손상**을 놓친다. 실제로 스킬은 있는데 카탈로그만 없는 워크트리가 있었다
# (카탈로그 설치가 나중에 추가돼, 그 전에 자산을 받은 위치는 스킬만 가진 채 남는다). 그래서
# 종류별로 하나씩 본다 — 파일 존재 검사라 몇 개를 보든 사실상 공짜다.
#
# 매니페스트는 sentinel 로 쓸 수 없다: --git-common-dir 기준이라 워크트리 전체가 공유하고,
# 마지막에 실행한 쪽 경로로 덮여 "이 위치에 깔렸는가" 를 답하지 못한다.
#
# 소비 repo 판별은 CLAUDE.md 존재로 근사한다. install.sh 가 규약·카탈로그를 infra 자신에서 제외하는
# 근거가 바로 "import 할 CLAUDE.md 가 없다" 이므로 같은 기준이고, origin 을 묻지 않아 프로세스도 안 뜬다.
need=0
[ -f "$root/.claude/commands/pr.md" ] || need=1
if [ -f "$root/CLAUDE.md" ]; then
  [ -f "$root/.claude/rules/testing-principles.md" ] || need=1
  [ -f "$root/shared-infra/contracts/extraction-error-codes.yaml" ] || need=1
fi
[ "$need" = 0 ] && exit 0

# ---- 여기부터는 자산이 없을 때만 돈다 (드물다) ----
# 남의 repo 는 건드리지 않는다. origin 이 TeamPiKi 인 것만 대상으로 한다.
origin=$(git -C "$root" remote get-url origin 2>/dev/null || true)
case "$origin" in
  *TeamPiKi/*) : ;;
  *) exit 0 ;;
esac

# install.sh 정본을 받아 이 위치에 설치한다. 실패(오프라인·권한 없음·빈 응답·문법 깨짐)면 조용히 넘어간다.
# infra 자신에서 돌면 원격 정본을 받으므로 working tree 의 수정 중인 자산은 반영되지 않는다
# (install.sh 의 self 모드와 다른 점). 다만 infra 에도 스킬이 깔려 sentinel 이 있으므로
# 여기까지 오는 일 자체가 드물다.
tmp=$(mktemp) || exit 0
if gh api -H "Accept: application/vnd.github.raw" repos/TeamPiKi/infra/contents/install.sh >"$tmp" 2>/dev/null &&
  [ -s "$tmp" ] && bash -n "$tmp" 2>/dev/null; then
  (cd "$root" && bash "$tmp") >/dev/null 2>&1
  echo "[piki] 공통 자산을 $root 에 설치했다 (세션 시작 이후 옮긴 위치라 비어 있었다)." >&2
fi
rm -f "$tmp"
exit 0
