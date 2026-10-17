#!/usr/bin/env bash
#
# contracts/internal-ranges.txt 형식 검사. 소비자(서버 벽·extractor·renderer)가 각자 파싱하므로
# 한쪽만 받아들이는 줄이 정본에 들어오지 않게 여기서 막는다.
#
# 실행: ./contracts/internal-ranges.test.sh [internal-ranges.txt 경로]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${1:-$SCRIPT_DIR/internal-ranges.txt}"

python3 -I - "$FILE" <<'PY'
import ipaddress
import sys

failures = []
networks = []
for number, raw in enumerate(open(sys.argv[1], encoding="utf-8"), start=1):
    entry = raw.split("#", 1)[0].strip()
    if not entry:
        continue
    try:
        # strict: 호스트 비트가 남은 줄(10.0.0.1/8)은 소비자마다 다르게 읽힐 수 있다.
        network = ipaddress.ip_network(entry, strict=True)
    except ValueError as e:
        failures.append(f"{number}행 {entry!r}: {e}")
        continue
    if str(network) != entry:
        failures.append(f"{number}행 {entry!r}: 정규형 {network} 으로 적을 것")
    networks.append((number, network))

for i, (n1, a) in enumerate(networks):
    for n2, b in networks[i + 1:]:
        if a.version == b.version and a.overlaps(b):
            failures.append(f"{n1}행 {a} 와 {n2}행 {b} 가 겹침")

for version in (4, 6):
    if not any(n.version == version for _, n in networks):
        failures.append(f"IPv{version} 대역이 하나도 없음")

for failure in failures:
    print(f"FAIL: {failure}", file=sys.stderr)
if failures:
    sys.exit(1)
print(f"OK: {len(networks)}개 대역")
PY
