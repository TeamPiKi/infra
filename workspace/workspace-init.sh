#!/usr/bin/env bash
#
# piki 워크스페이스 루트 1회 부트스트랩.
#
# 무엇을 만드나: 여러 repo 를 한 폴더에 두고 **거기서 세션을 시작하는** 구조. 루트 자신은 코드가
# 없는 얇은 git repo 이고, 세션은 루트에서 시작해 `EnterWorktree(path=)` 로 각 repo 의 워크트리에
# 들어가 작업한다. 루트가 git repo 여야 하는 이유는 실측이다 - non-git 이면 진입 도구가 대상과
# 무관하게 거부한다.
#
# 사용 (빈 폴더에서):
#   mkdir -p ~/code/piki && cd ~/code/piki
#   bash -c "$(gh api -H 'Accept: application/vnd.github.raw' repos/TeamPiKi/infra/contents/workspace/workspace-init.sh)"
#
# 멱등: 이미 있는 것은 건드리지 않는다. 다시 돌려도 안전하고, 빠진 조각만 채운다.
#
# PIKI_INIT_OFFLINE=1 을 주면 네트워크를 쓰는 두 단계(repo clone, 공통 자산 설치)를 건너뛰고
# 로컬 골격만 만든다. 셀프 테스트가 이 모드로 돈다.

set -uo pipefail

REPOS="core client extractor renderer infra"
OFFLINE="${PIKI_INIT_OFFLINE:-0}"

say() { printf '%s\n' "$*"; }

# ---- 0. 진입 가드 ----
#
# 기존 repo 안에서 돌리면 1-4단계가 "이미 있음" 으로 조용히 건너뛰고 5단계가 그 안에 repo 5개를
# clone 한다. 워크스페이스 루트는 origin 이 없다는 사실로 소비 repo 와 갈린다.
# toplevel 은 물리 경로로 나오므로 비교도 물리 경로로 한다 (macOS /tmp·/var 는 symlink).
top=$(git rev-parse --show-toplevel 2> /dev/null)
if [ -n "$top" ] && [ "$top" != "$(pwd -P)" ]; then
    say "기존 repo($top) 의 하위 폴더다 - 워크스페이스로 쓸 폴더에서 다시 실행"
    exit 1
fi
if [ -d .git ] && git remote get-url origin > /dev/null 2>&1; then
    say "origin 이 있는 기존 repo 다 - 워크스페이스로 쓸 폴더에서 다시 실행"
    exit 1
fi

# ---- 1. 루트를 git repo 로 ----
#
# 브랜치 이름을 workspace 로 두는 건 표시용이다. 이 repo 는 origin 이 없고 앞으로도 없다 -
# 추적하는 것은 자기 설정 몇 개뿐이고, 코드는 전부 자식 repo 에 있다.
if [ -d .git ]; then
    say "[1/5] git repo 이미 있음 - 건너뜀"
elif git init -b workspace -q; then
    say "[1/5] git init -b workspace"
else
    say "git init 실패"
    exit 1
fi

# ---- 2. .gitignore ----
#
# 자식 repo 를 통째로 무시한다(각자 자기 이력을 가진다). 허용 목록만 추적하되, .claude 밑에서도
# install.sh 가 설치하는 것(commands·rules)과 워크트리·개인 설정은 제외한다 - 설치 자산은 정본이
# infra 에 있어 여기 커밋하면 두 벌이 된다.
if [ -f .gitignore ]; then
    say "[2/5] .gitignore 이미 있음 - 건너뜀"
else
    cat > .gitignore << 'IGNORE'
# piki 워크스페이스 루트: 자식 repo 와 설치 자산은 추적하지 않는다.
/*
!/.gitignore
!/CLAUDE.md
!/.claude/
/.claude/worktrees/
/.claude/commands/
/.claude/rules/
/.claude/settings.local.json
/shared-infra/
IGNORE
    say "[2/5] .gitignore 생성"
fi

# ---- 3. .claude/settings.json ----
#
# SessionStart 부트스트랩 한 줄이 infra 의 install.sh 를 받아 실행한다. 소비 repo 들과 똑같은
# 패턴이라 루트에도 스킬(.claude/commands)과 로비 규칙(.claude/rules/piki-workspace.md)이 깔린다.
# 슬래시 목록은 **세션을 시작한 폴더** 기준이고 hop 후에도 안 바뀌므로(실측), 루트 설치가 필수다.
#
# autoMemoryDirectory 는 모든 piki 세션이 기억을 한 곳에 모으기 위한 것이다. 루트 세션과 repo
# 세션이 서로 다른 공책을 쓰면 한쪽이 배운 것을 다른 쪽이 모른다. 물결표는 Claude Code 가 푸는
# 것이라 여기서 확장되면 안 된다 - heredoc 을 따옴표로 묶어 셸 확장을 통째로 끈 이유다.
mkdir -p .claude
if [ -f .claude/settings.json ]; then
    say "[3/5] .claude/settings.json 이미 있음 - 건너뜀"
else
    cat > .claude/settings.json << 'SETTINGS'
{
  "autoMemoryDirectory": "~/.claude/piki-memory",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'tmp=$(mktemp); if gh api -H \"Accept: application/vnd.github.raw\" repos/TeamPiKi/infra/contents/install.sh >\"$tmp\" 2>/dev/null && [ -s \"$tmp\" ] && bash -n \"$tmp\" 2>/dev/null; then bash \"$tmp\"; fi; rm -f \"$tmp\"; exit 0'"
          }
        ]
      }
    ]
  }
}
SETTINGS
    say "[3/5] .claude/settings.json 생성"
fi

# ---- 4. CLAUDE.md ----
#
# 로비 규칙(.claude/rules/piki-workspace.md)은 install.sh 가 배포하지만, 규약 파일은 CLAUDE.md 가
# import 해야 세션 컨텍스트에 올라온다(실측: import 없이는 로드되지 않는다). 그 한 줄을 위해 만든다.
# 이미 있으면 사용자 문서이므로 손대지 않고, import 줄이 없을 때만 알려 준다.
if [ ! -f CLAUDE.md ]; then
    cat > CLAUDE.md << 'CLAUDEMD'
# piki 워크스페이스

@.claude/rules/piki-workspace.md
CLAUDEMD
    say "[4/5] CLAUDE.md 생성 (로비 규칙 import)"
elif grep -q '^@\.claude/rules/piki-workspace\.md' CLAUDE.md; then
    say "[4/5] CLAUDE.md 이미 있음 (import 확인됨)"
else
    say "[4/5] CLAUDE.md 이미 있음 - 다음 줄을 직접 추가할 것: @.claude/rules/piki-workspace.md"
fi

# ---- 5. 없는 repo clone ----
#
# 이미 있는 폴더는 건드리지 않는다. clone 실패(권한·네트워크)는 치명적이지 않다 - 나머지는 그대로
# 쓰고 나중에 다시 돌리면 된다.
missing=""
for r in $REPOS; do
    # 폴더 존재가 아니라 repo 존재를 본다 - 미리 만들어 둔 빈 폴더를 "있음" 으로 오판하지 않는다.
    [ -d "$r/.git" ] && continue
    missing="$missing $r"
done

if [ "$OFFLINE" = 1 ]; then
    say "[5/5] clone 건너뜀 (오프라인 모드)"
elif [ -z "$missing" ]; then
    say "[5/5] repo 5개 모두 있음 - 건너뜀"
else
    for r in $missing; do
        if command -v gh > /dev/null 2>&1; then
            gh repo clone "TeamPiKi/$r" "$r" -- -q 2> /dev/null
        fi
        # gh 가 없거나 실패했으면 https 로 폴백한다 - repo 5개는 전부 public 이다.
        if [ ! -d "$r/.git" ]; then
            git clone -q "https://github.com/TeamPiKi/$r.git" "$r" 2> /dev/null
        fi
        if [ -d "$r/.git" ]; then
            say "[5/5] clone $r"
        else
            say "[5/5] clone 실패: $r (나중에 다시 실행하면 채워진다)"
        fi
    done
fi

# ---- 첫 커밋 (아직 이력이 없을 때만) ----
if [ -z "$(git log --oneline -1 2> /dev/null)" ]; then
    git add .gitignore .claude/settings.json CLAUDE.md 2> /dev/null
    if git -c commit.gpgsign=false commit -q -m "chore: 워크스페이스 루트 설정" 2> /dev/null; then
        say "첫 커밋 생성"
    else
        say "첫 커밋 생략 (git 사용자 설정 확인)"
    fi
fi

# ---- 공통 자산 즉시 설치 ----
#
# 어차피 다음 세션의 SessionStart 가 깔지만, 여기서 한 번 돌려 두면 셋업 직후 첫 세션부터
# 스킬과 로비 규칙이 보인다.
if [ "$OFFLINE" = 1 ]; then
    say "공통 자산 설치 건너뜀 (오프라인 모드)"
else
    tmp=$(mktemp)
    if gh api -H "Accept: application/vnd.github.raw" repos/TeamPiKi/infra/contents/install.sh > "$tmp" 2> /dev/null &&
        [ -s "$tmp" ] && bash -n "$tmp" 2> /dev/null && bash "$tmp"; then
        say "공통 자산 설치 완료"
    else
        say "공통 자산 설치는 건너뜀 (다음 세션 시작 때 자동으로 깔린다)"
    fi
    rm -f "$tmp"
fi

say ""
say "완료. 이 폴더에서 세션을 시작하면 된다:  cd $(pwd) && claude"
exit 0
