#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=sndrgrdn/gary
TAP="${TAP:-../homebrew-tap}"
CASK="$TAP/Casks/gary.rb"
fail() { echo "release: $*" >&2; exit 1; }
changelog_section() {
    awk -v heading="## $1" '$0 == heading { found = 1; next } found && /^## / { exit } found { print }' CHANGELOG.md |
        sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

version="${1:-}"
version="${version#v}"
[[ -n "$version" ]] || fail "usage: scripts/release.sh <version>"
tag="v$version"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has changes; commit or stash them first"
[[ "$(git branch --show-current)" == main ]] || fail "release from main"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [[ "$(git rev-list -n 1 "$tag")" == "$(git rev-parse HEAD)" ]] || fail "$tag already tags another commit"
fi
! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 || fail "release $tag already exists on $REPO"
[[ -f "$CASK" ]] || fail "cannot find $CASK; clone sndrgrdn/homebrew-tap to $TAP or set TAP"
[[ -z "$(git -C "$TAP" status --porcelain)" ]] || fail "$TAP has changes; commit or stash them first"

git fetch -q origin main
if [[ "$(git log -1 --format=%s)" != "Release $version" ]]; then
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main does not match origin/main; push or pull first"
    [[ -n "$(changelog_section Unreleased)" ]] || fail "the ## Unreleased section of CHANGELOG.md is empty"
    ! grep -qx "## $version" CHANGELOG.md || fail "CHANGELOG.md already has a ## $version section"
    /usr/bin/sed -i '' "s/^## Unreleased\$/## Unreleased\\
\\
## $version/" CHANGELOG.md
    git commit -qm "Release $version" CHANGELOG.md
    git push -q origin HEAD:main
fi
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
changelog_section "$version" >"$notes"
[[ -s "$notes" ]] || fail "CHANGELOG.md has no notes under ## $version"

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
gh release create "$tag" --repo "$REPO" --title "Gary $version" --notes-file "$notes" "$out/$zip" "$out/$zip.sha256"

sha=$(cut -d ' ' -f 1 "$out/$zip.sha256")
/usr/bin/sed -i '' -e "s/^  version \".*\"$/  version \"$version\"/" -e "s/^  sha256 \".*\"$/  sha256 \"$sha\"/" "$CASK"
git -C "$TAP" diff --quiet || git -C "$TAP" commit -qm "Update gary to $version" Casks/gary.rb
git -C "$TAP" push
