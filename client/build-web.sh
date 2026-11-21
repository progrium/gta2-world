#!/bin/sh
# Builds the playable browser client into one static folder:
#   index.html, styles.css, dist/main.js, dist/worker.js, dist/game.wasm,
#   dist/host-worker.js + dist/host.wasm (the browser host Worker, host/)
# Usage: client/build-web.sh [out-dir]   (default client/web-out)
# Needs Zig 0.17.0, Node 22 and npm. Contains no game data: players pick
# their own GTA2 files in the page.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/web-out}
(cd "$here/wasm" && zig build -Doptimize=ReleaseSmall)
(cd "$here/../host" && zig build)
(cd "$here/shell" && { [ -d node_modules ] || npm ci --silent; } && npm run --silent build -- --minify)
mkdir -p "$out/dist"
cp "$here/shell/index.html" "$here/shell/styles.css" "$out/"
cp "$here/shell/dist/main.js" "$here/shell/dist/worker.js" "$here/shell/dist/host-worker.js" "$out/dist/"
cp "$here/wasm/zig-out/web/game.wasm" "$here/../host/zig-out/web/host.wasm" "$out/dist/"
# Version the URLs so a browser never mixes a new page with a cached old
# module or worker (GitHub Pages caches for 10 minutes).
v=$(cat "$out/dist/main.js" "$out/dist/worker.js" "$out/dist/game.wasm" "$out/dist/host-worker.js" "$out/dist/host.wasm" | sha256sum | cut -c1-10)
sed -i "s#\"\./game\.wasm\"#\"./game.wasm?v=$v\"#g; s#\"\./worker\.js\"#\"./worker.js?v=$v\"#g; s#\"\./host-worker\.js\"#\"./host-worker.js?v=$v\"#g" "$out/dist/main.js"
sed -i "s#\"\./host\.wasm\"#\"./host.wasm?v=$v\"#g" "$out/dist/host-worker.js"
sed -i "s#dist/main\.js\"#dist/main.js?v=$v\"#; s#styles\.css\"#styles.css?v=$v\"#" "$out/index.html"
grep -q "game.wasm?v=$v" "$out/dist/main.js" && grep -q "worker.js?v=$v" "$out/dist/main.js" || { echo "build-web: could not version the URLs in main.js" >&2; exit 1; }
grep -q "host.wasm?v=$v" "$out/dist/host-worker.js" || { echo "build-web: could not version the URL in host-worker.js" >&2; exit 1; }
echo "built $out"
