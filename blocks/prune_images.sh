#!/usr/bin/env bash
#
# 공통 배포 블록: 박스 이미지 정리 + 여유 공간 가드
#
# 새 이미지를 받기 전에 쓰지 않는 이미지를 비우고, 그래도 여유가 모자라면 배포를 여기서 끊는다.
# 실행 위치 중립 - 순수 bash + docker CLI 만 쓰므로 SSH runner 에서든 SSM in-box 에서든 같은
# 스크립트가 그대로 돈다. transport 는 호출자 소관 (conventions/blocks.md 1번 원칙).
#
# **호출 위치는 이미지 pull 앞이다.** 배포 마지막에 두면 디스크가 찬 상태에서 pull 이 먼저
# 실패해 정리 자체가 실행되지 않는다 - 그 배치였던 renderer 가 2026-09-13 배포에서 디스크
# 98% 로 `failed to extract layer` 를 맞았고, 사람이 박스에 들어가 이미지를 지워야 풀렸다.
# 규칙의 정본은 conventions/infra.md.
#
# 실행 중 컨테이너가 쓰는 이미지는 정리 대상이 아니다. 즉 pull 앞에서 부르면 직전 배포
# 이미지(아직 그 컨테이너가 떠 있다)는 살아남고 교체 뒤 다음 배포에서 지워진다 - 보존 개수를
# 세는 로직 없이 "현재 + 직전" 두 개가 유지된다. 더 오래된 롤백은 레지스트리에서 받는다.
#
# 사용 예:
#   prune_images.sh --min-free-gb 4            # 이미지가 큰 서비스(renderer 약 1.7GB)
#   prune_images.sh --min-free-gb 2            # core·extractor
#   prune_images.sh --min-free-gb 2 --dry-run  # 정리 없이 여유만 검사
#
# 인자:
#   --min-free-gb  (필수) 정리 후 있어야 할 최소 여유(GB, 정수). 기준은 "새 이미지 크기 x 2 + 여유"
#                  이고 이미지 크기가 서비스마다 다르므로 default 를 두지 않는다
#                  (conventions/blocks.md 2번 원칙).
#   --path         여유를 잴 경로. 기본 `/`. docker 데이터 루트가 다른 볼륨이면 그 경로를 준다
#   --dry-run      (선택 플래그) 정리하지 않고 현재 여유만 검사한다
#
# 종료 코드: 성공 0, 정리 후에도 여유 부족·측정 실패 1, 인자 오류 2

set -euo pipefail

MIN_FREE_GB=""
TARGET_PATH="/"
DRY_RUN=0

# 값을 받는 옵션이 마지막 인자로 끝나면(값 누락) shift 2 가 set -e 로 exit 1 이 되어
# 계약(인자 오류=2)이 깨진다 - 값 존재를 먼저 검사한다 (run_container.sh 와 동일).
require_value() {
  [ "$2" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --min-free-gb) require_value "$1" "$#"; MIN_FREE_GB="$2"; shift 2;;
    --path)        require_value "$1" "$#"; TARGET_PATH="$2"; shift 2;;
    --dry-run)     DRY_RUN=1; shift 1;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$MIN_FREE_GB" ] || { echo "--min-free-gb is required" >&2; exit 2; }
case "$MIN_FREE_GB" in
  ''|*[!0-9]*) echo "--min-free-gb must be a non-negative integer: $MIN_FREE_GB" >&2; exit 2;;
esac

# -P: POSIX 출력. 긴 디바이스명이 줄바꿈되면 컬럼이 밀려 Available 자리를 잘못 읽는다.
# -m: 1MB 블록 정수라 소수점 파싱이 없다.
# df 가 실패하면 빈 문자열로 돌려 호출부가 메시지와 함께 끊게 한다 - pipefail 로 여기서 죽으면
# 원인이 종료 코드에만 남는다.
free_mb() {
  df -Pm "$TARGET_PATH" 2>/dev/null | awk 'NR==2 {print $4}' || true
}

FREE_BEFORE=$(free_mb)
[ -n "$FREE_BEFORE" ] || { echo "cannot read free space: $TARGET_PATH" >&2; exit 1; }

if [ "$DRY_RUN" -eq 1 ]; then
  FREE_NOW="$FREE_BEFORE"
  echo "[prune] dry-run: 정리하지 않고 여유만 검사한다"
else
  # -a: 실행 중 컨테이너가 안 쓰는 이미지 전부. dangling 만 지우면 배포마다 남는 sha 태그가
  # 무한히 쌓인다(extractor 실측 35개·7.9GB). 실패해도 중단하지 않는다 - 진짜 판정은 아래 여유
  # 검사이고, 정리 실패보다 "공간이 없는데 pull 로 넘어가는 것" 이 위험하다.
  if ! docker image prune -af >/dev/null 2>&1; then
    echo "[prune] docker image prune 실패 - 여유 검사만 계속한다" >&2
  fi
  FREE_NOW=$(free_mb)
  [ -n "$FREE_NOW" ] || { echo "cannot read free space after prune: $TARGET_PATH" >&2; exit 1; }
fi

echo "[prune] $TARGET_PATH 여유 ${FREE_BEFORE}MB -> ${FREE_NOW}MB"

MIN_FREE_MB=$((MIN_FREE_GB * 1024))
if [ "$FREE_NOW" -lt "$MIN_FREE_MB" ]; then
  echo "[prune] 여유 ${FREE_NOW}MB < 필요 ${MIN_FREE_MB}MB - pull 앞에서 중단한다" >&2
  exit 1
fi

echo "[prune] OK (필요 ${MIN_FREE_MB}MB)"
