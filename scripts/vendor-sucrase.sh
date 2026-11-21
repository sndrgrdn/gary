#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SUCRASE=3.35.1
ESBUILD=0.28.2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
npm install --prefix "$work" --no-save --ignore-scripts "sucrase@$SUCRASE" "esbuild@$ESBUILD" >/dev/null
echo 'export { transform } from "sucrase";' > "$work/entry.js"
"$work/node_modules/.bin/esbuild" "$work/entry.js" --bundle --minify --format=iife --global-name=Sucrase \
    --platform=neutral --main-fields=main,module --log-level=warning --outfile=Resources/vendor/sucrase.js
cp "$work/node_modules/sucrase/LICENSE" Resources/vendor/sucrase.LICENSE
echo "vendored sucrase $SUCRASE into Resources/vendor/sucrase.js"
