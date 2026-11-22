#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ESBUILD=0.28.2
test -d node_modules/effect || { echo "run npm ci first: effect comes from package.json" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
npm install --prefix "$work" --no-save --ignore-scripts "esbuild@$ESBUILD" >/dev/null
"$work/node_modules/.bin/esbuild" Sources/gary-effect/index.ts --bundle --minify --format=iife --global-name=GaryEffect \
    --target=es2022 --legal-comments=none --log-level=warning --outfile=Resources/vendor/effect.js
cp node_modules/effect/LICENSE Resources/vendor/effect.LICENSE
version=$(node -p 'require("./node_modules/effect/package.json").version')
echo "vendored effect $version into Resources/vendor/effect.js ($(wc -c < Resources/vendor/effect.js | tr -d ' ') bytes, $(gzip -c Resources/vendor/effect.js | wc -c | tr -d ' ') gzipped)"
