#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

repo=sndrgrdn/gary
fail() { echo "release: $*" >&2; exit 1; }

update_tap() (
    checkout="$(mktemp -d)"
    trap 'rm -rf "$checkout"' EXIT
    git clone --quiet --depth 1 https://github.com/sndrgrdn/homebrew-tap.git "$checkout"
    cp dist/gary.rb "$checkout/Casks/gary.rb"
    git -C "$checkout" add Casks/gary.rb
    if ! git -C "$checkout" diff --cached --quiet; then
        git -C "$checkout" commit -q -m "Update gary to $version"
        git -C "$checkout" push -q
    fi
    echo "==> tap: gary $version"
)

changelog_section() {
    awk -v heading="## $1" '$0 == heading { found = 1; next } found && /^## / { exit } found { print }' CHANGELOG.md |
        sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

version="${1:-}"
version="${version#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: scripts/release.sh <X.Y.Z>"
tag="v$version"
[[ "$(git branch --show-current)" == main ]] || fail "release from main"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has changes; commit or stash them first"
git fetch -q origin main

if [[ "$(git log -1 --format=%s)" == "Release $version" ]]; then
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
        [[ "$(git rev-parse HEAD^)" == "$(git rev-parse origin/main)" ]] || fail "main does not match origin/main; push or pull first"
        git push -q origin HEAD:main
    fi
else
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main does not match origin/main; push or pull first"
    [[ -n "$(changelog_section Unreleased)" ]] || fail "the ## Unreleased section of CHANGELOG.md is empty"
    ! grep -qx "## $version" CHANGELOG.md || fail "CHANGELOG.md already has a ## $version section"
    ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag already exists"
    /usr/bin/sed -i '' "s/^## Unreleased\$/## Unreleased\\
\\
## $version/" CHANGELOG.md
    git commit -qm "Release $version" CHANGELOG.md
    git push -q origin HEAD:main
    echo "==> Prepared and pushed Release $version"
fi

head="$(git rev-parse HEAD)"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [[ "$head" == "$(git rev-list -n 1 "$tag")" ]] || fail "$tag already tags another commit"
fi
mkdir -p dist
changelog_section "$version" >dist/release-notes.md
[[ -s dist/release-notes.md ]] || fail "CHANGELOG.md has no notes under ## $version"

if [[ "$(gh release view "$tag" -R "$repo" --json isDraft --jq .isDraft 2>/dev/null || true)" == false ]]; then
    gh release download "$tag" -R "$repo" -p gary.rb -D dist --clobber
    update_tap
    exit 0
fi

scripts/package-release.sh "$version"
[[ "$head" == "$(git rev-parse HEAD)" && -z "$(git status --porcelain)" ]] || fail "the source changed during packaging; run again"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "Gary $version"
git push -q origin "$tag"
if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
    gh release edit "$tag" -R "$repo" --notes-file dist/release-notes.md
else
    gh release create "$tag" -R "$repo" --verify-tag --draft --title "Gary $version" --notes-file dist/release-notes.md
fi
gh release upload "$tag" -R "$repo" "dist/Gary-$version.zip" "dist/Gary-$version.zip.sha256" dist/gary.rb --clobber
gh release edit "$tag" -R "$repo" --draft=false --latest
echo "==> https://github.com/$repo/releases/tag/$tag"
update_tap
