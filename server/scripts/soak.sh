#!/bin/sh
# Headless end-to-end soak without game data: a synthetic map, the server,
# WebSocket bot clients for SECONDS, then every recorded replay re-run and
# hash-compared. Used by CI; exits nonzero on any failure.
#   scripts/soak.sh [seconds] [bots]
set -eu
secs=${1:-20}; bots=${2:-4}
here=$(cd "$(dirname "$0")/.." && pwd)
bin="$here/zig-out/bin/gta2-server"
tmp=$(mktemp -d); trap 'kill $pid 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/data" "$tmp/replays"
"$bin" synth-map "$tmp/data/city.gmp"
sh "$here/scripts/gen-cert.sh" "$tmp/certs" >/dev/null
"$bin" serve --data "$tmp/data" --cert "$tmp/certs/cert.pem" --key "$tmp/certs/key.pem" \
  --port 14433 --http-port 18080 --replay-dir "$tmp/replays" --idle-close 2 > "$tmp/server.log" 2>&1 &
pid=$!
i=0; until curl -sf http://127.0.0.1:18080/healthz >/dev/null; do i=$((i+1)); [ $i -lt 100 ] || { cat "$tmp/server.log"; exit 1; }; sleep 0.1; done
"$bin" bot --url ws://127.0.0.1:18080/s/soak/ws --map "$tmp/data/city.gmp" --bots "$bots" --players-per-bot 2 --seconds "$secs"
curl -sf http://127.0.0.1:18080/metrics | grep -E '^gta2_(session_step_seconds|client_snapshots_lost_total|slot_frames_repeated_total)' | head -12
sleep 4  # let the session close and its replay flush
n=0
for f in "$tmp"/replays/*.g2wr; do "$bin" replay "$f" --data "$tmp/data"; n=$((n+1)); done
[ $n -gt 0 ] || { echo "no replay recorded"; exit 1; }
grep -E '\[(err|warn)\]' "$tmp/server.log" || true
echo "soak ok"
