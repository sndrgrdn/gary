build:
    swift build --jobs 4

test:
    swift test --jobs 4 -Xswiftc -plugin-path -Xswiftc "$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"

bundle *flags:
    scripts/bundle.sh {{flags}}

run: kill
    scripts/bundle.sh --debug
    ./build/Gary.app/Contents/MacOS/gary

install: bundle
    #!/usr/bin/env bash
    set -euo pipefail
    running=false
    if pkill -f "Gary.app/Contents/MacOS/gary"; then running=true; fi
    rm -rf ~/Applications/Gary.app
    mkdir -p ~/Applications ~/.local/bin
    cp -R build/Gary.app ~/Applications/Gary.app
    ln -sf ~/Applications/Gary.app/Contents/MacOS/gary ~/.local/bin/gary
    ls -l ~/.local/bin/gary
    if $running; then open -g ~/Applications/Gary.app && echo "restarted Gary"; fi

release version:
    scripts/release.sh {{version}}

kill:
    pkill -f "Gary.app/Contents/MacOS/gary" || true

format:
    swiftlint --fix --quiet
    swiftformat .
    npx oxfmt

lint:
    swiftformat --lint .
    swiftlint lint --quiet --strict
    npx oxlint --deny-warnings
    npx oxfmt --check

typecheck: build
    #!/usr/bin/env bash
    set -euo pipefail
    gary="$(swift build --show-bin-path)/gary"
    for config in examples/*/tsconfig.json Resources/plugins/*/tsconfig.json; do
        dir="$(dirname "$config")"
        "$gary" plugin types "$dir" >/dev/null
        npx tsc -p "$dir"
    done

dead-code:
    swift build --build-system native --jobs 4 --scratch-path .build/periphery
    periphery scan --skip-build --quiet --strict --index-store-path .build/periphery/arm64-apple-macosx/debug/index/store --retain-public --retain-assign-only-properties --retain-objc-annotated --relative-results

anti-slop:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f tools/anti-slop-swift/Package.resolved
    swift build --package-path tools/anti-slop-swift --force-resolved-versions --jobs 4
    tools/anti-slop-swift/.build/debug/anti-slop Sources Tests
