# infra

PiKi 네 repo(core / extractor / renderer / infra)에
걸치는 **공통 자산의 SSOT**. 두 갈래를 담는다.

- **배포 공통화** — 배포 계약·공유 블록 (각 서비스 `deploy.yml` 이 이 블록들을 조립)
- **개발 규약 공통화** — 커밋 규약·git hooks 등, repo 마다 복제되면 어긋나는 개발 컨벤션

각 서비스의 terraform 은 자기 repo `infra/` 에 그대로 두고, 이 repo 는 **여러 repo 에
걸치는 공통 자산**만 담는다. 전체 시스템 구성은 [core](https://github.com/TeamPiKi/core) 를 참고한다.

## 입장 기준 (잡동사니 서랍 방지)

이 repo 에 들어올 수 있는 자산은 다음 두 조건을 **모두** 만족하는 것뿐이다.

1. **2개 이상의 repo 가 소비**한다 (한 repo 전용이면 그 repo 에 둔다).
2. **SSOT + 배선이 필요**하다 — 복제해 두면 어긋나는(drift) 성질이 있어, 정본 한 곳과
   각 repo 로의 배선(동기화) 메커니즘이 필요한 자산.

"공통이니까 일단 여기에"는 금지. 위 기준을 못 넘으면 원래 repo 에 둔다.

## 왜 블록식인가 (배포 갈래)

세 서비스의 배포는 "같은 블록들의 다른 부분집합 + 다른 파라미터"로 표현된다.

- headless  = build -> ship -> run -> healthcheck
- extractor = build -> ship -> inject_secrets -> run -> healthcheck
- server    = build -> ship -> provision -> inject_secrets -> run -> healthcheck -> swap_traffic -> (fail -> rollback) -> notify

server 가 풀세트, 나머지는 그 부분집합. 환경 차이의 대부분은 블록 본문이 아니라
**블록에 넘기는 인자**다. 블록이 도는 실행 기반은 **SSH runner 단일**로 확정했고(내부
박스도 SG 22 를 열어 통일), 블록은 순수 bash 라 실행 위치에 중립이다.

## 구조

```
infra/
  install.sh     # 개발 규약 자산 설치기 (정본) — 자산 목록·설치 위치·실패 처리를 여기만 안다.
                 # 배포 갈래(blocks)는 설치 대상이 아니다 — 각 서비스 deploy 가 원격 fetch 로 소비.
                 # contracts 도 산문은 같지만, 기계가 읽는 code 카탈로그만 소비 repo 의
                 # shared-infra/contracts 로 설치한다 (로컬 참조 편의 — CI 는 checkout 으로 직접 받는다)
  conventions/   # 규약 (이미 통일된 기준선 + 이 repo 자산의 작성 규칙)
    infra.md     # terraform state·컨테이너 배포단위·네트워크 격리 (등급 A)
    blocks.md    # 블록 작성 원칙 (실행위치 중립·값 미소유·종료코드·셀프검증)
    testing.md   # 테스트 컨벤션 원칙 (스택 무관 + JVM/Spring 공통) — install.sh 가 소비 repo 의
                 # .claude/rules/testing-principles.md 로 설치, 언어 바인딩은 각 repo 소유
  contracts/     # 서비스 간 계약 (판정 방식·규약)
    health.md    # 헬스체크 계약 (첫 통일 대상)
    observability.md  # 관측 계약 (Alloy 수집·라벨·로그 형식)
    extraction-api.md            # 추출 API 계약 (core -> extractor: 요청·응답 3갈래·code 의미·타임아웃 예산)
    extraction-error-codes.yaml  # 추출 실패 code 카탈로그 (정본 데이터) — 소비 repo 메타 테스트가 읽어 대조
  blocks/        # 실행 위치 중립 공유 블록 (bash 스크립트 + 관측 설정)
    healthcheck.sh
    healthcheck.test.sh
    run_container.sh
    run_container.test.sh
    alloy/       # 관측 수집기(Alloy) 공통 블록 (config.alloy·provision-alloy.sh·provision-alloy-ssm.sh)
  hooks/         # git hooks 정본 (commit-msg) — install.sh 가 각 repo 로 설치
  skills/        # 스킬 정본 — install.sh 가 설치한다. repo 워크플로(commit·coderabbit·pr·issue·session-check·session-close)는
                 # 각 repo(infra 자신 포함)의 .claude/commands 로, 세션 관리(retitle·find-session)는 repo 무관이라 ~/.claude/commands 로 간다
  claude/        # Claude Code 세션 자산 정본 — 설치 대상이 repo 가 아니라 사용자 홈(~/.claude)이라 그 구조를 미러링한다
    hooks/       # 세션 훅 (session-title-emit·session-title-compute) — 제목을 대화 맥락으로 갱신
    scripts/     # 세션 유틸 (find-session)
  .github/workflows/  # CI (정본) — shellcheck·블록 셀프테스트
    ci.yml
```
