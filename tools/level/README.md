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
- The autopilot goes where it is sent: random road waypoints 20 to 80 blocks away (see `--sp` for the mission arrow). On foot it walks straight at the target or takes the nearest free car when the target is over 20 blocks away; in a car it steers straight at the target and backs out when stuck. It has no route planner yet, so many trips end in the teleport (`--limit`, default 1800 ticks).
- Checks the invariants every tick (`tools/replay/src/qa.zig`): bodies inside matter, under the world or over a void, too fast, broken riding links, dead player rows, kinds stuck at capacity, health out of range.
- Reports trips, autopilot deaths, step time, invariant breaks with where they happened, and play statistics.

Exit code 1 when any map has an invariant break.

## Single player: `--sp`

```sh
zig-out/bin/level --sp --data ~/gta2/data --all --ticks 30000 --out results/sp-latest.md
```

Runs every map that has a main script of the same name (`wil.gmp` with `wil.scr` and the mission sub-scripts in `wil/*.scr`) in the `sp` configuration with the level attached. The autopilot goes to the mission arrow when the HUD shows one, else to the last phone that rang, else to road waypoints. Per level it reports missions started, passed and failed (with ticks), phone rings, wasted and busted, threads on one command for over 3,000 ticks (command number and type), the unhandled command count, invariant breaks and step time. `results/sp-latest.md` is the last run.

Still to come: a route-following autopilot on F's route planner, and answering phones by walking onto them once the scripts ring them.
