# infra

PIKI 네 repo(core / extractor / renderer / infra)에
걸치는 **공통 자산의 SSOT**. 두 갈래를 담는다.

- **배포 공통화** — 배포 계약·공유 블록·조립 매니페스트 (블록식 조립)
- **개발 규약 공통화** — 커밋 규약·git hooks 등, repo 마다 복제되면 어긋나는 개발 컨벤션

각 서비스의 terraform 은 자기 repo `infra/` 에 그대로 두고, 이 repo 는 **여러 repo 에
걸치는 공통 자산**만 담는다.

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
**블록에 넘기는 인자**다. 유일한 실질 장벽은 블록이 도는 실행 기반(SSH runner vs
SSM in-box)이며, 이는 얇은 transport 어댑터로 분리한다.

## 구조

```
infra/
  install.sh     # 공통 자산 설치기 (정본) — 자산 목록·설치 위치·실패 처리를 여기만 안다
  conventions/   # 규약 (이미 통일된 기준선 + 이 repo 자산의 작성 규칙)
    infra.md     # terraform state·컨테이너 배포단위·네트워크 격리 (등급 A)
    blocks.md    # 블록 작성 원칙 (실행위치 중립·값 미소유·종료코드·셀프검증)
  contracts/     # 서비스 간 배포 계약 (판정 방식·규약)
    health.md    # 헬스체크 계약 (첫 통일 대상)
  blocks/        # 실행 위치 중립 공유 스크립트 (순수 bash)
    healthcheck.sh
    healthcheck.test.sh
  hooks/         # git hooks 정본 (commit-msg) — install.sh 가 각 repo 로 설치
  skills/        # 개발 스킬 정본 (commit·coderabbit·pr·issue·session-check·session-close·retitle·find-session) — install.sh 가 소비 repo 의 .claude/commands 로 설치
  claude/        # Claude Code 세션 자산 정본 — 설치 대상이 repo 가 아니라 사용자 홈(~/.claude)이라 그 구조를 미러링한다
    hooks/       # 세션 훅 (session-auto-name·session-title-emit·session-title-compute)
    scripts/     # 세션 유틸 (find-session)
  .github/workflows/  # CI (정본) — shellcheck·블록 셀프테스트
    ci.yml
```

## 진행 상태

### 배포 공통화
- [x] 헬스체크 계약 + `healthcheck.sh` (첫 공유 블록)
- [x] 등급 A 명문화 (`conventions/infra.md` — terraform state·이미지 배포단위·네트워크 격리)
- [x] 블록 작성 원칙 (`conventions/blocks.md`)
- [x] 관측 계약 + Alloy 공통 블록 (`contracts/observability.md` · `blocks/alloy/`)
- [x] 이미지 태그·레지스트리 네이밍 통일 (`piki-<service>:{latest,<sha>}` — core 는 PR core#723 로 `piki-core` 전환, dev 실배포 검증)
- [x] 시크릿 네이밍 규약 (`/piki-<service>/*` — `conventions/infra.md` "4. 시크릿 네이밍".
      적용 현황: 세 서비스 전부 준수 — core 는 등급 C 이관(core#725·#726)으로 `/piki-core/<env>/*` 사용)
- [x] run_container 블록 (`blocks/run_container.sh` - 기동+즉사 검증·env passthrough·memory 한도,
      세 서비스 전부 소비: core#772·extractor#6·renderer#4)
- [x] ~~provision 블록~~ **안 만들기로 종결** (2026-07-20) - 블록화 기준은 "여러 서비스가 같은 것을
      쓴다"인데, 프로비저닝의 공용분(Alloy)은 이미 `blocks/alloy/` 로 블록화됐고 잔여(swap·redis·
      mysql·nginx)는 core 박스 전용이라 소비자가 하나뿐. 소비자 1개짜리 블록은 간접층만 늘린다
- [x] ~~transport 어댑터 (via-ssh / via-ssm)~~ **불필요로 종결** (2026-07-19) - SSH 단일 transport
      확정(내부 박스 SG 22 개방, ext#5·rend#3)으로 어댑터 분기 자체가 사라짐
- [x] ~~서비스별 조립 매니페스트~~ **안 만들기로 종결** (2026-07-20) - 각 서비스의 deploy.yml 이
      이미 "어떤 블록을 어떤 값으로"를 선언하는 매니페스트이고 GitHub Actions 가 실행기다.
      서비스 3개 규모에서 별도 YAML+해석기 층은 YAGNI
- [x] CI (shellcheck + 블록 셀프테스트, `.github/workflows/ci.yml`)
- [x] CI 를 required status check 로 승격 (`shellcheck`·`block-test`, strict — 2026-07-14 적용)

### 개발 규약 공통화
- [x] commit-msg 훅 SSOT 화 (`hooks/commit-msg`) + 자기 배선 (SessionStart cp)
- [x] 배선 메커니즘 결정: **얇은 부트스트랩 + 정본 설치기(`install.sh`)** — 소비 repo 의
      SessionStart 는 "install.sh 를 원격 fetch 해 실행" 한 줄뿐이고, 남는 상수는 repo 좌표
      1개다(최소 포인터, 제거 불가). 자산 목록·설치 위치·실패 처리는 install.sh(SSOT)만
      알아, 자산이 늘어도 소비 repo 는 무변경. 복사본 체크인 0, worktree 안전
      (`git-common-dir`), 실패 시 기존 설치본 유지. **배선이 서면 기존 복사본은 SSOT 를
      어긋나게 하는 잔재이므로 삭제한다** (이관의 일부).
- [x] 소비 repo 배선: extractor(PR #1 머지) · core(PR #711 머지, 체크인 훅 삭제 + 스킬 타입
      열거 제거 포함) · renderer(origin/main 부트스트랩 배선 반영 확인 — 보류 해소, 2026-07-20)
- [x] 개발 스킬 SSOT 화 (`skills/commit.md` · `skills/coderabbit.md`) — 좌표를 origin 에서 파생해
      repo 무관하게 만든 뒤 승격. `install.sh` 가 소비 repo 의 `.claude/commands/` 로 설치하고
      (`gc` 는 `commit` 별칭), self 모드(infra 자신)에서는 버전 영역 오염을 피해 스킵한다.
      `issue`·`pr` 도 좌표를 repo 무관화해 승격 (2026-07-20) — base 브랜치를 origin/dev → repo
      default 로 파생, core 전용 워크플로(pr-merge-project-sync) 언급을 한정. 보드·Issue Type ID 는
      org 상수라 그대로 둔다. 스킬 전제인 분류 라벨 9종(라벨==브랜치 prefix 1:1)을
      extractor·renderer·infra 에 동기화(기존 기본 라벨은 유지, 추가만)
- [x] `session-check`·`session-close` 승격 (2026-07-27) — core 로컬 스킬로만 있어 다른 소비 repo 에
      배포되지 않던 것을 SSOT 로 올렸다. 두 스킬은 이미 owner/repo 를 origin 에서 파생해 repo 무관
      했고, 유일한 repo 의존이던 session-check 의 TODO 스윕 base(`origin/dev` 하드코딩)를 `pr`·`issue`
      와 같은 우선순위(origin/dev → 레포 default → main)로 파생하게 바꿨다. 승격 중 CodeRabbit 리뷰로
      머지 판정도 강화했다 — `[gone]` 을 머지 증거로 쓰지 않고 merged PR 로 교차 확인, `headRefOid` 로
      "머지 후 새 커밋" 유실 차단, `gh` 조회 실패 시 워크트리 제거 전 중단. core 체크인본 삭제 +
      `.gitignore` 등록 완료(core#809), extractor·renderer 설치 확인.
- [x] 소비 repo 의 기존 복사본 삭제 + `.gitignore` 처리(SSOT 잔재 제거) — core PR #722 로 완료
      (2026-07-12 머지: `commit.md`·`coderabbit.md` 로컬 복사본 삭제 + `.gitignore` 에 설치본
      3경로 등록)
- [x] 세션 식별 자산 승격 (2026-07-27) — 세션을 나중에 되찾는 문제를 닫는다. `/resume` 은 현재
      폴더의 세션만 보여줘서 worktree 작업이 메인 체크아웃에서 안 보이고, 제목이 없으면 목록에서
      무엇이었는지 못 가린다. 스킬 `retitle`·`find-session` 과 세션 훅 3종(브랜치 기반 초기 이름 +
      대화 맥락 기반 주기 갱신) + 검색 유틸을 SSOT 로 올렸다. **설치기가 사용자 홈(`~/.claude`)까지
      다루는 첫 자산**이라 그 영역만 규칙을 더 세게 뒀다: 등록은 없을 때만(멱등), 다른 훅은
      무간섭, `~/.claude/.no-session-hooks` 로 opt-out, jq 부재·JSON 손상·설정 파일 부재면 무동작.
      제목 갱신은 방출(캐시)과 계산(백그라운드 haiku)을 분리해 프롬프트 지연이 0 이다.
