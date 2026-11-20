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
| Players | `join` spawns a ped on foot, at the hint or on a random pavement cell; `leave` despawns it and frees a car it was driving. Dead players respawn on foot after 70 ticks (2.3 s). |
| On foot, tank | `steer` turns, the turn speed building up while held (to 12° a tick); `throttle` moves forward or back at the one running pace, 1/16 block a tick (`run` changes nothing). A blocked step slides along a wall at half speed. |
| On foot, direct | With the `direct` bit, the ped moves along `aim` at a speed set by `throttle` and turns its body toward it (about 650°/s). |
| Jump | A fresh `handbrake_jump` press on the ground jumps: 16 ticks moving forward at the running pace, with slower turning, at the take-off height (a jump never drops into a gap; it falls once the jump ends). |
| Cars | Handling from the behaviour notes and the player's `.gci` (below). |
| Enter, exit | `enter_exit` (rising edge) on foot enters the nearest free car within 1.5 blocks of a point half a block ahead, if it is slower than 0.2 a tick. In a car, below 0.3 a tick, it exits on the driver's side (left of travel), else the right, else not at all. Entering sets `Riding.vehicle`, the car's `Vehicle.driver` and `Controller.player`, and `PlayerRow.car`; exiting clears them. `PlayerRow.car` is the car the player is in now, none on foot. |
| Map collision | Walls are the map's wall faces (`Grid.walls`, shape-and-map-collision.md 3.2-3.3): one-block lines on block boundaries, not solid cubes. A ped's square, a car's rotated rectangle and a shot's path are tested against them at the levels from a step above the body's feet to its top, so the face of the block at the top of a ramp does not stop you climbing onto it; bullets stop only at bullet-wall faces. Floors and ramps come from the cells: every cell shape reduces to "is there matter at this point, and how high is its top". Ramps (all 44 codes), partial blocks (53-61) and diagonal walls (45-48) are exact; diagonal slopes (49-52) act as diagonal walls for now. Peds climb 5/16 of a block, cars 7/10 (so a car's nose does not catch at the top of a ramp). Bodies fall, land and follow ramps down. |
| Bodies | Peds are circles sampled at 9 points; cars are boxes sampled at 8 points against the map and circles against each other. Moves are sub-stepped at a quarter block so nothing tunnels. |
| Weapons | A pistol for players on foot (M3 adds the rest, below). |
| Ambient | `dm16` spawns 24 cars on roads (aligned with the lane arrows) and 100 peds that wander on pavements and turn back at roads and drops. M3 makes 5 in 8 of the cars traffic. |
| Predict mode | Only `Predicted` entities step; others are fixed obstacles that are never written. Projectile spawns and every despawn become intents. Commands are ignored. Entering a car the client does not predict waits for the server. |

## What M3 adds

The rules follow the clean-room behaviour notes in `docs/behaviour/` where they cover them (the file is named beside each number in `tuning.zig`); the rest is our own, tuned by feel.

| Area | Behaviour |
| --- | --- |
| Weapons | Pistol (infinite), machine gun (a bullet every 2 ticks), shotgun (5 pellets 6° apart, short range), rocket launcher (`weapons.md`, `projectiles.md`). Ammo is kept in tenths of a displayed round (a machine-gun round is 10 bullets). Shots start a quarter block ahead and are not fired if the point halfway there is in a wall; they carry the shooter's velocity and vanish at the end of their range. Bullets do 10 to a player and 25 to anyone else (the pistol twice that), and 1600 (pistol) or 800 raw damage to a car. `weapon_next`/`weapon_prev` cycle through the ones with ammo. |
| Explosions | An explosion is an entity in the projectile table (`Projectile.weapon` has `explosion_bit`) with a 99-tick timer (`explosions-and-damage.md`). A rocket makes a small one (radius 0.5) on whatever it touches, a car a radius-1 one. Distances are square, with a vertical reach of 0.2. On its first tick it pushes cars outward; above 50 it throws standing peds (killed within half the radius; within it a non-player is killed and a player knocked down; up to twice the radius, above 70, knocked over) and, in ticks 81-89 and 51-59, does 32000 raw damage to cars in the radius, so explosions chain. |
| Car damage | `Health.hp` on a car is 32000 minus its damage. Hits add raw damage times the model's anti-strength (`car-collision.md`): impacts with walls and cars by impulse, (1 + e) x closing speed x mass x 200 (restitution 0.25 and 0.5; below 0.03 a tick, none), bullets and blasts by their figures. From 16000 a car burns, from 25000 it burns on by itself, at 32000 it explodes: everyone inside dies, credited to whoever destroyed it, and it becomes a wreck that cannot be entered, then despawns and a new traffic car appears elsewhere. |
| Knock-downs | A car moving into a ped hands him a knock-back of about twice its closing speed (`ped-movement.md` 3.8): under 0.1 he is knocked over; from 0.1 a non-player dies; a player is thrown and knocked down up to 0.3 (killed in between if a player was driving); from 0.3 anyone dies. Thrown bodies fly with gravity 0.02, slide to rest, then get up, lie a while, or die. The AI driver stops for 100 ticks. |
| Pickups | Weapon and health pickups (2 + 2 per player) appear on pavement near players, spin, and expire after a minute. Health restores full health. |
| Traffic | Cars with `flag_ai` follow lane arrows; at a junction they go straight on if the road goes on, else pick left or right once (`traffic-and-car-ai.md`). They keep to the lane centre, ramp a speed setting toward 0.1 a tick (up 0.01, down 0.08 a tick), brake for bodies 1.75 blocks ahead (1 while turning, with the handbrake above 0.4), halt 100 ticks after hitting someone and back out when stuck. Getting in takes the car over. |
| Ambient | Peds and traffic far from every player are moved back near one, at most 2 per tick. |
| Scoring | A kill is a point; a suicide (including your own rocket or a car you set burning) costs one. The first to `frag_limit` (10) ends the round: a `round_end` event, and every score resets. |
| Events | `events()` returns this tick's kill, explosion, round end and pickup events; the server sends them as I3 `event` messages. |

## Car handling

`sysCarControl` follows `docs/behaviour/car-handling.md` step by step, in fixed point: up and down become throttle, foot brake or reverse by the direction of travel (a change of direction costs a tick with nothing held); a gas pedal of 0-5 ramps 0.25 a tick, turbo doubles its share from 3; three gears by speed for a player driver, with damage over 16000 cutting the pull in gears 2 and 3; each axle's tyre pushes against its sideways slip (grip 1 +- turn in while steering, the rear cut by the handbrake slide value) and rolling drag 0.139 plus its brake share, the rear axle steering slightly against the front below 0.6 a tick and scaled by rear end stability; integrate by mass and moment of inertia, dead zones, damping 0.9 / 0.97 / 0.88, the speed cap (max speed forward, gear 2 speed back), and the lane-arrow snap. Spin (`Velocity.spin`) is in radians a tick, fixed point.

Per-model numbers come from the player's `.gci` (nyc.gci) and the style's car info through `tuning.deriveModel` (mass x 1.1, centre of mass and inertia from the sprite size and front mass bias, axles at the wheel offsets); hosts install them with `tuning.setCarModels`. Without the files every car uses `default_spec` (ours, a mid-range saloon). Trains, trams and tanks are not used as ambient cars. Slope roll-back, oil and trailers are not done.

Measured with `replay handling` (the default model):

| | |
| --- | --- |
| Top speed | 9.6 blocks/s |
| 0 to 90% of top speed | 2.4 s |
| Brake from top speed | 0.9 s, 2.1 blocks |
| Coast from top speed | 2.8 s, 6.3 blocks |
| Full lock, full throttle | 360 degrees in 2.2 s, circle 2.9 blocks across |
| Ped run | 1.9 blocks/s |

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

A local soak (not committed, since it needs the game files) runs `dm16` with 16 bots for 10,000 ticks on six original maps through `formats.grid.build`, and counts bodies that fall below the world or end up inside matter. It found two grid-mapping errors (now fixed in `formats/`) and two sim gaps (now fixed here): columns with no floor at any depth now act as walls instead of letting bodies fall out of the world, and bodies are half a block tall so they walk up ramps under one-block ceilings, while a jump stops at a ceiling. Result: zero falls on all six maps and zero bodies inside matter on five. On wil one ambient ped stays stuck at a ramp rail made of single wall faces, which needed a per-face wall table; M3 added it (`Grid.walls`). A native check walked a ped up all 775 ramps on wil with a floor at the top: every one that stops ends at a real wall face (a fence at the top of an embankment, or a block the ramp runs into).

## Notes for the interface owners

These are the places where I read the I1 draft a particular way. None changes a frozen type.

1. **Join spawn hint.** I1 says `arg` is a spawn hint without an encoding. I use bit 31 set, block x in bits 0-7, block y in bits 8-15 (`sim.spawnHint`); 0 lets the sim choose.
2. **`PlayerRow.car`** is the car the player is in now, and none on foot.
3. **`Controller` on cars.** A driven car's `Controller.player` is its driver's slot and its `in` is the driver's frame, so remote dead reckoning works on cars too. Unused cars have `no_player` and a neutral frame.
4. **Kind tables.** `pickup` is {Transform, Weapon, Appearance} in M3; `map_object` still has only a `Transform`.
5. **Event kinds.** I3 has `round_end` = 5 and `pickup` = 6 from M3 (signed off), and explosion's `a` is the cause (0 rocket, 1 car).
5. **Proposed component 12, `Appearance { sprite: u16, remap: u16 }`,** on cars and peds, for the renderer (workstream B). It is in the tables, `views()` and `replicated` now, flagged here for the proposal step. `sprite` is the car model for cars and the ped type (0) for peds; the walk cycle comes from `Pedestrian.anim` on the client, so it costs no snapshot bytes. `remap` is `0xFFFF` (none) until we pick colours.
6. **Sim-owned components are lean.** `Collider` holds only flags (radius and mass come from the kind and model), `Vehicle` is 8 bytes (driver, model, pedal, steer, flags). Pedal and steer must replicate: they are state the next step depends on.
