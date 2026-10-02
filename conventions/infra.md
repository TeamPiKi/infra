# 인프라 공통 규약

세 서비스가 지키는 인프라 규약이다. 신규 서비스·환경은 이 규약을 따른다.
값은 각 repo 의 terraform·배포 스크립트가 정본이다.

## 1. Terraform state

단일 S3 버킷을 서비스별 key prefix 로 나눠 blast-radius 를 격리한다.

| 서비스 | state key | 비고 |
|---|---|---|
| core (앱) | `terraform.tfstate` | dev/prod 를 하나로 통합한 single state |
| core Grafana | `grafana.tfstate` | 알림·대시보드 (terraform-grafana). 앱 state 와 분리 |
| extractor | `extractor/terraform.tfstate` | 앱 state 와 분리 |
| renderer | `headless-browser/terraform.tfstate` | 앱 state 와 분리 (key 는 S3 의 사실 기록이라 옛 이름 유지) |

- 버킷 `piki-tfstate-<ACCOUNT_ID>` (ap-northeast-2), `encrypt = true`, `use_lockfile = true`.
  잠금은 S3 native lock 을 쓰며 DynamoDB 락 테이블을 두지 않는다. 모든 key 동일.
- **버킷명 주입**: public repo 는 계정번호 노출을 막으려 gitignore 된 `backend.hcl` 로
  주입한다. 템플릿은 extractor·renderer 가 `backend.hcl.example`, core 는 `terraform/README.md`
  의 파생 명령이다.
- **공개 repo 값 규율**: 이 repo 를 포함한 public repo 에는 AWS 계정번호·호스트 주소·
  private IP·토큰 등 내부 식별 값을 커밋하지 않는다. 문서엔 `<ACCOUNT_ID>` 같은
  플레이스홀더를 쓰고, 실제 값은 각 환경의 gitignore 파일·시크릿 저장소가 갖는다.
- **apply 는 CI 없이 수동**(팀 규율). state 가 key 로 분리되어 각 apply 는 자기 key 의
  인프라에만 영향을 준다. (단 core 는 dev/prod 통합 state 라 로컬 apply 가 prod 까지 미침.)

## 2. 배포 단위 = 단일 Docker 이미지

- 배포 단위는 항상 **단일 Docker 이미지**다. jar/소스가 아니라 이미지가 경계.
- **시크릿은 이미지에 굽지 않고 런타임에 SSM Parameter Store 에서 주입**한다 (경로 규약은 4번 항목).
- 컨테이너는 `--restart unless-stopped` 로 실행해 박스 재부팅에 자동 복구한다.
- **이미지 정리는 pull 앞에서, `blocks/prune_images.sh` 로 한다.** 배포 마지막에 두면 디스크가
  찬 상태에서 pull 이 먼저 실패해 정리가 영영 실행되지 않는다 (실측: 디스크 98% 에서
  `failed to extract layer`). 블록은 정리 후 여유가 `--min-free-gb` 미만이면 pull 앞에서 배포를 끊는다.
- **최소 여유 기준은 함대 정책이라 블록 기본값(`prune_images.sh` 의 `MIN_FREE_GB`)이 정본이다.**
  호출부가 값을 반복하지 않고, 기준을 바꿀 때 infra 한 곳만 고치면 다음 배포부터 전 서비스에
  반영된다(소비 repo 가 배포마다 infra main 에서 블록을 받아가기 때문). 앱 박스 볼륨 통일
  (각 terraform 의 볼륨 크기)이 이 값의 전제이고, 볼륨이 다른 박스만 `--min-free-gb` 로 덮어쓴다.
- **보존 개수를 세지 않는다.** 실행 중 컨테이너의 이미지는 정리 대상이 아니라, pull 앞에서
  정리하면 직전 배포 이미지가 자동으로 살아남아 "현재 + 직전" 이 유지된다. 더 오래된 롤백은
  레지스트리에서 받는다.

## 3. 네트워크 격리

- **앱·extractor·renderer 박스 EIP 고정**: egress IP 를 고정해 몰 차단 대응·IP 평판을 관리하고,
  앱은 서로를 private IP 로 호출한다. DB 박스는 EIP 없이 자동 할당 IP 를 쓴다. 앱이 사설 IP 로만
  접근하기 때문이다.
- **내부 서비스(extractor·renderer·DB)의 서비스 포트 인바운드는 IP 가 아니라 SG-id 참조로 격리**한다
  ("우리 서버만" 도달).
  - extractor ingress = [app SG] on 8090
  - renderer ingress = [app SG, extractor SG] on 8000
  - DB ingress = [app SG] on 3306
- **서비스 포트를 공개하는 것은 core 뿐**이다. 0.0.0.0/0 인바운드(80·443) + nginx TLS 를 연다.
  앱 포트(blue·green 슬롯)는 외부에 노출하지 않고 nginx 가 localhost 로 forward 한다. core SG 의
  ingress 규칙은 콘솔/CLI 가 권위를 가지며 terraform 은 `ignore_changes = [ingress]` 로 덮어쓰지 않는다.
- **egress 는 모든 박스가 전체 개방**(0.0.0.0/0). 외부 몰 fetch·LLM·렌더 호출과 SSM·S3·이미지
  pull 에 필요하다.

## 4. 시크릿 네이밍

- **서비스 시크릿은 `/piki-<service>/` 아래에 둔다**(하위 구성은 각 repo 배포 워크플로가 정본).
  서비스가 공유하는 관측 자격만 `/piki/observability/*` 에 둔다.
- `<key>` 는 kebab-case 다.
- **서비스 세그먼트는 repo 이름과 일치시킨다.** 새 서비스·새 시크릿은 시작부터 따른다.
  예외는 renderer 의 `/piki-headless-browser/` 하나다(1번 항목의 state key 와 같은 이유로 이미
  생성된 경로의 옛 이름 유지).
