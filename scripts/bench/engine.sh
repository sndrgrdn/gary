#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

read -r -a sides <<< "${REVS:?set REVS to the commits to compare, base first}"
RUNS="${RUNS:-5}"
SECONDS_PER_RUN="${SECONDS_PER_RUN:-60}"
OUT="${OUT:-tmp/bench/engine-$(date +%Y%m%d-%H%M%S).jsonl}"
toolchain="$(dirname "$(xcrun --find swift)")/.."
mkdir -p tmp/bench
read -r -a revs <<< "$(printf '%s\n' "${sides[@]%%:*}" | awk '!seen[$0]++' | tr '\n' ' ')"
for rev in "${revs[@]}"; do
    dir="tmp/bench/engine/$rev"
    rm -rf "$dir"
    mkdir -p "$dir"
    git archive "$rev" | tar -x -C "$dir"
    mkdir -p "$dir/scripts/bench"
    cp scripts/bench/EngineBench.swift "$dir/scripts/bench/"
    [[ -z "${PATCH:-}" ]] || patch -s -d "$dir" -p1 < "$PATCH"
    if [[ -f "$dir/Sources/gary/PluginEngine.swift" ]]; then
        cp "$dir/scripts/bench/EngineBench.swift" "$dir/Tests/GaryTests/"
        [[ -f "$dir/Sources/gary/PluginEngines.swift" ]] || cp scripts/bench/SharedEngine.swift "$dir/Tests/GaryTests/"
    else
        grep -v benchEngine "$dir/scripts/bench/EngineBench.swift" > "$dir/Tests/GaryTests/EngineBench.swift"
    fi
    swift build --package-path "$dir" -c release --build-tests -Xswiftc -enable-testing --jobs 4 \
        -Xswiftc -plugin-path -Xswiftc "$toolchain/lib/swift/host/plugins/testing" 2>&1 | grep -E 'error|Compiling gary|Build complete' || true
done
for run in $(seq "$RUNS"); do
    shift_by=$(((run - 1) % ${#sides[@]}))
    for side in "${sides[@]:shift_by}" "${sides[@]:0:shift_by}"; do
        echo "run=$run $side"
        engines=""
        [[ "$side" != *:* ]] || engines="${side#*:}"
        GARY_ENGINE_BENCH="$SECONDS_PER_RUN" BENCH_SIDE="$side" BENCH_ENGINES="$engines" swift test --package-path "tmp/bench/engine/${side%%:*}" --skip-build -c release \
            -Xswiftc -enable-testing --filter EngineBench 2>&1 | grep '^engine_bench ' | sed "s/^engine_bench //" | tee -a "$OUT"
    done
done
python3 scripts/bench/engine.py "$OUT"
