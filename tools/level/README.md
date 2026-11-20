# tools/level: headless level runner

Workstream Q (docs/plan-notes.md). Runs a real level from your own GTA2 data, headless, and checks it holds up. Native only. It reads the data from `--data` and is never run in CI; the results it writes have no game data in them (counts, ticks and block coordinates only), so `results/latest.md` is committed.

```sh
cd tools/level
zig build -Doptimize=ReleaseFast
zig-out/bin/level --data ~/gta2/data --all --out results/latest.md
zig-out/bin/level --data ~/gta2/data --map wil.gmp --ticks 50000 --bots 15
```

What a run does, per map:

- Loads the `.gmp` with `formats/` and builds the sim grid.
- Puts an autopilot player in slot 0 and bots in the other slots (`--bots`, default 7) to stir the city.
- The autopilot goes where it is sent. Until the sim has a mission arrow (A1's HUD state, `missionArrow`), it is sent to random road waypoints 20 to 80 blocks away. On foot it walks straight at the target or takes the nearest free car when the target is over 20 blocks away; in a car it steers straight at the target and backs out when stuck. It has no route planner yet, so many trips end in the teleport (`--limit`, default 1800 ticks).
- Checks the invariants every tick (`tools/replay/src/qa.zig`): bodies inside matter, under the world or over a void, too fast, broken riding links, dead player rows, kinds stuck at capacity, health out of range.
- Reports trips, autopilot deaths, step time, invariant breaks with where they happened, and play statistics.

Exit code 1 when any map has an invariant break.

To come, as the workstreams land: mission scripts (per mission started, passed or failed, ticks taken, threads stuck on one command for over 3,000 ticks, unimplemented command types reached), the `sp` configuration with a full city, and a route-following autopilot once F's route planner exists.
