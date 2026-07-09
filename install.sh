#!/usr/bin/env bash
#
# PIKI-Infra 공통 자산 설치기 (정본)
#
# 어떤 자산을 어디에 어떤 권한으로 설치하는지, 실패를 어떻게 다루는지는 이 파일만 안다.
# 소비 repo 의 SessionStart 는 이 스크립트를 원격 fetch 해 실행하는 한 줄 부트스트랩만 갖고,
# 소비 repo 에 남는 상수는 repo 좌표(TeamPiKi/PIKI-Infra) 1개뿐이다. 자산이 늘거나
# 설치 로직이 바뀌어도 소비 repo 는 무변경이다.
#
# 실행 모드 (origin 원격으로 자동 판별):
#   - PIKI-Infra 자신 안에서 실행 -> working tree 의 로컬 자산을 설치 (수정 중인 자산 즉시 반영)
#   - 소비 repo 에서 실행(부트스트랩 경유) -> 원격 정본을 fetch 해 설치
#
# 실패 안전: fetch 실패(오프라인·권한 없음)나 빈 응답이면 해당 자산을 건너뛰고 기존
# 설치본을 유지한다. 항상 exit 0 (SessionStart 를 깨뜨리지 않는다).

set -uo pipefail

INFRA_REPO="TeamPiKi/PIKI-Infra"

hooks_dir="$(git rev-parse --git-common-dir 2>/dev/null)/hooks"
[ -d "$hooks_dir" ] || exit 0

if git remote get-url origin 2>/dev/null | grep -q "PIKI-Infra"; then
  get() { cat "$(git rev-parse --show-toplevel)/$1" 2>/dev/null; }
else
  get() { gh api -H "Accept: application/vnd.github.raw" "repos/$INFRA_REPO/contents/$1" 2>/dev/null; }
fi

# $1=자산 경로(repo 내) $2=설치 대상(절대경로) $3=mode
install_asset() {
  local tmp
  tmp=$(mktemp)
  if get "$1" >"$tmp" && [ -s "$tmp" ]; then
    install -m "$3" "$tmp" "$2"
  fi
  rm -f "$tmp"
}

# ---- 자산 목록 (여기만 고치면 모든 소비 repo 에 반영된다) ----
install_asset hooks/commit-msg "$hooks_dir/commit-msg" 755

exit 0
