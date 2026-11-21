#!/bin/sh
# The QA merge train's checks (docs/plan-notes.md, workstream Q), run on the
# integration branch after each merge. Exits non-zero at the first failure.
#   tools/merge-check.sh [--data <gta2/data>]   with --data, also the level runner
set -e
cd "$(dirname "$0")/.."
root=$PWD
data=""
[ "$1" = "--data" ] && data="$2"
step() { echo "== $*"; }
step no-floats; sh tools/check-no-floats.sh
step coverage; node tools/coverage/rollup.mjs --check
for m in Debug ReleaseSafe ReleaseFast; do
  step "sim tests $m"; (cd sim && zig build test -Doptimize=$m)
done
step "interfaces, formats, net, client tests"
(cd interfaces/zig && zig build test)
(cd formats && zig build test)
(cd net && zig build test)
(cd client/wasm && zig build test)
(cd client/render && zig build test)
step "shell check and tests"
(cd client/shell && { [ -d node_modules ] || npm ci --silent; } && npm run check --silent && npm test --silent > /tmp/qa-shell.out 2>&1 || { cat /tmp/qa-shell.out; exit 1; })
step "replay build"; cd "$root/tools/replay" && zig build -Doptimize=ReleaseSafe
step "golden native"; ./zig-out/bin/replay verify golden
h=$(./zig-out/bin/replay hash200 2>&1 | sed -n 's/.*final hash \([0-9a-f]\{16\}\).*/\1/p')
step "golden wasm"; node verify-wasm.mjs zig-out/bin/replay.wasm golden "$h"
step "sp golden native"; ./zig-out/bin/replay sp-verify golden-sp
step "sp golden wasm"; node verify-wasm.mjs zig-out/bin/replay.wasm golden-sp
step selftest; ./zig-out/bin/replay selftest
step stats
./zig-out/bin/replay stats golden > /tmp/qa-stats.out 2>&1
grep -q '^invariants: .* 0 breaks$' /tmp/qa-stats.out || { cat /tmp/qa-stats.out; exit 1; }
sed -n '/^ticks /,/^final_peds /p' /tmp/qa-stats.out | diff -u golden/stats.txt -
step soak; ./zig-out/bin/replay soak 100000
if [ -n "$data" ]; then
  step level; cd "$root/tools/level" && zig build -Doptimize=ReleaseFast && ./zig-out/bin/level --data "$data" --all --out results/latest.md > /dev/null
fi
step "all checks passed"
