#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

read -r -a apps <<< "${APPS:?set APPS to the Gary.app builds to compare, before first}"
RUNS="${RUNS:-5}"
CASES="${CASES:-s2-busy-100 s5-large}"
OUT="${OUT:-tmp/bench/ab-$(date +%Y%m%d-%H%M%S).jsonl}"
mkdir -p tmp/bin tmp/bench
swiftc -O -o tmp/bin/meter scripts/bench/meter.swift
swiftc -O -o tmp/bin/windows scripts/bench/windows.swift

for run in $(seq "$RUNS"); do
    shift_by=$(((run - 1) % ${#apps[@]}))
    order=("${apps[@]:shift_by}" "${apps[@]:0:shift_by}")
    for case in $CASES; do
        for app in "${order[@]}"; do
            echo "run=$run $case $app"
            BENCH_APP="$app" /usr/bin/lockf -k /tmp/gary-live.lock python3 scripts/bench/render.py run "$case" "$OUT" "$@"
        done
    done
done
python3 scripts/bench/render.py report "$OUT"
