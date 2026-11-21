build:
    swift build --jobs 4

test:
    swift test --jobs 4 -Xswiftc -plugin-path -Xswiftc "$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"

bundle *flags:
    scripts/bundle.sh {{flags}}

run: kill
    scripts/bundle.sh --debug
    ./build/Gary.app/Contents/MacOS/gary

kill:
    pkill -f "Gary.app/Contents/MacOS/gary" || true
