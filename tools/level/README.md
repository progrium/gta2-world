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

## Traffic soak: `--traffic`

```sh
zig-out/bin/level --traffic --data ~/gta2/data --all --ticks 10000 --out results/traffic-latest.md
zig-out/bin/level --traffic --data ~/gta2/data --map wil.gmp --trace 5      # last 80 ticks of the first 5 cars that leave the road
zig-out/bin/level --traffic --data ~/gta2/data --map wil.gmp --dump 22,67   # the lanes around a block
```

Workstream F's check of the traffic AI on real maps. Runs the `sp` configuration (48 ambient cars, no level script) with the player on foot, moved to the pavement beside a random road block every 2,000 ticks, and counts per map: cars abandoned (gave up seeking the road), stuck (stopped 300 ticks with nothing holding them), wrong way (against their lane's arrow for 30 ticks), off the road for 20 ticks, car impacts, and damaged and wrecked cars, with the block of the first few of each. `results/traffic-latest.md` is the last run. The mike2 maps have no road, so no traffic.
