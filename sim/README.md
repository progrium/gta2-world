# sim

The deterministic game simulation (workstream A), implementing **I1** from `interfaces/I1-sim-abi.md`. Pure Zig, no I/O, no clock, no floats, no allocation. Linked by the browser client (WASM) and the server (native).

```sh
cd sim && zig build test        # unit and gameplay tests, I1 conformance (Zig 0.17.0)
cd tools/replay && zig build -Doptimize=ReleaseFast
./zig-out/bin/replay verify golden        # golden replay, native
node verify-wasm.mjs zig-out/bin/replay.wasm golden   # same replay in WASM
./zig-out/bin/replay handling             # car and ped numbers
./zig-out/bin/replay bench16              # step time
```

## Using it from a host

`sim/` is a Zig package that depends on `interfaces/zig` by path.

```zig
// build.zig.zon
.dependencies = .{ .sim = .{ .path = "../sim" } },
// build.zig
const sim_dep = b.dependency("sim", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sim", sim_dep.module("sim"));
// code
const sim = @import("sim");
var s: sim.Sim16 = undefined;                       // Sim(abi.config_16), "dm16"
s.init(&grid, .{ .seed = seed, .mode = .authoritative });
s.step(&frames, &.{.{ .op = .join, .slot = 0, .arg = 0 }});
```

- `sim.Sim(cfg)` for any `abi.Config`; `sim.Sim16` is `dm16`, `sim.config_200` is the 200-player load configuration.
- Everything in I1: `init`, `step`, `save`, `load`, `hash`, `tick`, `setTick`, `stateBytes`, `views`, `intents`, `playerRow`, `replicaPut`, `replicaRemove`, `config`, `state_size`, `layout_hash`. `abi.checkSim` runs at compile time.
- `replicated`: per kind, the components a snapshot carries, in ascending id, never `Predicted` (the shape workstream C asked for).
- Not in I1, for tools and tests: `spawnCarAt`, `pedOf`, `transformOf`, `spawnHint`.
- `sim.testmap.build(&grid)` makes the synthetic test map. `formats.grid.build` (workstream B) makes a grid from a real `.gmp`.

## What M1 implements

| Area | Behaviour |
| --- | --- |
| Players | `join` spawns a ped on foot, at the hint or on a random pavement cell; `leave` despawns it and frees a car it was driving. Dead players respawn on foot after 3 s. |
| On foot, tank | `steer` turns (about 230°/s), `throttle` walks forward or back (back is slower). `run` held runs. |
| On foot, direct | With the `direct` bit, the ped moves along `aim` at a speed set by `throttle` and turns its body toward it (about 650°/s). |
| Jump | `handbrake_jump` on foot jumps when on the ground. |
| Cars | Placeholder handling, ours, tuned by feel (below). |
| Enter, exit | `enter_exit` (rising edge) on foot enters the nearest free car within 1.5 blocks that is nearly stopped. In a car it exits on the driver's side (left of travel), else the right, else not at all. Entering sets `Riding.vehicle`, the car's `Vehicle.driver` and `Controller.player`, and `PlayerRow.car`; exiting clears them. `PlayerRow.car` is the car the player is in now, none on foot. |
| Map collision | Every cell shape reduces to "is there matter at this point, and how high is its top". Walls block; ramps (all 44 codes), partial blocks (53-61) and diagonal walls (45-48) are exact; diagonal slopes (49-52) act as diagonal walls for now. Peds climb 5/16 of a block, cars 7/10 (so a car's nose does not catch at the top of a ramp). Bodies fall, land and follow ramps down. |
| Bodies | Peds are circles sampled at 9 points; cars are boxes sampled at 8 points against the map and circles against each other. Moves are sub-stepped at a quarter block so nothing tunnels. |
| Weapons | A pistol for players on foot (M3 adds the rest, below). |
| Ambient | `dm16` spawns 24 cars on roads (aligned with the lane arrows) and 100 peds that wander on pavements and turn back at roads and drops. M3 makes 5 in 8 of the cars traffic. |
| Predict mode | Only `Predicted` entities step; others are fixed obstacles that are never written. Projectile spawns and every despawn become intents. Commands are ignored. Entering a car the client does not predict waits for the server. |

## What M3 adds

All of it is our own design, tuned by feel; every number is in `tuning.zig`.

| Area | Behaviour |
| --- | --- |
| Weapons | Pistol (infinite), machine gun, shotgun (6 pellets), rocket launcher. `weapon_next`/`weapon_prev` cycle through the ones with rounds. Rounds per weapon live in `Weapon.a0..a3`. |
| Explosions | Rockets explode at a wall, a body or the end of their range; cars explode when they burn out. Damage falls off from a core radius to the edge and pushes bodies away. |
| Cars | Below `car_burn_hp` a car burns and loses health, then explodes and becomes a wreck that cannot be entered, then despawns and a new traffic car appears elsewhere. |
| Pickups | Weapon and health pickups (2 + 2 per player) appear on pavement near players, spin, and expire after a minute. |
| Traffic | Cars with `flag_ai` follow lane arrows, choose a turn at junctions, keep to the lane centre, brake for bodies ahead and back out when stuck. Getting in takes the car over. |
| Ambient | Peds and traffic far from every player are moved back near one, at most 2 per tick. |
| Scoring | A kill is a point; a suicide (including your own rocket or a car you set burning) costs one. The first to `frag_limit` (10) ends the round: a `round_end` event, and every score resets. |
| Events | `events()` returns this tick's kill, explosion, round end and pickup events; the server sends them as I3 `event` messages. |

## Placeholder handling

Velocity is split into forward and lateral parts each tick. The pedal (ramped toward `throttle`, so keys and digital triggers build up) accelerates with a taper to top speed, or brakes against the motion, or reverses. The tyres remove at most `grip` of lateral speed per tick; anything above that slides, which is the whole drift model. The handbrake cuts grip to a quarter and adds yaw. Yaw follows the front wheels (ramped toward `steer`) times forward speed, capped. Wall hits keep a quarter of the normal speed as a bounce.

Measured with `replay handling` (model 0, the only one):

| | |
| --- | --- |
| Top speed | 11.8 blocks/s |
| 0 to 90% of top speed | 1.8 s |
| Brake from top speed | 0.8 s, 4.8 blocks |
| Coast from top speed | 2.8 s, 15.6 blocks |
| Full lock, full throttle | 360° in 2.0 s, circle 4.7 blocks across |
| Handbrake + full lock, 0.67 s from top speed | car turns 80° while still sliding at 7.5 blocks/s the old way |
| Ped walk / run | 1.8 / 3.3 blocks/s |

Every number is in `tuning.zig`. Authentic GTA2 handling comes later from clean-room behaviour notes; nothing here came from the original game or its decompilation.

## Determinism

- No floating point in `sim/` (`tools/check-no-floats.sh`).
- Randomness only from `abi.rand(seed, tick, entity, salt)`; the seed is in the state.
- The state is one extern struct with no implicit padding (checked at compile time). `mode` is a property of the host, not the state, so a client that loads a server state stays in predict mode.
- The golden replay in `tools/replay/golden/` is 10,000 ticks of 16 scripted bots on the test map (walking, jumping, shooting, getting in and out of cars, driving, two players leaving and rejoining). CI replays it natively and in WASM in Debug, ReleaseSafe and ReleaseFast, comparing `hash()` every tick with a save/run-ahead/load rewind every 100 ticks, and compares a 200-bot run's final hash between native and WASM. After an intended gameplay change, re-record with `zig build golden` in `tools/replay` and commit both files.

## Budget

| | Native | WASM (Node 22) |
| --- | --- | --- |
| `dm16` step, 16 bots + 100 peds + 24 cars | 0.02 ms (0.036 with M3) | 0.04 ms (bots included) |
| save + 10-tick replay + load | 0.21 ms | 0.34 ms |
| `dm200` step, 200 bots | 0.87 ms mean with M3 (0.42 in M1) | |
| State size | 36,128 bytes (`dm16`), 291,232 bytes (`dm200`) | |

The design budget is 0.5 ms per step in WASM for a full session; `dm16` with M3 is well inside it, and the 200-player load configuration is not a target. On real maps (wil, ste, bil, mp1/2/5-comp, through `formats.grid`) a `dm16` step with 16 bots is 14 to 26 µs natively.

## Soak on original maps

A local soak (not committed, since it needs the game files) runs `dm16` with 16 bots for 10,000 ticks on six original maps through `formats.grid.build`, and counts bodies that fall below the world or end up inside matter. It found two grid-mapping errors (now fixed in `formats/`) and two sim gaps (now fixed here): columns with no floor at any depth now act as walls instead of letting bodies fall out of the world, and bodies are half a block tall so they walk up ramps under one-block ceilings, while a jump stops at a ceiling. Result: zero falls on all six maps and zero bodies inside matter on five. On wil one ambient ped stays stuck at a ramp rail made of single wall faces, which needs the per-face wall table (`formats.grid.buildWalls`) that the 16-bit cell has no room for. That is the next collision step after M1.

## Notes for the interface owners

These are the places where I read the I1 draft a particular way. None changes a frozen type.

1. **Join spawn hint.** I1 says `arg` is a spawn hint without an encoding. I use bit 31 set, block x in bits 0-7, block y in bits 8-15 (`sim.spawnHint`); 0 lets the sim choose.
2. **`PlayerRow.car`** is the car the player is in now, and none on foot.
3. **`Controller` on cars.** A driven car's `Controller.player` is its driver's slot and its `in` is the driver's frame, so remote dead reckoning works on cars too. Unused cars have `no_player` and a neutral frame.
4. **Kind tables.** `pickup` is {Transform, Weapon, Appearance} in M3; `map_object` still has only a `Transform`.
5. **Event kinds.** M3 proposes `round_end` = 5 and `pickup` = 6 in I3, and explosion's `a` as the cause (0 rocket, 1 car).
5. **Proposed component 12, `Appearance { sprite: u16, remap: u16 }`,** on cars and peds, for the renderer (workstream B). It is in the tables, `views()` and `replicated` now, flagged here for the proposal step. `sprite` is the car model for cars and the ped type (0) for peds; the walk cycle comes from `Pedestrian.anim` on the client, so it costs no snapshot bytes. `remap` is `0xFFFF` (none) until we pick colours.
6. **Sim-owned components are lean.** `Collider` holds only flags (radius and mass come from the kind and model), `Vehicle` is 8 bytes (driver, model, pedal, steer, flags). Pedal and steer must replicate: they are state the next step depends on.
