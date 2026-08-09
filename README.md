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
    testing.md   # 테스트 컨벤션 원칙 (스택 무관 + JVM/Spring 공통) — install.sh 가 소비 repo 의
                 # .claude/rules/testing-principles.md 로 설치, 언어 바인딩은 각 repo 소유
  contracts/     # 서비스 간 배포 계약 (판정 방식·규약)
    health.md    # 헬스체크 계약 (첫 통일 대상)
  blocks/        # 실행 위치 중립 공유 스크립트 (순수 bash)
    healthcheck.sh
    healthcheck.test.sh
  hooks/         # git hooks 정본 (commit-msg) — install.sh 가 각 repo 로 설치
  skills/        # 스킬 정본 — install.sh 가 설치한다. repo 워크플로(commit·coderabbit·pr·issue·session-check·session-close)는
                 # 소비 repo 의 .claude/commands 로, 세션 관리(retitle·find-session)는 repo 무관이라 ~/.claude/commands 로 간다
  claude/        # Claude Code 세션 자산 정본 — 설치 대상이 repo 가 아니라 사용자 홈(~/.claude)이라 그 구조를 미러링한다
    hooks/       # 세션 훅 (session-title-emit·session-title-compute) — 제목을 대화 맥락으로 갱신
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
      repo 무관하게 만든 뒤 승격. `install.sh` 가 repo 의 `.claude/commands/` 로 설치한다
      (`gc` 는 `commit` 별칭). self 모드(infra 자신)는 처음엔 버전 영역 오염을 피해 스킵했으나,
      infra 에서도 커밋·PR 이 일어나 설치 대상에 포함했다 (#33 — untracked 노이즈는
      `.gitignore` 의 `.claude/commands/` 가 막는다. 규약 문서는 소비 repo 한정 유지).
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
      무엇이었는지 못 가린다. 스킬 `retitle`·`find-session`(repo 무관이라 전역 설치) 과 세션 훅(대화 맥락 기반 주기 갱신) + 검색 유틸을 SSOT 로 올렸다. **설치기가 사용자 홈(`~/.claude`)까지
      다루는 첫 자산**이라 그 영역만 규칙을 더 세게 뒀다: 등록은 없을 때만(멱등), 다른 훅은
      무간섭, `~/.claude/.no-session-hooks` 로 opt-out, jq 부재·JSON 손상·설정 파일 부재면 무동작.
      제목 갱신은 방출(캐시)과 계산(백그라운드 haiku)을 분리해 프롬프트 지연이 0 이다.
- [x] 테스트 컨벤션 원칙 SSOT 화 (2026-07-29) — core(Kotlin)의 규약을 extractor(Java)가 "번역판"으로
      복제해 두 벌이 존재했다. 복제본은 원문을 손으로 따라가야 해 실제로 리브랜딩 후 한동안 옛
      이름(`PIKI-Server`)을 가리키다 뒤늦게 정정된 이력이 있다(복제 유지비용의 실증). **원칙과 바인딩을 갈라** 원칙만 `conventions/testing.md` 로
      올린다 — 1장 스택 무관(분류·가치 판단·결정 트리·모킹 금지·셋업·네이밍·기계 강제), 2장
      JVM·Spring 공통(컨텍스트 캐싱·E2E 격리·동시성). 언어 문법에 묶이는 것(메서드명 표기·단언
      라이브러리·DB 컨테이너·좌표·메타 테스트 구현)은 각 repo 가 소유한다. 스킬과 달리 규약은
      에이전트 컨텍스트에 상주해야 효력이 있어 `.claude/rules/` 로 설치하고 CLAUDE.md 가 import 한다.
- [x] 세션 제목을 맥락 단일 근거로 정리 (2026-07-29) — 시작 시 브랜치명을 붙이던 훅을 제거했다.
      실측상 브랜치 제목은 거의 다 3프롬프트 안에 맥락 제목으로 덮여 실익이 없었고(살아남은 건
      짧게 끝난 세션 하나뿐), 맥락 제목이 훨씬 구체적이다(`fix/802-parsing-heartbeat-stale` →
      "일시오류 반납 및 박동 캡 제거"). 반면 워크트리를 재사용하면 위치에서 온 이름이 실제 작업과
      어긋나 거짓 제목이 굳는 위험만 남는다. 함께 사용자 이름 존중 결함도 고쳤다 — 첫 프롬프트에
      이미 제목이 있으면(`claude -n` 등) 그 세션은 자동 갱신에서 제외한다. 기존 변경 감지만으로는
      우리가 한 번도 방출하기 전이라 비교가 건너뛰어져 사용자 이름을 덮어썼다.
- [x] 설치기에 철거 경로 추가 (2026-07-29) — 설치기는 설치만 해서, 정본에서 자산을 지워도 이미
      깔린 환경에는 파일·등록이 남아 계속 돌았다(#26 으로 브랜치 네이밍을 지웠는데 내 환경에서
      그대로 동작한 것이 발견 계기). `RETIRED_HOOKS` 목록의 자산을 홈에서 지우고 settings.json
      등록도 해제한다. 우리가 설치했던 경로가 정확히 일치할 때만 건드리고 사용자의 다른 훅은
      보존하며, 목록은 추가만 한다(오래 안 켠 환경도 언젠가 켜면 정리되도록).
- [x] 은퇴 자산 자동 감지 (2026-07-30) — 손으로 관리하던 은퇴 목록을 **설치 매니페스트**로 대체했다.
      설치기가 "이번에 설치하려는 경로"를 기록해 두고, 다음 실행에서 **지난 기록 − 이번 목록 = 은퇴**
      로 스스로 판정한다. 이제 자산을 없앨 때 정본에서 파일만 지우면 되고 목록에 적을 필요가 없다
      (#27 직후 실제로 적는 걸 빠뜨려 머지 후에도 계속 돌던 사고가 계기). 기록은 **결과가 아니라
      선언**이라 오프라인으로 fetch 가 실패해도 은퇴로 오인되지 않으며, 홈(머신당)과 repo(.git 안,
      워크트리 공유) 범위를 나눠 A repo 에서 켤 때 B repo 설치본이 사라진 것으로 보이지 않게 했다.
      삭제 대상은 우리 설치 위치 안의 경로로 제한한다. `RETIRED_HOOKS` 는 기록이 없던 시절 자산을
      위한 일회성 다리로만 남는다.
- [x] 관리 자산을 읽기 전용으로 설치 (2026-07-30) — 관리 경로의 파일은 SSOT 소유이고 수정은 infra
      에서 한다. 그런데 로컬에서 고쳐도 다음 설치가 조용히 되돌릴 뿐이라, 고친 사람은 자기 수정이
      사라진 것도 몰랐다. 이제 `md` 는 444, 실행물은 555 로 깔아 **고치려는 그 순간 막힌다**
      (편집기·셸이 거부). 정본 갱신과 은퇴 삭제는 그대로 동작한다. 함께 삭제 시 지문 대조(#29)를
      제거했다 — 설치가 로컬 수정을 덮어쓰면서 삭제만 그것을 존중하는 것은 정책 모순이고,
      읽기 전용이 그 상황 자체를 없앤다.
