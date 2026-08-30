#!/usr/bin/env bash
#
# workspace/workspace-init.sh 셀프 테스트
#
# 임시 폴더에서 오프라인 모드(PIKI_INIT_OFFLINE=1)로 부트스트랩을 돌려 산출물을 실측한다.
# 네트워크를 쓰는 두 단계(repo clone, 공통 자산 설치)는 그 모드가 건너뛰므로 CI 에서도 돈다.
#
# 특히 지키려는 것은 **settings.json 이 유효한 JSON 이고 그 안의 셸 조각이 확장되지 않은 채로
# 들어간다**는 것이다. 여기가 깨지면 세션 훅이 조용히 죽어 원인을 찾기 어렵다.
#
# 실행: ./workspace/workspace-init.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="$SCRIPT_DIR/workspace-init.sh"

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# 로그는 부트스트랩 대상 폴더 **밖**에 둔다. 안에 두면 멱등 검사(파일 해시 비교)가 로그 자체의
# 변화를 잡아 늘 실패한다.
LOGS="$WORKDIR/logs"
ROOT="$WORKDIR/root"
mkdir -p "$LOGS" "$ROOT"

# 커밋 단언은 git 사용자 설정을 전제한다. CI 러너엔 없으므로 격리된 설정을 만들어 준다
# (러너·개발자 개인의 전역 설정에도 물들지 않는다).
export GIT_CONFIG_GLOBAL="$WORKDIR/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name piki-init-test
git config --file "$GIT_CONFIG_GLOBAL" user.email piki-init-test@example.invalid

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
}
ng() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
}
# try "설명" 명령... - 명령이 성공하면 통과
try() {
    local desc="$1"
    shift
    if "$@" > /dev/null 2>&1; then ok "$desc"; else ng "$desc"; fi
}
# eq "설명" 실제 기대
eq() {
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        ng "$1"
        printf '       expected: %s\n       actual:   %s\n' "$3" "$2"
    fi
}

cd "$ROOT" || exit 1

echo "1. 빈 폴더에서 부트스트랩"
PIKI_INIT_OFFLINE=1 bash "$INIT" > "$LOGS/run1.log" 2>&1
eq "종료 코드 0" "$?" "0"
try "git repo 생성" test -d .git
try ".gitignore 생성" test -f .gitignore
try "settings.json 생성" test -f .claude/settings.json
try "CLAUDE.md 생성" test -f CLAUDE.md
eq "브랜치 이름" "$(git branch --show-current)" "workspace"
eq "부트스트랩 직후 clean (첫 커밋이 산출물 전부 포함)" "$(git status --porcelain)" ""

echo "2. settings.json 내용"
if command -v jq > /dev/null 2>&1; then
    try "유효한 JSON" jq -e . .claude/settings.json
    # 물결표는 Claude Code 가 푸는 것이라 파일 안에 리터럴로 남아야 한다.
    # shellcheck disable=SC2088
    eq "autoMemoryDirectory 가 물결표 그대로" \
        "$(jq -r '.autoMemoryDirectory' .claude/settings.json)" "~/.claude/piki-memory"
    cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' .claude/settings.json)
    # 훅 문자열 안의 셸 조각은 생성 시점에 확장되면 안 된다 (확장되면 훅이 죽는다).
    # shellcheck disable=SC2016
    case "$cmd" in
        *'$(mktemp)'*) ok "훅 안의 mktemp 치환이 확장되지 않음" ;;
        *) ng "훅 안의 mktemp 치환이 확장되지 않음 (actual: $cmd)" ;;
    esac
    case "$cmd" in
        *'repos/TeamPiKi/infra/contents/install.sh'*) ok "훅이 install.sh 를 받는다" ;;
        *) ng "훅이 install.sh 를 받는다" ;;
    esac
else
    echo "  skip jq 없음 - JSON 검증 생략"
fi

echo "3. CLAUDE.md 가 로비 규칙을 import"
try "import 줄 있음" grep -q '^@\.claude/rules/piki-workspace\.md' CLAUDE.md

echo "4. .gitignore 가 설치 자산을 제외"
for pat in '/.claude/commands/' '/.claude/rules/' '/.claude/worktrees/'; do
    try "무시: $pat" grep -qxF "$pat" .gitignore
done
try "허용: !/.claude/" grep -qxF '!/.claude/' .gitignore

echo "5. 멱등 (두 번째 실행이 아무것도 바꾸지 않는다)"
snapshot() { find . -path ./.git -prune -o -type f -print | sort | xargs shasum 2> /dev/null | shasum; }
before=$(snapshot)
PIKI_INIT_OFFLINE=1 bash "$INIT" > "$LOGS/run2.log" 2>&1
eq "두 번째 종료 코드 0" "$?" "0"
eq "파일 내용 불변" "$(snapshot)" "$before"
try "이미 있는 것은 건너뛴다고 보고" grep -q '건너뜀' "$LOGS/run2.log"

echo "6. 사용자가 이미 쓴 CLAUDE.md 는 덮지 않는다"
mkdir -p "$WORKDIR/other" && cd "$WORKDIR/other" || exit 1
printf '# 내 메모\n' > CLAUDE.md
PIKI_INIT_OFFLINE=1 bash "$INIT" > "$LOGS/run3.log" 2>&1
eq "CLAUDE.md 내용 보존" "$(cat CLAUDE.md)" "# 내 메모"
try "import 줄 누락을 알린다" grep -q '직접 추가할 것' "$LOGS/run3.log"

echo "7. 잘못된 자리에서는 멈춘다"
mkdir -p "$WORKDIR/fakerepo/sub" && cd "$WORKDIR/fakerepo" || exit 1
git init -q && git remote add origin https://github.com/TeamPiKi/core.git
PIKI_INIT_OFFLINE=1 bash "$INIT" > "$LOGS/run4.log" 2>&1
eq "origin 있는 repo 에서 exit 1" "$?" "1"
try "clone 을 시작하지 않음" grep -q '기존 repo' "$LOGS/run4.log"
cd "$WORKDIR/fakerepo/sub" || exit 1
PIKI_INIT_OFFLINE=1 bash "$INIT" > "$LOGS/run5.log" 2>&1
eq "repo 하위 폴더에서 exit 1" "$?" "1"

echo
printf '통과 %d, 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
