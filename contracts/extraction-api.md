# 추출 API 계약

core(호출자)와 extractor(추출 서비스) 사이의 계약. 구현이 이 문서와 어긋나면 구현을 고친다.
내부망 전용이고 인증은 없다(보안그룹 격리).

| 정본 | 맡는 것 |
|---|---|
| `contracts/extraction.proto` | 요청·응답의 모양, 필드와 code 의 의미, code 분류(disposition·bucket) |
| 이 문서 | 모양으로 표현되지 않는 동작 규칙과 그 근거 |

와이어는 protobuf 의 JSON 매핑이다(필드명 lowerCamelCase, enum 은 이름 문자열).

## 0. 설계 불변식

- Extractor 는 무상태다. 같은 요청이 중복 도착해도 대가는 LLM 비용 한 번뿐이다.
- 재시도·내구성·상태 전이는 호출자의 책임이다. Extractor 는 단건 시도 1회에만 답한다.
- 에스컬레이션(plain fetch 에서 헤드리스 브라우저로)은 Extractor 내부 관심사라 응답에 드러나지 않는다.
  브라우저를 여는 데는 허락이 필요 없다.
- 정책 수용 지점은 요청의 `authorized` 하나다. 판정 원장은 호출자이고 Extractor 는 판단 없이 전달한다.

## 1. 응답 3갈래

| Extractor 응답 | 의미 | core 전이 |
|---|---|---|
| 2xx + 추출 결과 | 성공 | `markReady` |
| 422 + `{code}` | 확정 실패 | 즉시 `markFailed` |
| 그 외 전부 (5xx·타임아웃·연결 실패·미지의 상태) | 일시 실패 | PROCESSING 유지 후 recover 재시도 (attempt 상한 2) |

- 전이 판정은 HTTP status 만 쓴다. `code` 는 관측용이고, 모르는 code 여도 422 면 확정 실패다.
- 분류할 수 없는 실패는 전부 일시로 떨어진다(fail-safe). 재시도 비용은 호출자의 attempt 상한이 바운드한다.
- code 의 `disposition` 옵션과 1:1 이다. `PERMANENT` 는 422, `TRANSIENT` 는 502.

## 2. 엔드포인트

### POST `/internal/extractions/link`

- 지정 모델이 404 면 기본 모델로 대체하고 추출을 이어간다(가용성 우선). 응답 모양은 같고, 대체 사실은
  warn 로그와 `gemini.model.fallback` 카운터에만 남는다.
- 400·5xx·timeout 은 대체하지 않는다. 400 은 요청 쪽 결함일 수 있어 대체가 버그를 덮고, 나머지는 모델을
  바꿔도 풀리지 않는다.
- 헤더 `X-Correlation-Id`(선택)는 호출자의 item_snapshot id 다. 로그 상관용이고 동작에 영향 없다.

### POST `/internal/extractions/image`

- 처리 순서는 `download(bucket, key)`, OCR 추출, bbox 크롭(불가 시 원본), `upload(bucket, items/{uuid}.{ext})` 다.
  업로드한 결과의 public URL 이 `imageUrl` 이다.
- `imageUrl` 은 항상 채워진다(크롭에 실패해도 원본이 올라간다). 이름·가격을 못 뽑으면 그 둘만 빈 200 이다.
- 업로드 확장자·content-type 은 결과물을 따른다. 크롭했으면 png, 크롭 불가 포맷(HEIC·WebP·HEIF)은 원본 그대로다.
- 모델 대체 규칙은 link 와 같다.

### POST `/internal/models/probe`

백오피스가 모델을 저장하기 전에 그 모델이 그 경로에서 실제로 동작하는지 묻는다.

- 판정은 메타 조회가 아니라 그 경로의 실제 generateContent 호출이다. 존재 확인만으로는 요청 스키마
  비호환(400)을 못 거르는데, 400 은 추출 경로에서 대체 대상이 아니라 파싱 전건 실패다.
- 대체 없이 지정 모델만 친다. 대체하면 없는 모델도 기본 모델이 대신 통과시켜 게이트가 무력화된다.
- 아는 모델 목록을 코드에 두지 않는다. 목록을 두면 새 모델마다 Extractor 배포가 필요하다.
- 일시 실패를 거절(422)로 바꾸지 않는다. 외부가 잠깐 흔들린 사이에 멀쩡한 모델의 저장이 막힌다.

| status | 의미 | 호출자의 처리 |
|---|---|---|
| `200` (body 없음) | 이 경로에서 동작하는 모델 | 저장 허용 |
| `422` + code | 확정 거절 | 저장 거부 + 사유 표시 |
| `400` | 필수 필드 누락·모르는 target | 호출자 구현 버그. 재시도해도 같다 |
| 그 외(502) | 외부 사정으로 확인 불가 | 저장 거부 + 재시도 안내 |

## 3. bucket (확정 실패의 운영 분류)

값과 뜻의 정본은 `extraction.proto` 의 `Bucket` enum 이다. 확정 실패에만 붙고, 일시 실패는 recover 가
종결 시 집계한다.

## 4. 타임아웃 예산

| 층 | 값 | 근거 |
|---|---|---|
| core stale 판정 | 60s | `ItemParsingScheduler.STALE_TIMEOUT` |
| core -> Extractor HTTP read | 55s (connect 2s) | stale 미만. recover 의 유령 중복 발주 방지. link·image 공용 |
| Extractor 내부 합계 (link) | 약 50s | 아래 합 + 여유 |
| 대상 몰 fetch (link) | connect 5s / read 15s | |
| 헤드리스 render (link) | connect 2s / read 20s | 실측 전형 1.6-5.5s 대비 약 4배 여유. headless-first 최악(connect 2 + render 20 + LLM 30 = 약 52s)이 호출자 read 55s 안에 들도록 상한 |
| Gemini | read 30s | link LLM fallback·image OCR 동일 |
| Extractor 내부 합계 (image) | 약 40s | S3 download + Gemini OCR 30s + crop + 결과 upload |

- 안쪽 예산은 항상 바깥보다 작아야 한다. Extractor 내부 값을 늘릴 땐 이 표와 core read 타임아웃을 함께 재검증한다.
- 예외로 에스컬레이션 경로(plain 실패 후 headless)의 최악 스택은 55s 를 넘을 수 있다. redirect hop 마다
  타임아웃이 새로 적용돼 fetch 단독 이론 최악이 약 120s 이고, render 22s 와 LLM 30s 를 더하면 약 172s 다.
  넘치면 호출자가 일시 실패로 처리해 재시도하고, Extractor 가 무상태라 중복 발주는 안전하다.
  55s 안에 넣으려면 render 예산이 5s 이하가 돼 recall 을 잃는다(의도된 트레이드오프).

## 5. 진화 규칙

- additive-only. 필드·code 추가는 자유, 제거·의미 변경·타입 변경은 금지다(필요하면 새 경로).
  모양 위반은 CI 의 `buf breaking` 이 막는다.
- code 는 proto enum 에 분류 옵션과 함께 더한다. 소비 repo 의 메타 테스트가 자기 매핑과 대조한다.
- 배포 순서는 Extractor 먼저, core 나중.
- 호출자는 모르는 응답 필드·code 를 무시한다(tolerant reader).

## 6. 관측

- W3C `traceparent` 헤더를 수용해 core 의 `item.parse` span 아래로 연결된다.
- 추출 메트릭(`product.extract{via,reason}`·`product.extract.escalation{outcome,category}`)은 Extractor 가
  소유한다(`contracts/observability.md`).
