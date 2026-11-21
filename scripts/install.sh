#!/bin/sh
set -eu

REPO=sndrgrdn/gary
APP="$HOME/Applications/Gary.app"
LINK="$HOME/.local/bin/gary"
fail() { echo "gary install: $*" >&2; exit 1; }

main() {
    command -v gh >/dev/null 2>&1 || fail "needs the GitHub CLI; install it with brew install gh, then run gh auth login"
    gh auth status --hostname github.com >/dev/null 2>&1 || fail "gh is not logged in; run gh auth login"

    if [ $# -gt 0 ]; then
        tag="v${1#v}"
    else
        tag=$(gh release view --repo "$REPO" --json tagName --jq .tagName) || fail "cannot read the releases of $REPO; ask its owner for access"
    fi
    version=${tag#v}
    installed=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null) || installed=none
    echo "installed: $installed, release: $version"

    fresh=false
    if [ "$installed" = "$version" ] && codesign --verify --deep --strict "$APP" 2>/dev/null; then
        echo "Gary $version is up to date"
    else
        fresh=true
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        gh release download "$tag" --repo "$REPO" --pattern "Gary-$version.zip*" --dir "$work"
        (cd "$work" && shasum -a 256 -c "Gary-$version.zip.sha256") || fail "the checksum of Gary-$version.zip does not match"
        ditto -x -k "$work/Gary-$version.zip" "$work/unzipped"
        codesign --verify --deep --strict "$work/unzipped/Gary.app" || fail "the signature of Gary $version does not verify"

        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/.Gary.app.new" "$HOME/Applications/.Gary.app.old"
        ditto "$work/unzipped/Gary.app" "$HOME/Applications/.Gary.app.new"
        if [ -x "$APP/Contents/MacOS/gary" ]; then "$APP/Contents/MacOS/gary" quit; fi
        if [ -d "$APP" ]; then mv "$APP" "$HOME/Applications/.Gary.app.old"; fi
        mv "$HOME/Applications/.Gary.app.new" "$APP"
        rm -rf "$HOME/Applications/.Gary.app.old"
        echo "installed Gary $version in $APP"
    fi

    mkdir -p "$(dirname "$LINK")"
    ln -sfn "$APP/Contents/MacOS/gary" "$LINK"
    "$LINK" login on
    if ! "$LINK" ping >/dev/null 2>&1; then
        open -g "$APP"
        tries=0
        until "$LINK" ping >/dev/null 2>&1; do
            tries=$((tries + 1))
            [ "$tries" -lt 50 ] || fail "Gary did not start; see ~/Library/Logs/gary.log"
            sleep 0.2
        done
    fi
    echo "Gary $version is running"

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) echo "add ~/.local/bin to your PATH to run gary" ;;
    esac
    [ "$fresh" = true ] || return 0
    cat <<EOF

Next steps:
  gary onboarding     grant the macOS permissions that your plugins need
  gary skill setup    teach Claude Code and other agents to write Gary plugins
EOF
}

main "$@"
