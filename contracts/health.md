# 헬스체크 계약

세 서비스(PIKI-Server / PIKI-Extractor / PIKI-HeadlessBrowser)의 배포 직후
"새 컨테이너가 트래픽 받을 준비가 됐나"를 판정하는 공통 게이트.

## 계약

- 각 서비스는 헬스 경로에 대해 **준비되면 HTTP 200 을 반환**한다.
- 판정 기준은 **HTTP 200 하나**다. body 형식은 서비스 자유(200 자체가 신호).
  - 기동 중/비정상: non-200(4xx·5xx) 또는 연결 실패 -> "아직 준비 안 됨"으로 동일 취급, 재시도.
- 더 엄격히 보고 싶으면 `--expect-body` 마커로 200 + 본문 문자열을 함께 요구한다(선택).

## 공유 블록

`blocks/healthcheck.sh` 하나가 세 서비스를 다 처리한다.
경로·간격·횟수·타임아웃·본문 마커를 **전부 인자**로 받으므로, 서비스 차이는
블록 본문이 아니라 호출 인자로 흡수된다. 스크립트는 실행 위치 중립(SSH/SSM 무관).

## 서비스별 파라미터 (실측)

| 서비스 | 경로 | 200 body | 간격 | 횟수 | 총 대기 | 근거 |
|---|---|---|---|---|---|---|
| server | `/health` | `{"status":"ok"}` | 5s | 60 | 300s | `deploy.yml:563` — JVM+DB 기동 |
| extractor | `/actuator/health` | `{"status":"UP"}` | 5s | 24 | 120s | actuator 표준 — stateless JVM (제안값) |
| headless | `/health` | `{"ok":true,"proxy_loaded":…}` | 3s | 20 | 60s | `deploy_remote.sh` — 브라우저 프로세스 |

- **간격·횟수·총 대기는 서비스 기동 특성이라 일부러 다르게 둔다.** 계약이 통일하는 건
  "블록·판정 방식·경로 규약"이지 대기 시간이 아니다.
- extractor 값은 제안값이다(현재 in-repo 폴링 로직이 없어 외부 레이어가 정함).

## 경로 규약

- 신규/통일 방향은 `/health` 를 권장한다(server·headless 이미 준수).
- extractor 는 `/actuator/health` 다. 계약이 경로를 강제하지 않으므로(인자) 당장 통일
  대상은 아니고, 원하면 후속으로 `/health` alias 를 더해 수렴시킨다.

## 호출 예시 (서비스별)

```bash
# server (blue-green inactive 슬롯)
healthcheck.sh --url "http://localhost:${INACTIVE_PORT}/health" --interval 5 --attempts 60

# extractor
healthcheck.sh --url "http://localhost:8090/actuator/health" --interval 5 --attempts 24 \
               --expect-body '"status":"UP"'

# headless
healthcheck.sh --url "http://localhost:8000/health" --interval 3 --attempts 20 \
               --expect-body '"ok":true'
```
