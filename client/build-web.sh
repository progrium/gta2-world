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
# Version the URLs so a browser never mixes a new page with a cached old
# module or worker (GitHub Pages caches for 10 minutes).
v=$(cat "$out/dist/main.js" "$out/dist/worker.js" "$out/dist/game.wasm" | sha256sum | cut -c1-10)
sed -i "s#\"\./game\.wasm\"#\"./game.wasm?v=$v\"#g; s#\"\./worker\.js\"#\"./worker.js?v=$v\"#g" "$out/dist/main.js"
sed -i "s#dist/main\.js\"#dist/main.js?v=$v\"#; s#styles\.css\"#styles.css?v=$v\"#" "$out/index.html"
grep -q "game.wasm?v=$v" "$out/dist/main.js" && grep -q "worker.js?v=$v" "$out/dist/main.js" || { echo "build-web: could not version the URLs in main.js" >&2; exit 1; }
# The browser host Worker (src/host/worker.ts), when the build has it.
if [ -f "$here/shell/dist/host-worker.js" ]; then
  cp "$here/shell/dist/host-worker.js" "$out/dist/"
  sed -i "s#\"\./host-worker\.js\"#\"./host-worker.js?v=$v\"#g" "$out/dist/main.js"
fi
echo "built $out"
