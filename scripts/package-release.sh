#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: scripts/package-release.sh <version>}"
version="${version#v}"
profile="${NOTARYTOOL_PROFILE:-GaryNotary}"
identity="${DEVELOPER_ID_APPLICATION:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$identity" ]] || { echo "no Developer ID Application identity; set DEVELOPER_ID_APPLICATION" >&2; exit 1; }
APP=build/Gary.app
zip="Gary-$version.zip"

echo "==> Building and signing Gary $version with $identity"
VERSION="$version" BUILD="$(git rev-list --count HEAD)" IDENTITY="$identity" TIMESTAMP=--timestamp scripts/bundle.sh
codesign --verify --deep --strict "$APP"

mkdir -p dist
rm -f dist/Gary-*.zip dist/Gary-*.zip.sha256 dist/gary.rb
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "==> Notarizing with profile $profile"
ditto -c -k --keepParent "$APP" "$tmp/upload.zip"
xcrun notarytool submit "$tmp/upload.zip" --keychain-profile "$profile" --wait --output-format json >"$tmp/result.json"
id="$(plutil -extract id raw "$tmp/result.json")"
if [[ "$(plutil -extract status raw "$tmp/result.json")" != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    echo "Apple did not accept submission $id" >&2
    exit 1
fi
xcrun stapler staple "$APP"

ditto -c -k --keepParent "$APP" "dist/$zip"
(cd dist && shasum -a 256 "$zip" >"$zip.sha256")
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$(cut -d ' ' -f 1 "dist/$zip.sha256")/" scripts/gary.rb.template >dist/gary.rb
! grep -q '@[A-Z0-9_]*@' dist/gary.rb || { echo "dist/gary.rb has an unfilled placeholder" >&2; exit 1; }

echo "==> Checking the shipping zip"
ditto -x -k "dist/$zip" "$tmp/unpacked"
shipped="$tmp/unpacked/Gary.app"
codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "8U24BL7PPN" and identifier "com.sndrgrdn.gary"' "$shipped"
[[ "$(spctl --assess --type execute --verbose=2 "$shipped" 2>&1)" == *"source=Notarized Developer ID"* ]] || { echo "Gatekeeper does not see a notarized Developer ID app in dist/$zip" >&2; exit 1; }
[[ "$("$shipped/Contents/MacOS/gary" --version)" == "gary $version" ]] || { echo "the gary in dist/$zip does not report version $version" >&2; exit 1; }
echo "==> dist/$zip ($(du -h "dist/$zip" | cut -f 1)), Gary $version build $(git rev-list --count HEAD)"
