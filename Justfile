build:
    swift build --jobs 4

test:
    swift test --jobs 4

bundle *flags:
    scripts/bundle.sh {{flags}}

# Debug bundle, replace any running Gary, and run attached so logs stream here.
run: kill
    scripts/bundle.sh --debug
    ./build/Gary.app/Contents/MacOS/gary

kill:
    pkill -f "Gary.app/Contents/MacOS/gary" || true
