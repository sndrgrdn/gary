#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

RUNS="${RUNS:-3}"
SECONDS_PER_RUN="${SECONDS_PER_RUN:-60}"
mkdir -p tmp/bin
swiftc -O -o tmp/bin/meter scripts/bench/meter.swift
APP=build/Gary.app
SKETCHYBAR=$(pgrep -x sketchybar | head -1)

for run in $(seq "$RUNS"); do
    pkill -f "$APP/Contents/MacOS/gary" || true
    while pgrep -f "$APP/Contents/MacOS/gary" > /dev/null; do sleep 0.2; done
    open "$APP"
    sleep 5
    GARY=$(pgrep -f "$APP/Contents/MacOS/gary app$")
    echo "run=$run $(tmp/bin/meter "$SECONDS_PER_RUN" "gary=$GARY" "sketchybar=$SKETCHYBAR" | tr '\n' ' ')"
    footprint -p "$GARY" 2>/dev/null | grep -E "^\s*Footprint|phys_footprint:" | head -1 | sed "s/^/run=$run gary footprint tool: /"
done
