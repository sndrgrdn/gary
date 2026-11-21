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

kill:
    pkill -f "Gary.app/Contents/MacOS/gary" || true
