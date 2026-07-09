# PIKI-Infra

PIKI 세 서비스(PIKI-Server / PIKI-Extractor / PIKI-HeadlessBrowser)의 배포를
**블록식 조립**으로 공통 관리하기 위한 규약·공유 스크립트 모음.

각 서비스의 terraform 은 자기 repo `infra/` 에 그대로 두고, 이 repo 는 세 배포에
걸치는 **공통 계약·공유 블록·조립 매니페스트**만 담는다.

## 왜 블록식인가

세 서비스의 배포는 "같은 블록들의 다른 부분집합 + 다른 파라미터"로 표현된다.

- headless  = build -> ship -> run -> healthcheck
- extractor = build -> ship -> inject_secrets -> run -> healthcheck
- server    = build -> ship -> provision -> inject_secrets -> run -> healthcheck -> swap_traffic -> (fail -> rollback) -> notify

server 가 풀세트, 나머지는 그 부분집합. 환경 차이의 대부분은 블록 본문이 아니라
**블록에 넘기는 인자**다. 유일한 실질 장벽은 블록이 도는 실행 기반(SSH runner vs
SSM in-box)이며, 이는 얇은 transport 어댑터로 분리한다.

## 구조

```
PIKI-Infra/
  conventions/   # 이미 통일된 인프라 규약 (등급 A: 기준선)
    infra.md     # terraform state·컨테이너 배포단위·네트워크 격리
  contracts/     # 서비스 간 배포 계약 (판정 방식·규약)
    health.md    # 헬스체크 계약 (첫 통일 대상)
  blocks/        # 실행 위치 중립 공유 스크립트 (순수 bash)
    healthcheck.sh
```

## 진행 상태

- [x] 헬스체크 계약 + `healthcheck.sh` (첫 공유 블록)
- [x] 등급 A 명문화 (`conventions/infra.md` — terraform state·이미지 배포단위·네트워크 격리)
- [ ] 이미지 태그·레지스트리 네이밍 통일 (`piki-<service>:{latest,<sha>}`)
- [ ] 시크릿 네이밍 규약 (`/piki-<service>/*`)
- [ ] run_container / provision 블록
- [ ] transport 어댑터 (via-ssh / via-ssm)
- [ ] 서비스별 조립 매니페스트
