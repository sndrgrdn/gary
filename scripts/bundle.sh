#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1}"
BUILD="${BUILD:-1}"
IDENTITY="${IDENTITY:-Sander Local Signing}"
CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug

BUILD_FLAGS=(-c "$CONFIG" --jobs 4 --arch arm64)
swift build "${BUILD_FLAGS[@]}"

APP=build/Gary.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/gary" "$APP/Contents/MacOS/gary"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
cp Resources/theme.json "$APP/Contents/Resources/theme.json"
cp -R Resources/plugins "$APP/Contents/Resources/plugins"
cp Resources/vendor/sucrase.js Resources/vendor/sucrase.LICENSE "$APP/Contents/Resources/"
"$APP/Contents/MacOS/gary" plugin types "$APP/Contents/Resources/types" >/dev/null

codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP ($CONFIG, $VERSION build $BUILD)"
