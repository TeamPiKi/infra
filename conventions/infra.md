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
| renderer | `headless-browser/terraform.tfstate` | 앱 state 와 분리 (key 는 S3 의 사실 기록이라 옛 이름 유지) |

- 버킷 `piki-tfstate-<ACCOUNT_ID>` (ap-northeast-2), `encrypt = true`, `use_lockfile = true`.
  잠금은 S3 native lock 을 쓰며 DynamoDB 락 테이블을 두지 않는다. 셋 다 동일.
- **버킷명 주입**: public repo 는 계정번호 노출을 막으려 gitignore 된 `backend.hcl` 로
  주입하고 `backend.hcl.example` 만 커밋한다 (extractor·headless 가 이 패턴).
- **공개 repo 값 규율**: 이 repo 를 포함한 public repo 에는 AWS 계정번호·호스트 주소·
  private IP·토큰 등 내부 식별 값을 커밋하지 않는다. 문서엔 `<ACCOUNT_ID>` 같은
  플레이스홀더를 쓰고, 실제 값은 각 환경의 gitignore 파일·시크릿 저장소가 갖는다.
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

## 4. 시크릿 네이밍

- **SSM Parameter Store 를 쓰는 서비스는 경로를 `/piki-<service>/<key>` 로 통일한다.**
  런타임 주입(2번 항목)의 구체 규약이다. extractor·renderer 가 이미 이 규약을 따른다.
  - extractor: `/piki-extractor/*` (예: `/piki-extractor/gemini-api-key`)
  - renderer: `/piki-headless-browser/*` (예: `/piki-headless-browser/grafana-metrics-url`) —
    `<service>` 자리에 옛 이름 `headless-browser` 를 그대로 쓴다. 1번 항목의 state key 와
    같은 이유다 (이미 생성된 실제 파라미터 경로라, 리네이밍하면 재생성·값 마이그레이션 비용이 든다).
  - `<key>` 는 kebab-case 소문자로 쓴다 (실측 사례: `gemini-api-key`, `grafana-metrics-url`).
- **core(server)는 아직 GitHub secrets 를 쓴다.** SSM 단일화는 등급 C(로드맵)에서 이관하며,
  이관 시 같은 규약을 따라 `/piki-core/*` 를 쓴다.
- **새 서비스·새 시크릿은 시작부터 이 규약을 따른다.** renderer 처럼 이미 생성된 옛 이름을
  유지해야 하는 예외가 아니면, repo 이름과 SSM 서비스 세그먼트를 일치시킨다.
