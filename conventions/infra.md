# 인프라 공통 규약 (등급 A: 이미 통일됨)

세 서비스가 **이미 동일하게 지키고 있는** 인프라 규약을 명문화한다.
"통일 작업"이 아니라 "이미 통일된 사실의 기준선"이다. 신규 서비스·환경은 이 규약을 따른다.
값은 각 repo 의 terraform·배포 스크립트에서 실측한 것이다.

## 1. Terraform state

단일 S3 버킷을 서비스별 key prefix 로 나눠 blast-radius 를 격리한다.

| 서비스 | state key | 비고 |
|---|---|---|
| server (앱) | `terraform.tfstate` | dev/staging/prod 를 하나로 통합한 single state |
| extractor | `extractor/terraform.tfstate` | 앱 state 와 분리 |
| headless | `headless-browser/terraform.tfstate` | 앱 state 와 분리 |

- 버킷 `piki-tfstate-<ACCOUNT_ID>` (ap-northeast-2), `encrypt = true`, `use_lockfile = true`.
  잠금은 S3 native lock 을 쓰며 DynamoDB 락 테이블을 두지 않는다. 셋 다 동일.
- **버킷명 주입**: public repo(extractor·headless)는 계정번호 노출을 막으려 gitignore 된
  `backend.hcl` 로 주입하고 `backend.hcl.example` 만 커밋한다. private repo(server)는 코드에
  직접 박아도 된다. 이 차이는 repo 공개성에 따른 정당한 분기다.
- **apply 는 CI 없이 수동**(팀 규율). state 가 key 로 분리되어 각 apply 는 자기 key 의
  인프라에만 영향을 준다. (단 server 는 dev/staging/prod 통합 state 라 로컬 apply 가 prod 까지 미침.)

## 2. 배포 단위 = 단일 Docker 이미지

- 배포 단위는 항상 **단일 Docker 이미지**다. jar/소스가 아니라 이미지가 경계.
- **시크릿은 이미지에 굽지 않고 런타임 주입**한다. (출처는 아직 서비스별로 다르다:
  server=GitHub secrets→env, extractor·headless=SSM Parameter Store `/piki-<service>/*`.
  SSM 단일화는 등급 C 후속.)
- 컨테이너는 `--restart unless-stopped` 로 실행해 박스 재부팅에 자동 복구한다.
  (server·headless 실측 확인, extractor 는 컨테이너 실행이 배포 레이어 소관.)

## 3. 네트워크 격리

- **모든 박스 EIP 고정**: egress IP 를 고정해 몰 차단 대응·IP 평판을 관리하고, 앱은 서로를
  private IP 로 호출한다.
- **내부 서비스(extractor·headless)는 인바운드를 IP 가 아니라 SG-id 참조로 격리**한다
  ("우리 서버만" 도달).
  - extractor ingress = [app SG] on 8090
  - headless ingress = [app SG, extractor SG] on 8000
- **공개 서비스(server)만** 0.0.0.0/0 인바운드(80·443) + nginx TLS 를 연다. 앱 포트(8080)는
  외부에 노출하지 않고 nginx 가 localhost 로 forward 한다. server SG 의 ingress 규칙은
  콘솔/CLI 가 권위를 가지며 terraform 은 `ignore_changes = [ingress]` 로 덮어쓰지 않는다.
- **egress 는 셋 다 전체 개방**(0.0.0.0/0). 외부 몰 fetch·LLM·헤드리스 렌더·프록시로 나가야 하기 때문.
