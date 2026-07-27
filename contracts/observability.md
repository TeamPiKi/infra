# 관측(Observability) 계약

세 서비스(core / extractor / renderer)의 메트릭·로그·트레이스를 Grafana Cloud 로 보내는
공통 수집 계약. 수집기는 **Grafana Alloy** 하나이며, config·기동 블록을 이 repo 가 소유한다.

## 계약

- **박스마다 Alloy 하나** — 수집기는 박스를 따라간다. 크로스박스 scrape 로 남의 박스를 긁지
  않고, 각 박스의 Alloy 가 자기 박스의 컨테이너·호스트만 수집한다.
- **config·기동 블록의 SSOT 는 이 repo** — `blocks/alloy/config.alloy`(컴포넌트 그래프)와
  `blocks/alloy/provision-alloy.sh`(기동 블록). 블록은 값을 담지 않는다.
- **값(자격증명·환경)은 호출부/SSM 주입** — 아래 env 로 주입한다. secret 미등록 박스는
  provision-alloy.sh 가 기동을 skip 한다(빈 endpoint 로 부팅해 crash loop 하지 않는다).

## 수집 대상 = docker label opt-in

다서비스가 한 박스에 동거할 수 있으므로, 서비스명을 열거하는 regex 대신 **컨테이너 라벨로
opt-in** 한다. 라벨이 없는 컨테이너(redis·mysql·alloy 자기 등)는 어떤 신호도 수집되지 않는다.

| 라벨 | 필수 | 기본 | 뜻 |
|---|---|---|---|
| `piki.observe` | 예 | — | `"true"` 여야 수집 대상. 없으면 메트릭·로그 **모두 미수집** |
| `piki.service` | 예 | — | telemetry 서비스 식별자. 허용값 `piki-core`·`piki-extractor`·`piki-renderer` |
| `piki.metrics.port` | 아니오 | — | 호스트 `127.0.0.1` 에서 닿는 메트릭 포트. **없으면 메트릭 미수집**(로그만 걷힘) |
| `piki.metrics.path` | 아니오 | `/metrics` | 메트릭 경로. Spring 서비스는 `/actuator/prometheus` 를 명시한다 |

- 메트릭은 `piki.observe`+`piki.service`+`piki.metrics.port` **셋 다** 있어야 수집된다.
- 로그는 `piki.observe`+`piki.service` 둘만 있으면 수집된다(포트 불필요).
- 라벨 이름의 `.` 은 Alloy docker SD 에서 `__meta_docker_container_label_piki_*` 로 매핑된다.

## 식별자 체계

| 축 | 유래 | 용도 |
|---|---|---|
| `service` / `job` | `piki.service` 라벨 | 서비스 식별. `{job="piki-extractor"}` 식 질의 |
| `instance` | 컨테이너명(선행 슬래시 제거) | blue/green 등 인스턴스 구분 |
| `environment` | `sys.env(ENVIRONMENT)` | 환경 축. dev / staging / prod (기존 유지) |
| `box` | `sys.env(PIKI_BOX)` = 박스 주인 서비스 | 호스트 메트릭의 박스 구분 (**신설**) |
| `deployment.environment` | 트레이스 resource attr | Tempo 의 환경 축(메트릭·로그 `environment` 와 같은 결) |

- **`box` 신설 사유**: `environment=prod` 박스가 2개(core·extractor)가 되면, 호스트 메트릭
  (node_exporter)은 service/instance 축이 없어 같은 environment 로 시계열이 충돌한다. `box` 가
  박스 주인을 붙여 이를 가른다. 앱 메트릭은 service/instance 로 이미 갈리므로 box 가 없어도 되지만,
  remote_write external_labels 는 모든 메트릭에 붙으므로 앱 메트릭에도 box 가 함께 붙는다.
- **box 는 메트릭에만** 붙는다. 로그·트레이스에는 붙이지 않는다(로그는 container, 트레이스는
  service.name 으로 이미 갈린다).
- 트레이스의 서비스 식별자는 앱이 붙이는 `service.name`(resource attr)이다(라벨 유래 아님).

## 로그 형식

수집 대상 컨테이너의 stdout 로그는 **구조화 JSON 한 줄**을 계약으로 한다. 계약의 본질은
형식 이름(ECS 여부)이 아니라 **아래 필드 경로가 유지되는 것**이다 — 박스 Alloy 의 공용
파이프라인(`loki.process`, `blocks/alloy/config.alloy`)이 이 경로를 파싱해 가공하므로,
경로가 바뀌면 유입은 계속되는 채 level 라벨·본문 정리만 **조용히** 사라진다.

| 필드 경로 | 필수 | Alloy 가 하는 일 |
|---|---|---|
| `message` | 예 | 라인 본문을 이 값으로 교체(줄에 메시지만 남김) |
| `log.level` | 예 | `level` 라벨로 승격 — Grafana 레벨 필터·색상 |
| `log.logger` | 아니오 | structured metadata (중카디널리티, 스트림 안 쪼갬) |
| `traceId` / `spanId` (top-level) | 아니오 | structured metadata 로 승격 — 로그→트레이스 점프 |

- **켜는 방법(Spring 서비스)**: 앱 배선 없이 운영 docker run 에 표준 env
  `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs` 를 준다(relaxed binding 이 property 를 직접 채운다).
  **커스텀 env 이름을 만들지 않는다** — 서비스마다 켜는 이름이 갈리면 동거 컨테이너 배선 실수가
  재발한다(2026-07-20 dev extractor: core 전용 이름을 줘 구조화가 무효였다).
- **비 Spring 서비스(renderer)**: ECS 일 필요 없이 위 **필수 경로(`message`·`log.level`)만 유지**하면
  된다 — 선택 경로는 의무가 아니고, 있으면 승격된다(renderer 는 traceparent 수용으로 `traceId`/`spanId` 도 실음).
- **비 JSON 라인은 안전**: `stage.json` 이 조용히 통과시켜 라인을 보존한다 — 평문 로그도 유입은
  되고, level 라벨·본문 정리만 빠진다.

## 트레이스 수신

앱은 자기 박스 Alloy 의 **4318(HTTP)** 로 push 한다(gRPC 는 4317). 앱 컨테이너는 bridge
네트워크라 컨테이너 안 `localhost` 는 자기 자신을 가리켜 `--network host` 인 Alloy 에 안 닿는다.
그래서 앱 컨테이너는 다음으로 배선한다:

- `--add-host=host.docker.internal:host-gateway`
- OTLP endpoint `http://host.docker.internal:4318/v1/traces`

Alloy receiver 는 `0.0.0.0:4318`/`4317` 로 bind 해 호스트 게이트웨이로 들어온 걸 받는다.
외부 노출은 SG 가 차단하므로 `0.0.0.0` bind 가 안전하다.

## 주입 env

`provision-alloy.sh` 가 컨테이너에 `-e` 로 주입한다(자격증명은 인자가 아니라 env — ps 노출 방지).

| env | 용도 |
|---|---|
| `ENVIRONMENT` | environment / deployment.environment 라벨 |
| `PIKI_BOX` | box 라벨(박스 주인 서비스) |
| `GRAFANA_METRICS_URL` / `GRAFANA_METRICS_USER` | 메트릭 remote_write endpoint·계정 |
| `GRAFANA_LOGS_URL` / `GRAFANA_LOGS_USER` | 로그 loki.write endpoint·계정 |
| `GRAFANA_TRACES_URL` / `GRAFANA_TRACES_USER` | 트레이스 otlphttp endpoint·계정 |
| `GRAFANA_CLOUD_TOKEN` | 메트릭·로그·트레이스 공유 토큰(각 write scope 포함) |

### 자격의 정본과 회전

**GRAFANA_* 값의 정본은 SSM 공유 경로 `/piki/observability/grafana-*` 하나다** (SecureString,
kebab-case: `grafana-metrics-url` 등 7건). 세 서비스 박스의 프로비저닝이 전부 이 경로를 읽는다 —
core 는 `provision-runtime.sh`, extractor·renderer 는 각자의 `provision-observability.sh`.
각 박스 인스턴스 롤이 이 경로의 `ssm:GetParameter` 를 갖는다 (각 repo terraform).
GH secrets·서비스별 SSM 사본은 폐기됐다 (TeamPiKi/core#771).

**토큰 회전 절차** (Grafana Cloud 콘솔에서 새 토큰 발급 후):

1. `aws ssm put-parameter --name /piki/observability/grafana-cloud-token --type SecureString --overwrite --value file://<값 파일>` — 한 곳이 끝.
2. 각 박스에서 Alloy 재프로비저닝: core 는 다음 배포가 자동 수행, extractor·renderer 는 박스에서 `provision-observability.sh` 재실행 (또는 SSM run-command).
3. 확인: 각 박스 `curl -s localhost:12345/metrics | grep -E "prometheus_remote_write.*failed|loki_write_dropped"` 가 0, Grafana Explore 에 신규 데이터 유입.

## 버전 핀

- 수집기 이미지는 `grafana/alloy:v1.16.1` 로 고정한다.
- **버전 핀의 SSOT 는 `provision-alloy.sh` 의 `--version` default** 다. 문서·config 에 버전
  숫자를 중복해 박지 않는다.
- provision-alloy.sh 는 기동 **전에** 같은 버전 이미지로 `validate` 게이트를 돌린다 — 잘못된
  config 로 산 수집기를 죽이지 않는다.

## 이관 메모

core 박스의 현행 Alloy config(`core/infra/alloy/config.alloy`)에는 이 공통 블록으로 대체되는
두 가지가 있다:

- **`EXTRACTOR_METRICS_TARGET` 크로스박스 scrape** — prod 에서 core 박스 Alloy 가 extractor
  박스를 크로스 scrape 하던 방식. "수집기는 박스를 따라간다" 원칙에 따라 extractor 박스의 자기
  Alloy 가 걷는 것으로 대체된다.
- **`team3-(blue|green)` 컨테이너명 regex** — 서비스 열거 방식. label opt-in(`piki.observe`)으로 대체.

둘 다 core 가 이 블록을 채택하는 시점에 폐기된다.
