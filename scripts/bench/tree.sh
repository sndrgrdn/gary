#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

toolchain="$(dirname "$(xcrun --find swift)")/.."
if [[ "${1:-}" == "build" ]]; then
    swift build -c release --build-tests -Xswiftc -enable-testing --jobs 4 \
        -Xswiftc -plugin-path -Xswiftc "$toolchain/lib/swift/host/plugins/testing"
    rm -rf "tmp/harness/$2"
    mkdir -p "tmp/harness/$2"
    cp -R .build/out/Products/Release/GaryTests.xctest "tmp/harness/$2/"
    exit
fi

platform="$(xcrun --show-sdk-platform-path)/Developer"
export DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib"
variants=("$@")
RUNS="${RUNS:-5}"
SIZES="${SIZES:-100,500,1000,2000}"
OUT="${OUT:-tmp/bench/tree-$(date +%Y%m%d-%H%M%S).txt}"
mkdir -p tmp/bench
for run in $(seq "$RUNS"); do
    shift_by=$(((run - 1) % ${#variants[@]}))
    for variant in "${variants[@]:shift_by}" "${variants[@]:0:shift_by}"; do
        GARY_TREE_BENCH="$SIZES" "$toolchain/libexec/swift/pm/swiftpm-testing-helper" \
            --test-bundle-path "tmp/harness/$variant/GaryTests.xctest/Contents/MacOS/GaryTests" \
            --testing-library swift-testing --filter TreeViewBench 2>&1 | grep '^tree_bench' | sed "s/^tree_bench /variant=$variant run=$run /" | tee -a "$OUT"
    done
done
python3 - "$OUT" <<'PY'
import re, statistics, sys
rows = [dict(re.findall(r"(\w+)=(\S+)", line)) for line in open(sys.argv[1])]
for key in sorted({(row["variant"], int(row["nodes"])) for row in rows}, key=lambda key: (key[1], key[0])):
    group = [row for row in rows if (row["variant"], int(row["nodes"])) == key]
    def spread(name):
        values = [float(row[name]) for row in group]
        return f"{statistics.median(values):.2f} ({min(values):.2f} to {max(values):.2f})"
    print(f"{key[0]} nodes={key[1]} n={len(group)} frame p50 {spread('frame_ms_p50')} ms; layout p50 {spread('layout_ms_p50')} ms; "
          f"apply p50 {spread('apply_ms_p50')} ms; mount {spread('mount_ms')} ms"
          + (f"; parse p50 {spread('parse_ms_p50')} ms" if all("parse_ms_p50" in row for row in group) else ""))
PY
