#!/bin/sh
# Determinism rule 1: no floating point in sim/. Exits non-zero on a hit.
cd "$(dirname "$0")/../.." || exit 2
if grep -nE '\bf(16|32|64|80|128)\b|comptime_float|@float|[0-9]\.[0-9]+[eE]?' sim/*.zig | grep -vE '^\S+:[0-9]+:\s*//'; then
  echo "floating point found in sim/" >&2; exit 1
fi
echo "sim/: no floating point"
