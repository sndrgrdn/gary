#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

RUNS="${RUNS:-5}"
UNTRACED="${UNTRACED:-s1-idle s2-busy-100 s2-busy-500 s2-busy-1000 s3-first-1000 s4-static s4-loops s4-shader s5-small s5-large}"
TRACED="${TRACED:-s2-busy-100 s2-busy-500 s2-busy-1000 s3-first-1000 s5-small s5-large}"
BASE="${BASE:-s2-busy-100 s5-small}"
BASE_APP="${BASE_APP:-tmp/base/build/Gary.app}"
OUT="${OUT:-tmp/bench/baseline-$(date +%Y%m%d-%H%M%S).jsonl}"
mkdir -p tmp/bin tmp/bench
swiftc -O -o tmp/bin/meter scripts/bench/meter.swift
swiftc -O -o tmp/bin/windows scripts/bench/windows.swift

bench() {
    echo "run=$run $*"
    /usr/bin/lockf -k /tmp/gary-live.lock python3 scripts/bench/render.py run "$@"
}

for run in $(seq "$RUNS"); do
    for case in $UNTRACED; do bench "$case" "$OUT"; done
    for case in $TRACED; do bench "$case" "$OUT" --trace; done
    if [[ -d "$BASE_APP" ]]; then
        for case in $BASE; do BENCH_APP="$BASE_APP" bench "$case" "$OUT"; done
    fi
done
python3 scripts/bench/render.py report "$OUT"
