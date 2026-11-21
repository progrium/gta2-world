# Single-player golden

The sp configuration on the synthetic test map, running the hand-written
script `../src/sp_golden.sasm` (scrasm, no game data) for 6,000 ticks with
one player. The player's inputs were made by the level runner's autopilot:
walk into the trigger area by the phone, go to the mission car, then loop
round the city.

- `inputs.bin`, `hashes.bin`: the dm16 golden's formats with one player.
- `summary.txt`: what the run did (missions, rings, wasted and busted, the
  script's counters, unhandled commands, invariant breaks). `sp-verify`
  fails if any line changes.

Verify: `zig-out/bin/replay sp-verify golden-sp` and
`node verify-wasm.mjs zig-out/bin/replay.wasm golden-sp`.
Re-record (QA only, with a note of what changed): `zig build golden-sp`.
