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

BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
APP=build/Gary.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/gary" "$APP/Contents/MacOS/gary"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
cp Resources/theme.json "$APP/Contents/Resources/theme.json"
cp -R Resources/plugins "$APP/Contents/Resources/plugins"
cp Resources/vendor/sucrase.js Resources/vendor/sucrase.LICENSE "$APP/Contents/Resources/"
"$APP/Contents/MacOS/gary" plugin types "$APP/Contents/Resources/types" >/dev/null

ADAPTER="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
mkdir -p "$ADAPTER/Versions/A/Resources" "$APP/Contents/Resources/mediaremote-adapter"
cp "$BIN/libMediaRemoteAdapter.dylib" "$ADAPTER/Versions/A/MediaRemoteAdapter"
install_name_tool -id @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter "$ADAPTER/Versions/A/MediaRemoteAdapter" 2>/dev/null
plutil -create xml1 "$ADAPTER/Versions/A/Resources/Info.plist"
plutil -insert CFBundleIdentifier -string com.sndrgrdn.gary.MediaRemoteAdapter "$ADAPTER/Versions/A/Resources/Info.plist"
plutil -insert CFBundleExecutable -string MediaRemoteAdapter "$ADAPTER/Versions/A/Resources/Info.plist"
plutil -insert CFBundlePackageType -string FMWK "$ADAPTER/Versions/A/Resources/Info.plist"
ln -s A "$ADAPTER/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$ADAPTER/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$ADAPTER/Resources"
cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/mediaremote-adapter/"

codesign --force --sign "$IDENTITY" "$ADAPTER"
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP ($CONFIG, $VERSION build $BUILD)"
