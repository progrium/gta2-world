# Spike S2: sim cost and determinism

**Question:** is a fixed-point sim cheap enough to replay, and identical on WASM and native?

**Result: YES on everything measurable here.** Step time is about 50x under the
0.5 ms WASM budget, and 10,000-tick replays hash identically on native and in
WASM (Node and headless Chromium), including save/step/load rewinds. Firefox,
Safari and desktop Chrome runs still need to be done by hand (below); nothing
in the sim gives a reason to expect them to differ, since it is integer-only.

Measured on a cloud VM (4 vCPU Intel Xeon @ 2.1 GHz), Zig 0.17.0, ReleaseFast.

## Numbers

### 16 players (16 cars, 116 peds incl. 100 ambient), crowded into a 48x48 block area

| | Native | WASM, Node 22 (V8) | WASM, headless Chromium 157 |
| --- | --- | --- | --- |
| Step, mean | 0.007 ms | 0.008–0.010 ms | 0.008–0.010 ms |
| Step, p99 | 0.017 ms | 0.02–0.05 ms | (timer too coarse) |
| 10-tick replay (rewind) | 0.067 ms | 0.073–0.081 ms | 0.081 ms |
| save / load (memcpy) | 0.0006 ms | 0.0005 ms | 0.0006–0.0012 ms |
| hash (Wyhash of state) | 0.0009 ms | 0.005 ms | 0.008 ms |
| State size | 22,632 bytes | same | same |

Budget is 0.5 ms per step in WASM; measured is ~0.01 ms. A worst-case 10-tick
replay costs ~0.08 ms of a 16 ms frame. 16 saved states for rewind = 362 KB
(target was under 4 MB; state target was under 256 KB).

### 200 players' worth (200 cars, ~1,450 peds, ~100-125 live shots), same density over 170x170 blocks

| | Native | WASM, Node 22 | WASM, headless Chromium |
| --- | --- | --- | --- |
| Step, mean | 0.21 ms | 0.22–0.23 ms | 0.22 ms |
| Step, p99 | 0.36–0.38 ms | 0.32–0.39 ms | — |
| Step, max (10k ticks) | 1.1–5.8 ms (VM noise) | 3.4 ms | 2.9 ms |
| 10-tick replay | 1.9–2.0 ms | 2.1 ms | 1.8 ms |
| State size | 232,520 bytes | same | same |

At 30 Hz a tick is 33 ms, so one native server thread at 200 players uses about
0.6% of a core for the sim (the max outliers are VM scheduling, not the sim; the
p99 is under 0.4 ms).

### Determinism

| Check | Result |
| --- | --- |
| 10,000-tick replay of recorded 16-player inputs, hash compared **every tick**, native ReleaseFast vs ReleaseSafe vs Debug | match (final `1eab16d2aa3817a2`) |
| Same replay in WASM under Node 22 | match |
| Same replay in WASM in headless Chromium 157 | match |
| 100 rewinds during each replay (save, step 10 ticks ahead, load, continue) | all hashes still match |
| Bot-driven 200-player 10,000-tick run, native vs WASM (3,069 ped deaths, 413 car wrecks, 128k shots) | match (final `c01f092f591d13a5`) |
| No floats in `sim/` (`check-no-floats.sh`) | clean |
| Overflow: Debug and ReleaseSafe runs trap on integer overflow; none hit | clean |

What the 16-player replay exercises over 10,000 ticks: 16k body contacts, 180
damaging impacts, 10k shots (670 hits), 80 ped deaths and respawns, 16 car
wrecks, 50 car entries and 65 exits, so spawn/despawn, free-list reuse,
`Riding`, and slopes are all on the hashed path.

## What was built

Carried forward (per the design doc), in `sim/`:

- `ecs.zig` — the comptime static-archetype ECS (~250 lines). Each kind is a
  fixed-capacity struct-of-arrays `extern struct`, generated with `@Struct`.
  `world.each(.{Transform, Velocity}, ctx, f)` picks matching tables at comptime
  and emits plain loops; there are no runtime queries. Entity ids are index (12
  bits) + kind (4) + generation (16). Spawns reserve a slot immediately (so ids
  are deterministic) and become visible at `applyPending`, the one fixed point
  per tick, which also frees despawned slots onto a free stack held in state.
  Freed slots are zeroed so they hash the same whatever they held.
- `fixed.zig` — 16.16 fixed point, u16 binary angles, an integer-built sine
  table, integer atan2 and sqrt.
- `components.zig`, `input.zig` (I2, 8-byte frame), `map.zig` (256x256x8 block
  grid with solid and slope types, kept outside the saved state).
- `sim.zig` — the I1 shape: `init(map, seed, players)`, `step(inputs)`,
  `save(buf)`, `load(buf)`, `hash()`. Capacities are a comptime `Config`
  (`config_16`, `config_200`). Systems run in one hard-coded order: input,
  ped AI, vehicles (simple drift model), ped movement, weapons, body movement
  with axis-separated wall collision and slopes/falling, projectiles, a
  uniform-grid broadphase (rebuilt each tick in scratch, not saved), contacts
  with momentum exchange and damage, swept projectile hits, riders follow
  cars, health/death/respawn, `applyPending`.
- A layout guard rejects implicit padding in `State`; all components are
  `extern` with 4-byte-multiple sizes, so wasm32 and x86_64 produce the same bytes.

Throwaway, in `spikes/s2/`: a synthetic city map generator (street grid,
buildings 1–5 high, ramped platforms, plazas), scripted bots, the native
harness, the WASM exports, and the Node/browser harness.

## Caveats

- **The physics is a toy.** Cars and peds are circles; the car model is a
  forward/lateral grip split, not GTA2 handling. Real car-car collision with
  rotated boxes, the S5 handling model, weapons and AI will cost more. The
  16-player step has ~50x headroom against the budget, which is the margin
  those additions have to fit in.
- Single-tick timings in browsers are limited by timer resolution (0.1 ms in
  Chromium without cross-origin isolation, coarser in Firefox/Safari), so the
  page reports the mean over 100-tick batches, which is reliable.
- The grid is synthetic (no game data). It has the real dimensions and block
  types, so lookup cost is representative; real maps have more slope types.
- Measured on a server VM, not a mid-range laptop; laptop single-thread speed
  is usually similar or better.

## Browser runs still to do (Jeff)

Chrome (desktop), Firefox and Safari:

```sh
cd spikes/s2/web && python3 -m http.server 8642
# open http://localhost:8642/ in each browser and press Run (or open /#auto)
```

The page needs nothing built: `s2.wasm` and the recorded replay are committed.
It shows "hashes MATCH" or the first mismatching tick, plus step times. Pass is
"hashes MATCH" and a 16-player step under 0.5 ms. Please paste the output
block from each browser back into the thread.

## Reproduce

```sh
cd spikes/s2
zig build test                                   # sim unit tests
zig build -Doptimize=ReleaseFast                 # native s2 + s2.wasm
zig build web -Doptimize=ReleaseFast             # refresh web/s2.wasm
./zig-out/bin/s2 bench16 && ./zig-out/bin/s2 bench200
./zig-out/bin/s2 record web/replay 10000         # regenerate inputs + hashes
./zig-out/bin/s2 verify web/replay               # also try -Doptimize=ReleaseSafe / Debug
./zig-out/bin/s2 hash200
node run-node.mjs                                # WASM replay + bench under Node
./check-no-floats.sh
```
