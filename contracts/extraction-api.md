# 추출 API 계약

core(호출자)와 extractor(추출 서비스) 사이의 API 계약. 구현(springdoc `/v3/api-docs`)이나 각 repo
문서와 어긋나면 **이 문서를 기준으로 구현을 고친다.**

소비자는 core 의 파싱 워커 하나뿐이다. 공개 API 가 아니며 보안그룹으로 내부망에서만 접근한다(별도 인증 없음).

**code 목록의 정본은 `contracts/extraction-error-codes.yaml`** 이다. 이 문서는 각 code 가 무엇을
뜻하는지를 맡고, 목록·disposition·bucket 은 그 파일이 갖는다(이중 관리 방지). 카탈로그에 있는데
아래 표에 없는 code 가 보이면 카탈로그가 옳다 — 설명을 여기 보탠다.

> extractor repo 의 `docs/api-contract.md` 에서 이관했다. 정본이 소비자 한쪽에 있으면 다른 쪽이
> 따라가지 않아도 정본은 멀쩡해 어긋남이 조용하다(TeamPiKi/infra#41).

## 0. 설계 불변식

- Extractor 는 **무상태**다. DB 없음, 호출 간 상태 없음. 같은 요청이 중복 도착해도 상태 오염이 없다
  (중복의 대가는 LLM 비용 한 번뿐). Extractor 에 상태를 넣고 싶어지면 설계 경고 신호다.
- 재시도·내구성·상태 전이는 전부 호출자(core 의 `item_snapshots` 작업 큐)의 책임이다. Extractor 는
  "단건 시도 1회"에만 답한다.
- 에스컬레이션(plain fetch -> 헤드리스 브라우저)은 Extractor 내부 관심사다. 응답 계약에 드러나지 않고
  호출자는 어떤 fetch 전략이 쓰였는지 모른다. **브라우저를 여는 것 자체에는 허락이 필요 없다** — 우리는
  신원을 UA 로 밝히고 우리 IP 로 가며, 막히면 막힌 대로 보고한다.
- 단 "이 대상이 플랫폼의 명시적 허락을 받았는가"의 **판정**은 호출자(DB·백오피스)가 주인이라, 요청 필드
  `authorized` 로 받는다(2장) — 무상태 불변식을 지키는 선에서의 유일한 정책 수용 지점이다. 이 값이 여는
  것은 렌더 서비스의 우회 수단(지문 보정·프록시)뿐이고, Extractor 는 판단 없이 전달만 한다.

## 1. 응답 3갈래 (전이 규약)

| Extractor 응답 | 의미 | core 전이 |
|---|---|---|
| 2xx + 추출 결과 | 성공 | `markReady` |
| 422 + `{code}` | 확정 실패 (재시도 무의미) | 즉시 `markFailed` |
| 그 외 전부 (5xx·타임아웃·연결 실패·미지의 상태) | 일시 실패 | PROCESSING 유지 -> recover 재시도 (attempt 상한 2) |

- **전이 판정은 HTTP status 만 사용한다.** 422 body 의 `code` 는 관측·디버깅용이며, 호출자가 모르는
  code 여도 422 면 확정 실패로 처리한다(tolerant reader).
- **fail-safe 원칙**: 분류할 수 없는 실패는 전부 "일시"로 떨어진다. 확정 실패 신호는 422 하나뿐이다.
  호출자의 attempt 상한이 재시도 비용을 바운드한다.
- 카탈로그의 `disposition` 이 이 갈래와 1:1 이다 — `permanent` 는 422 로, `transient` 는 502 로 나간다.
  Extractor 쪽 런타임 정본은 각 예외 팩토리의 `permanent` 플래그이며, 카탈로그는 그 계약 표기다.

## 2. 엔드포인트

### POST `/internal/extractions/link` — URL 상품 추출

요청:

```json
{ "url": "https://www.musinsa.com/products/12345", "authorized": false, "model": "gemini-3.1-flash-lite" }
```

- `url` (필수): https 스킴의 상품 페이지 URL. 형식·스킴·미지원 플랫폼의 동기 검증은 호출자(core 등록
  경계)가 이미 끝냈다는 전제이나, Extractor 도 자기 경계에서 방어 검증한다(다층 방어).
- `authorized` (선택, 기본 false): 이 대상이 플랫폼의 명시적 허락을 받았는가. 판정의 단일 진실은 호출자
  DB(백오피스)에 있고 무상태인 Extractor 는 요청 단위로만 받아 렌더 서비스까지 전달한다. **추출 경로는 이
  값과 무관하게 같다** — 정적 fetch 로 시작해 필요하면 브라우저로 승격하는 흐름은 항상 동일하다. 이 값이
  true 일 때 열리는 것은 렌더 서비스의 우회 수단(지문 보정·프록시)뿐이다. 생략·null 은 false(허락 없음)로
  정규화되는 fail-safe 라, 이 필드를 모르는 구버전 호출자의 요청은 안전한 쪽으로만 어긋난다.
- `model` (선택): 이 요청의 LLM 추출에 쓸 모델. authorized 와 같은 성질이다 — 정책의 단일 진실은
  호출자 DB(백오피스)에 있고 Extractor 는 요청 단위로만 받는다. **요청 단위로 받는 이유**: Extractor
  박스 한 대를 여러 환경이 공유하므로, 모델을 Extractor 환경변수로 잡으면 dev 에서 바꾼 것이 prod
  파싱까지 덮는다. 생략·null·빈 문자열이면 Extractor 의 기본 모델을 쓴다 — 구버전 호출자의 요청이
  그대로 동작하므로 배포 순서 무관.
- **지정 모델이 404 면 기본 모델로 대체하고 추출을 이어간다.** 등록 당시 유효했던 모델이 폐기돼 사라지는
  경우가 있고, 그때 파싱 전체가 죽는 것보다 기본 모델로 이어가는 편이 낫다(가용성 우선). 대체가 일어나도
  응답 모양은 같으며, 발생 사실은 Extractor 의 warn 로그와 `gemini.model.fallback` 카운터에만 남는다.
  **400·5xx·timeout 은 대체하지 않는다** — 400 은 요청 body 쪽 결함일 수 있어 대체로 덮으면 버그가
  묻히고, 나머지는 모델을 바꾼다고 풀리는 실패가 아니다.
- 헤더 `X-Correlation-Id` (선택): 호출자의 item_snapshot id. 로그·trace 상관용이며 동작에 영향 없다.

성공 200:

```json
{
  "name": "나이키 에어포스",
  "imageUrl": "https://...",
  "currentPrice": 99000,
  "currency": "KRW",
  "finalUrl": "https://www.musinsa.com/products/6760200",
  "method": "STRUCTURED"
}
```

- `finalUrl`: 리다이렉트를 따라간 최종 페이지 URL. 호출자가 상품 정체성(canonical) 정규화의 입력으로
  쓴다 — 단축링크(onelink 등)는 경로가 불투명 코드라 이 값 없이 같은 상품을 알아볼 수 없다. link 경로는
  항상 채워지고 image 경로는 null. 호출자는 이 값이 없으면(구버전 Extractor) canonical 확정을
  건너뛴다 — 배포 순서 무관.
- `method`: 값을 만든 추출 경로. `STRUCTURED`(구조화 파싱, 결정론적) | `LLM`(Gemini — URL fallback·image
  경로). 호출자가 snapshot 출처(SERVER/SERVER_LLM)를 구분 저장하는 근거다. tolerant reader 라 모르는
  값이 와도 무시하고 출처 미기록으로 둔다.
- **값 필드는 전부 nullable 이고, Extractor 는 "하나라도 채웠다" 만 보장한다.** `name`(non-blank)·
  `imageUrl`·`currentPrice` 중 **하나도 못 채웠을 때만** 422(`UNTRUSTWORTHY_VALUE`)이고, 일부만 채운
  결과는 채운 값 그대로 200 이다. `currency` 는 단독으로 "채웠다" 의 근거가 되지 못한다(READY 필수가
  아니라서다).
- 세 필드는 여전히 core 의 READY 불변식(name·price·imageUrl·extractedAt, extractedAt 은 호출자가 전이
  시점에 채움)과 같은 집합이지만, **그 집합을 채우는 책임이 Extractor 단독에서 "Extractor 가 채운 만큼 +
  사용자가 나머지" 로 갈렸다.** 호출자는 부분값을 `INCOMPLETE` 상태로 받아 사용자 입력으로 완성한다
  (TeamPiKi/core#944). 사진에 가격이 박혀 있지 않은 것은 정상 입력이라, 셋을 다 요구하면 "쇼핑몰 화면
  캡처" 만 통과하는 계약이 되기 때문이다.
- 호출자의 엔티티 불변식은 최후 보루로 유지된다 — READY 로 전이하는 값은 여전히 세 필드를 다 요구한다.

확정 실패 422:

```json
{ "code": "NOT_PRODUCT_PAGE" }
```

일시 실패는 Extractor 가 502 를 쓴다(호출자는 status 구분 없이 "2xx/422 외 전부"로 처리). body 에 code 를
실을 수 있으나 호출자는 읽지 않는다.

### POST `/internal/extractions/image` — S3 이미지 OCR 추출 + 크롭

요청:

```json
{ "bucket": "dev-piki-images-<ACCOUNT_ID>", "key": "items/raw/0f3a....png", "model": "gemini-3.1-flash-lite" }
```

- **`bucket` 을 요청이 준다** — Extractor 는 여러 환경의 트래픽을 받고 각 환경의 이미지 버킷이 다르다.
  버킷을 고정 config 로 두지 않고 요청별로 받아 버킷 무관하게 동작한다. IAM 은 이미지 버킷 와일드카드로
  전 환경을 덮는다.
- `key`: raw 원본 object key(등록 시 core 가 `items/raw/{uuid}.{ext}` 로 durable 적재한 것).
- `model` (선택): link 와 같은 규약이되 **축이 갈린다** — 이미지 경로에는 이미지용 지정만 온다. 링크는
  텍스트와 JSON 스키마를 다루고 이미지는 보는 능력이 필요해, 한쪽에 맞는 모델이 다른 쪽에 맞지 않을 수
  있기 때문이다. 대체 규칙(404 만 기본 모델로)도 link 와 같다.

성공 200 은 link 경로와 **동일한 필드 모양**이다(`finalUrl` 만 null). Extractor 가
`download(bucket,key) -> OCR 추출 -> bbox 크롭(불가 시 원본) -> upload(bucket, items/{uuid}.{ext})` 를
다 하고, 업로드한 결과 이미지의 public URL 을 `imageUrl` 로 돌려준다.

- **`imageUrl` 은 이 경로에서 항상 non-null 이다** — 업로드 결과라 크롭에 실패해도 원본이 올라간다.
  따라서 이미지 경로가 값 0개로 422 가 되는 일은 사실상 없고, 이름·가격을 못 뽑으면 그 둘만 빈 200 이다.
- **업로드 확장자·content-type 은 결과물을 따른다.** 크롭이 실제로 일어났으면 `png`/`image/png` 이고,
  크롭 불가 포맷(HEIC·WebP·HEIF 는 자바 ImageIO 에 디코더가 없다)이라 원본을 그대로 올리면 **원본의
  확장자·content-type** 을 쓴다. 예전에는 둘 다 png 로 고정해 HEIC 바이트가 png 로 위장 저장됐고,
  브라우저 대부분이 그 파일을 렌더링하지 못했다(TeamPiKi/extractor#35).
- 그 밖의 값 필드 규약은 link 와 같다(하나라도 채우면 200, 하나도 못 채우면 422).

이 경로에만 나오는 code: `IMAGE_UNSUPPORTED`(확정), `STORAGE_ERROR`(일시). 이미지에서 상품 식별 실패는
link 와 같은 `UNTRUSTWORTHY_VALUE` 를 재사용한다.

### POST `/internal/models/probe` — 모델 유효성 프로브

호출자가 백오피스에서 모델을 저장하기 전에 "이 모델이 이 경로에서 실제로 동작하는가"를 묻는다.
저장 게이트가 이 응답으로 갈린다.

요청:

```json
{ "model": "gemini-3.1-flash-lite", "target": "LINK" }
```

- `model` (필수): 확인할 모델 이름. 아는 모델 목록을 Extractor 코드에 박지 않는 것이 이 엔드포인트의
  존재 이유다 — allowlist 를 박으면 새 모델이 나올 때마다 Extractor 배포가 필요해져 "배포 없이 바꾼다"는
  목적이 무너진다. 유효성은 런타임 실측이 판정한다.
- `target` (필수): `LINK` 또는 `IMAGE`. 두 경로는 요청 wire 가 달라(link 는 `responseJsonSchema` 에
  소문자 type, image 는 `responseSchema` 에 대문자 enum type 과 thinkingConfig) 한쪽에서 통과한 모델이
  다른 쪽에서 400 일 수 있다.

**판정은 메타 조회가 아니라 그 경로의 실제 generateContent 호출이다.** 모델 존재만 확인하면 요청 스키마
비호환(400)을 못 거르는데, 400 은 추출 경로에서 대체 대상이 아니라 곧 파싱 전건 실패다. 게이트가 정작
막아야 할 실패를 놓치게 된다. 최소 입력을 쓰되 wire 모양은 운영과 같다.

**대체 없이 지정 모델만 친다.** 추출 경로처럼 대체하면 없는 모델을 넣어도 기본 모델이 대신 성공해
프로브가 통과하고, 저장 게이트가 무력화된다.

| status | 의미 | 호출자의 처리 |
|---|---|---|
| `200` (body 없음) | 이 경로에서 동작하는 모델 | 저장 허용 |
| `422` + code | 확정 거절 | 저장 거부 + 사유 표시 |
| `400` | 필수 필드 누락·모르는 target | 호출자 구현 버그. 재시도해도 같다 |
| 그 외(502) | 외부 사정으로 확인 불가 | 저장 거부 + 재시도 안내 |

**일시 실패를 거절로 바꾸지 않는다.** 5xx·429·타임아웃을 422 로 내보내면 외부가 잠깐 흔들린 사이에
멀쩡한 모델이 "쓸 수 없는 모델"로 판정돼 저장이 막힌다.

## 3. code 의 의미

목록·`disposition`·`bucket` 의 정본은 `contracts/extraction-error-codes.yaml` 이다. 아래는 각 code 가
무엇을 가리키는지에 대한 설명이다.

| code | 의미 |
|---|---|
| `NOT_PRODUCT_PAGE` | 읽긴 했는데 상품 페이지가 아니다 |
| `INVALID_URL` | url 형식·스킴 위반. 정상 흐름에선 호출자가 동기 검증해 도달하지 않는다(방어) |
| `EMPTY_SHELL` | fetch 는 2xx 지만 본문이 데이터 없는 CSR 셸(파싱 no-data 를 재분류). 헤드리스 에스컬레이션 대상이라, 헤드리스가 켜진 구성에선 헤드리스 결과가 대신 응답된다 |
| `NO_EXTRACTABLE_CONTENT` | 본문에 가시 텍스트도 데이터 script 도 없어 LLM 을 부르지 않고 확정(빈 셸 환각 차단). plain 경로는 EMPTY_SHELL 재분류가 선행하므로 사실상 헤드리스 렌더 결과까지 셸일 때 나온다 |
| `FETCH_CLIENT_ERROR` | 대상 4xx (403 차단·404·429 등). 봇 방어의 클로킹일 수 있다 |
| `PERMANENT_UPSTREAM` | 대상 500/501 등 결정론적 재실패 5xx. 대형 몰은 상시 가용이라 대개 진짜 장애가 아니라 봇 방어다 |
| `UNTRUSTWORTHY_VALUE` | 추출값이 범위·상식 위반이거나, 값을 하나도 못 채웠다(일부만 채운 결과는 실패가 아니라 200) |
| `LLM_INVALID_RESPONSE` | 재시도해도 같은 LLM 실패(4xx·파싱 불가·정책 거부로 text part 없음) |
| `IMAGE_UNSUPPORTED` | 이미지 경로 전용 — 빈 이미지·미지원 MIME |
| `BLOCKED_HOST` | 사설·메타데이터·loopback 으로 resolve 되는 host 를 SSRF 로 차단. 헤드리스 에스컬레이션 절대 금지 대상 |
| `TOO_MANY_REDIRECTS` | redirect 가 hop 상한을 넘어 무한·체인 의심 |
| `MALFORMED_REDIRECT` | 3xx 를 주면서 Location 이 없거나 깨진 비정상 redirect |
| `UPSTREAM_ERROR` | 대상 몰 502/503/504·연결 실패·빈 body |
| `LLM_UPSTREAM` | Gemini 5xx/429/408/transport 오류 |
| `HEADLESS_BLOCKED` | 실제 브라우저로도 차단(verdict=BLOCK). 렌더 서비스의 BLOCK 판정에는 429·일시 챌린지가 섞여 영구/일시를 못 가르므로 fail-safe 로 일시다. `HEADLESS_UPSTREAM` 과 code 를 나눈 이유는 대응이 달라서다(차단 추세 = 정책 후보, 장애 추세 = 렌더 박스 점검) |
| `HEADLESS_UPSTREAM` | 렌더 서비스 연결 실패·타임아웃·빈 렌더(verdict=EMPTY)·브라우저 오류(verdict=ERROR)·압축 해제 실패. 렌더 서비스는 파싱하지 않으므로 HTML 이 있으면 verdict 와 무관하게 Extractor 파이프라인이 추출을 이어간다 |
| `STORAGE_ERROR` | 이미지 경로 전용 — S3 read/write 실패 |
| `MODEL_NOT_FOUND` | 프로브 전용 — 그런 모델이 없다(Gemini 404). 오타이거나 폐기돼 사라진 모델 |
| `MODEL_INCOMPATIBLE` | 프로브 전용 — 모델은 있으나 그 경로의 요청을 처리하지 못한다. 요청 스키마 비호환(400)·결제 티어 제한, 200 을 주면서 응답 스키마를 못 맞춘 경우까지 포함 |

### bucket (확정 실패의 운영 분류)

`bucket` 은 "이 실패를 우리가 어떻게 받아들이나"의 축이다. 확정 실패에만 붙는다 — 일시 실패는 호출자가
세지 않고 recover 가 종결 시 집계한다.

| bucket | 뜻 | 운영이 보는 것 |
|---|---|---|
| `not_product` | 애초에 상품 링크가 아니다 | 사용자 입력 문제. 늘어도 서비스 결함이 아니다 |
| `unreadable` | 상품 페이지지만 우리가 읽어내지 못했다 | 렌더·에스컬레이션 커버리지 문제 |
| `blocked` | 대상이 우리를 막았다 | 플랫폼 정책·차단 대응 대상 |
| `extract_quality` | 읽었으나 값을 신뢰할 수 없다 | 추출 품질(프롬프트·모델·파서) 문제 |
| `internal_error` | 우리 쪽 방어·비정상 상태로 끝났다 | 정상 요청이 여기 쌓이면 우리 버그 신호 |

분류를 각 repo 자유로 두지 않고 카탈로그가 소유하는 이유: "extractor 는 차단으로 보는데 core 는 상품
아님으로 센다" 같은 의미 어긋남은 기계가 못 잡고, 지표를 조용히 거짓말하게 만든다.

## 4. 타임아웃 예산

| 층 | 값 | 근거 |
|---|---|---|
| core stale 판정 | 60s | `ItemParsingScheduler.STALE_TIMEOUT` |
| core -> Extractor HTTP read | 55s (connect 2s) | stale 미만 — recover 의 유령 중복 발주 방지. link·image 공용 |
| Extractor 내부 합계 (link) | 약 50s | 아래 합 + 여유 |
| 대상 몰 fetch (link) | connect 5s / read 15s | |
| 헤드리스 render (link) | connect 2s / read 20s | 실측 전형 1.6-5.5s(프록시 포함) 대비 약 4배 여유. headless-first 최악(connect 2 + render 20 + LLM 30 = 약 52s)이 호출자 read 55s 안에 들도록 상한 |
| Gemini | read 30s | link LLM fallback·image OCR 동일 |
| Gemini 무료 티어 시도 | read 10s | 무료 키가 설정된 경우에만 선행하는 시도. 유료와 같은 상한을 주면 두 호출이 직렬로 쌓여 image 합계가 호출자 read 를 크게 넘는다. 무료의 주 실패(429·503)는 1초 안에 오므로 짧게 잡아도 잃는 것이 적다 |
| Extractor 내부 합계 (image) | 약 40s | S3 download + Gemini OCR 30s + crop + 결과 upload. S3 는 동일 리전이라 수 초 |

**안쪽 예산은 항상 바깥보다 작아야 한다.** link 와 image 가 호출자 read 55s 를 공유하므로, 어느 경로든
Extractor 내부 값을 늘릴 땐 이 표를 갱신하고 core 쪽 read 타임아웃과 함께 재검증한다.

예외적으로 **에스컬레이션 경로(plain 실패 -> headless)의 최악 스택**은 호출자 read 55s 를 넘을 수 있다.
plain fetch 는 수동 redirect 추적(hop 상한 3 = 요청 최대 4회)마다 connect/read 타임아웃이 **새로 적용**되므로
fetch 단독의 이론 최악이 이미 약 88s 다(헤드리스 이전부터 있던 특성). 여기에 render 22s + LLM 30s 가
얹히면 이론 최악 약 140s — 단, 각 단이 전부 타임아웃까지 끄는 경우는 실측상 없다시피 하고(차단은 대개
즉시 4xx/5xx 로 떨어져 fetch 가 빨리 실패한다), 넘치면 호출자는 read 타임아웃 -> 일시 실패로 처리해
recover 가 재시도한다. 그 사이 Extractor 가 계속 돌아 중복 발주가 겹쳐도 Extractor 는 무상태라
안전하고(0장), attempt 상한 2 가 총비용을 바운드한다. 이 스택을 55s 안에 구겨 넣으려면 render 예산이
실측 대비 무의미하게 얇아져(5s 이하) recall 을 잃는다 — 의도된 트레이드오프다.

**Gemini 무료 티어 폴백도 같은 성격의 초과를 만든다.** 무료 키가 설정되면 LLM 단이 최악
(connect 5 + read 10) + (connect 5 + read 30) = 50s 가 되어 image 합계가 약 60s 로 호출자 read 55s 를
넘을 수 있다. 다만 이 최악은 무료가 10s 를 꽉 채워 무응답이고 **동시에** 유료가 30s 를 꽉 채워야
성립하며, 무료의 실제 실패는 대개 즉시 오는 429·503 이라 실측상 도달하지 않는다. 넘치면 위와 같이
호출자 read 타임아웃 -> 일시 실패 -> recover 재시도로 흡수되고 attempt 상한 2 가 총비용을 바운드한다.

무료 시도는 **비용이 아니라 지연만 늘린다** — 무료가 성공하면 과금이 없고, 실패하면 유료 1회로
무료 도입 전과 같다. 무료 키를 비우면 이 단이 통째로 사라져 표의 나머지가 그대로 성립한다.

## 5. 진화 규칙

- **additive-only**: 응답 필드 추가·422 code 추가는 자유. 필드 제거·의미 변경·타입 변경은 금지 —
  필요하면 새 경로로 분리한다.
- **code 를 더하거나 고칠 때는 카탈로그(`extraction-error-codes.yaml`)를 먼저 고친다.** 소비 repo 의
  메타 테스트가 카탈로그를 읽어 대조하므로, 구현만 고치면 그쪽이 빨간불이 된다 — 그게 이 배치의 목적이다.
- **배포 순서: Extractor 먼저, 소비자(core) 나중.**
- 호출자는 tolerant reader — 모르는 응답 필드·code 를 무시한다.

## 6. 관측

- W3C `traceparent` 헤더를 수용해 core 의 `item.parse` span 아래로 연결된다(micrometer tracing 기본 동작).
- 추출 메트릭(`product.extract{via,reason}`·`product.extract.escalation{outcome,category}`)은 Extractor 가
  소유하며, `application=piki-extractor` 라벨로 core 시계열과 구분된다(`contracts/observability.md`).
