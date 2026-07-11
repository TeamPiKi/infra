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
  hooks/         # git hooks 정본 (commit-msg) — install.sh 가 각 repo 로 설치
  skills/        # 개발 스킬 정본 (commit·coderabbit) — install.sh 가 소비 repo 의 .claude/commands 로 설치
```

## 진행 상태

### 배포 공통화
- [x] 헬스체크 계약 + `healthcheck.sh` (첫 공유 블록)
- [x] 등급 A 명문화 (`conventions/infra.md` — terraform state·이미지 배포단위·네트워크 격리)
- [x] 블록 작성 원칙 (`conventions/blocks.md`)
- [ ] 이미지 태그·레지스트리 네이밍 통일 (`piki-<service>:{latest,<sha>}`)
- [ ] 시크릿 네이밍 규약 (`/piki-<service>/*`)
- [ ] run_container / provision 블록
- [ ] transport 어댑터 (via-ssh / via-ssm)
- [ ] 서비스별 조립 매니페스트

### 개발 규약 공통화
- [x] commit-msg 훅 SSOT 화 (`hooks/commit-msg`) + 자기 배선 (SessionStart cp)
- [x] 배선 메커니즘 결정: **얇은 부트스트랩 + 정본 설치기(`install.sh`)** — 소비 repo 의
      SessionStart 는 "install.sh 를 원격 fetch 해 실행" 한 줄뿐이고, 남는 상수는 repo 좌표
      1개다(최소 포인터, 제거 불가). 자산 목록·설치 위치·실패 처리는 install.sh(SSOT)만
      알아, 자산이 늘어도 소비 repo 는 무변경. 복사본 체크인 0, worktree 안전
      (`git-common-dir`), 실패 시 기존 설치본 유지. **배선이 서면 기존 복사본은 SSOT 를
      어긋나게 하는 잔재이므로 삭제한다** (이관의 일부).
- [x] 소비 repo 배선: extractor(PR #1 머지) · core(PR #711 머지, 체크인 훅 삭제 + 스킬 타입
      열거 제거 포함) · renderer 만 **보류**(로컬에 타 세션 미푸시 커밋, 정리 후 배선)
- [x] 개발 스킬 SSOT 화 (`skills/commit.md` · `skills/coderabbit.md`) — 좌표를 origin 에서 파생해
      repo 무관하게 만든 뒤 승격. `install.sh` 가 소비 repo 의 `.claude/commands/` 로 설치하고
      (`gc` 는 `commit` 별칭), self 모드(infra 자신)에서는 버전 영역 오염을 피해 스킵한다. 소비
      repo 의 기존 복사본은 삭제 + `.gitignore` 처리(SSOT 잔재 제거). `issue`·`pr` 은 아직
      진화 중이라 로컬 유지(후속 승격 후보)
