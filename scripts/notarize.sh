#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Gary.app}"
PROFILE="${NOTARY_PROFILE:-GaryNotary}"
fail() { echo "notarize: $*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "cannot find $APP"
[[ "$(codesign -dvv "$APP" 2>&1)" == *$'\nAuthority=Developer ID Application: '* ]] || fail "$APP is not signed with a Developer ID Application certificate"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -c -k --keepParent "$APP" "$work/upload.zip"
xcrun notarytool submit "$work/upload.zip" --keychain-profile "$PROFILE" --wait --output-format json >"$work/result.json" ||
    fail "notarytool submit failed: $(cat "$work/result.json")"
id="$(plutil -extract id raw "$work/result.json")"
status="$(plutil -extract status raw "$work/result.json")"
if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    fail "Apple did not accept $APP: $status (submission $id)"
fi

xcrun stapler staple -q "$APP"
xcrun stapler validate -q "$APP" || fail "the notarization ticket is not stapled to $APP"
spctl --assess --type execute "$APP" || fail "Gatekeeper rejects $APP"
echo "notarized $APP (submission $id)"
