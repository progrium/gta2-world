#!/bin/sh
# Determinism rule 1: no floating point in sim/ (every .zig file, in every
# subdirectory). Comments are ignored, so "3.2" in a note reference or
# "-0.5..0.5" in a range comment is fine. Exits non-zero on a hit.
cd "$(dirname "$0")/.." || exit 2
hits=$(find sim -name '*.zig' -not -path '*/.zig-cache/*' -not -path '*/zig-out/*' | sort | xargs awk '
  {
    line = $0
    sub(/\/\/.*/, "", line)
    if (line ~ /(^|[^A-Za-z0-9_])f(16|32|64|80|128)([^A-Za-z0-9_]|$)|comptime_float|@float|[0-9]\.[0-9]/)
      printf "%s:%d: %s\n", FILENAME, FNR, $0
  }')
if [ -n "$hits" ]; then
  echo "$hits"
  echo "floating point found in sim/" >&2; exit 1
fi
echo "sim/: no floating point"
