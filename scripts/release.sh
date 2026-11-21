#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=sndrgrdn/gary
TAP="${TAP:-../homebrew-tap}"
CASK="$TAP/Casks/gary.rb"
fail() { echo "release: $*" >&2; exit 1; }

version="${1:-}"
version="${version#v}"
[[ -n "$version" ]] || fail "usage: scripts/release.sh <version>"
tag="v$version"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has changes; commit or stash them first"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [[ "$(git rev-list -n 1 "$tag")" == "$(git rev-parse HEAD)" ]] || fail "$tag already tags another commit"
fi
! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 || fail "release $tag already exists on $REPO"
[[ -f "$CASK" ]] || fail "cannot find $CASK; clone sndrgrdn/homebrew-tap to $TAP or set TAP"
[[ -z "$(git -C "$TAP" status --porcelain)" ]] || fail "$TAP has changes; commit or stash them first"

VERSION="$version" BUILD="$(git rev-list --count HEAD)" scripts/bundle.sh
APP=build/Gary.app
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>/dev/null | grep -q '^designated => .*certificate' || fail "$APP is not signed with a certificate, so permission grants would not survive an update"

out=build/release
zip="Gary-$version.zip"
rm -rf "$out"
mkdir -p "$out"
ditto -c -k --keepParent "$APP" "$out/$zip"
(cd "$out" && shasum -a 256 "$zip" > "$zip.sha256")

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "Gary $version"
git push origin "$tag"
gh release create "$tag" --repo "$REPO" --title "Gary $version" --generate-notes "$out/$zip" "$out/$zip.sha256"

sha=$(cut -d ' ' -f 1 "$out/$zip.sha256")
/usr/bin/sed -i '' -e "s/^  version \".*\"$/  version \"$version\"/" -e "s/^  sha256 \".*\"$/  sha256 \"$sha\"/" "$CASK"
git -C "$TAP" diff --quiet || git -C "$TAP" commit -qm "Update gary to $version" Casks/gary.rb
git -C "$TAP" push
