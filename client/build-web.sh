#!/bin/sh
# Builds the playable browser client into one static folder:
#   index.html, styles.css, dist/main.js, dist/worker.js, dist/game.wasm
# Usage: client/build-web.sh [out-dir]   (default client/web-out)
# Needs Zig 0.17.0, Node 22 and npm. Contains no game data: players pick
# their own GTA2 files in the page.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/web-out}
(cd "$here/wasm" && zig build -Doptimize=ReleaseSmall)
(cd "$here/shell" && { [ -d node_modules ] || npm ci --silent; } && npm run --silent build -- --minify)
mkdir -p "$out/dist"
cp "$here/shell/index.html" "$here/shell/styles.css" "$out/"
cp "$here/shell/dist/main.js" "$here/shell/dist/worker.js" "$out/dist/"
cp "$here/wasm/zig-out/web/game.wasm" "$out/dist/"
echo "built $out"
