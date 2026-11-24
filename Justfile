swift_flags := '--jobs 4 -Xswiftc -warnings-as-errors -Xswiftc -plugin-path -Xswiftc "$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"'

build:
    swift build --build-tests {{swift_flags}}

test: build
    swift test --skip-build

check: lint build test typecheck dead-code anti-slop

bundle *flags:
    scripts/bundle.sh {{flags}}

run: kill
    scripts/bundle.sh --debug
    "{{justfile_directory()}}/build/Gary.app/Contents/MacOS/gary"

isolated home="tmp/isolated":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{home}}"
    home="$(cd "{{home}}" && pwd)"
    support="$home/Library/Application Support/Gary"
    mkdir -p "$home/.config/gary/plugins" "$home/Library/Logs" "$support" "$home/run"
    [[ -f "$home/.config/gary/shell.json" ]] || echo '{ "bar": { "right": ["gary.battery", "gary.clock"] } }' > "$home/.config/gary/shell.json"
    [[ -f "$support/onboarding.json" ]] || echo '{ "missing": ["accessibility", "audio-capture", "automation", "bluetooth", "calendars", "full-disk-access", "location", "notifications", "screen-recording"] }' > "$support/onboarding.json"
    scripts/bundle.sh --debug
    echo "drive it with: GARY_RUNTIME_DIR=$home/run $PWD/build/Gary.app/Contents/MacOS/gary <verb>"
    exec env GARY_HOME="$home" GARY_RUNTIME_DIR="$home/run" "$PWD/build/Gary.app/Contents/MacOS/gary"

install: bundle
    #!/usr/bin/env bash
    set -euo pipefail
    running=false
    if pkill -f "$HOME/Applications/Gary.app/Contents/MacOS/gary"; then running=true; fi
    rm -rf ~/Applications/Gary.app
    mkdir -p ~/Applications ~/.local/bin
    cp -R build/Gary.app ~/Applications/Gary.app
    ln -sf ~/Applications/Gary.app/Contents/MacOS/gary ~/.local/bin/gary
    ls -l ~/.local/bin/gary
    if $running; then open -g ~/Applications/Gary.app && echo "restarted Gary"; fi

package version:
    scripts/package-release.sh {{version}}

release version:
    scripts/release.sh {{version}}

kill:
    pkill -f "^{{justfile_directory()}}/build/Gary.app/Contents/MacOS/gary( |$)" || true

format:
    swiftlint --fix --quiet
    swiftformat .
    npx oxfmt

lint:
    swiftformat --lint .
    swiftlint lint --quiet --strict
    git ls-files -z '*.sh' | xargs -0 shellcheck
    npx oxlint --deny-warnings
    npx oxfmt --check

typecheck: build
    #!/usr/bin/env bash
    set -euo pipefail
    gary="$(swift build {{swift_flags}} --show-bin-path)/gary"
    for config in examples/*/tsconfig.json Resources/plugins/*/tsconfig.json; do
        dir="$(dirname "$config")"
        "$gary" plugin types "$dir" >/dev/null
        npx tsc -p "$dir"
    done
    npx tsc -p Sources/gary-effect

dead-code: build
    outskirts scan --skip-build --quiet --strict --retain-public --retain-assign-only-properties --retain-objc-annotated --relative-results

anti-slop:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f tools/anti-slop-swift/Package.resolved
    swift build --package-path tools/anti-slop-swift --force-resolved-versions --jobs 4
    tools/anti-slop-swift/.build/debug/anti-slop Sources Tests
