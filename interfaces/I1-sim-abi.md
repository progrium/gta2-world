# I1. Sim ABI

**Status:** frozen at v1 (`abi_version = 1`), 2026-11-19. Changes go through the proposal process in [README.md](README.md).
**Between:** `sim/` and its two hosts, `client/wasm/` and `server/`. Read-only views are also used by the renderer (workstream B) and tools.
**Code:** [`zig/src/abi.zig`](zig/src/abi.zig) (types and the `checkSim` conformance check), [`zig/src/stub.zig`](zig/src/stub.zig) (a conforming stub for B–E), [`ts/src/abi.ts`](ts/src/abi.ts).

## Shape

A sim is a Zig type built for a named, comptime `Config`. It is not a C library: both hosts are Zig and link `sim/` as a module. `sim/` must call `abi.checkSim(Sim(cfg))` for every configuration it builds; the check fails compilation if any function below is missing or has a different type.

| Declaration | Type | Contract |
| --- | --- | --- |
| `config` | `abi.Config` | The configuration this type was built for. |
| `state_size` | `usize` | Size of the saved state in bytes. |
| `layout_hash` | `u64` | `abi.layoutHash(State)`. Covers every field name, offset, size and capacity. I3 refuses a peer whose value differs. |
| `init` | `fn (*S, *const Grid, InitParams) void` | Resets everything. Keeps a pointer to the grid, which must outlive the sim. No allocation, now or later. |
| `step` | `fn (*S, []const Frame, []const Command) void` | Advances one tick. `frames.len == config.max_players`, indexed by player slot; slots without a player get the neutral frame. Commands apply first, in order, then systems run in their one fixed order. |
| `save` | `fn (*const S, []u8) usize` | Copies the state into `buf` (at least `state_size` bytes), returns `state_size`. A plain memcpy. |
| `load` | `fn (*S, []const u8) error{BadSize}!void` | Inverse of `save`. Fails only if `len != state_size`. |
| `hash` | `fn (*const S) u64` | `abi.stateHash(stateBytes())`, Wyhash seed 0. Equal on every target for equal inputs. |
| `tick` / `setTick` | `fn (*const S) Tick` / `fn (*S, Tick) void` | Number of steps taken since `init`. `setTick` is for clients loading replicated state. |
| `stateBytes` | `fn (*const S) []const u8` | The live state, read only. |
| `views` | `fn () []const ColumnDesc` | Where every table column lives inside `stateBytes()` (below). Comptime constant. |
| `intents` | `fn (*const S) []const Intent` | Spawns and despawns the last `step` suppressed in `.predict` mode. Empty in `.authoritative` mode. |
| `playerRow` | `fn (*S, u32) *PlayerRow` | The row for a player slot. |
| `replicaPut` / `replicaRemove` | `fn (*S, EntityId) bool` / `fn (*S, EntityId) void` | Client only: make the slot named by the id alive with that generation (zeroing it if the generation changed), or free it. Returns false if the id is out of range for this config. |

The client host writes replicated component values straight into the columns that `views()` describes, then sets `Predicted.on` per its policy. No other writes into the state are allowed from outside `sim/`.

## Numbers and units

- **Fixed point:** `Fx` is signed 16.16 in an `i32`. One map block is `1.0` (65536). Positions are in blocks, velocities in blocks per tick.
- **Angles:** `u16` binary angle, 65536 per turn, wrapping. `0` points along +x (east) and angles grow toward +y (south). Because y grows downward on screen, positive is clockwise on screen. The unit vector for angle `a` is `(cos a, sin a)`.
- **Ticks:** `u32`, 30 per second, 0 at `init`.
- **Axes:** x grows east, y grows south, z grows up, as S1's parser reads the map.

S5's handling model uses 14-bit fixed point, 1440-step angles and heading 0 along +y. It must be converted to these units when it moves into `sim/`. Its internals may keep their own precision, but every value crossing a component is in the units above.

## Modes

`InitParams.mode` selects one of:

- **`.authoritative`** (server, replay runner, golden test). Steps every entity, applies spawns and despawns at the one fixed point per tick.
- **`.predict`** (client). Steps only entities whose `Predicted.on != 0`. Every other entity keeps its replicated values and is a fixed obstacle for collisions. Spawns and despawns are not applied; each becomes an `Intent`, which the client turns into a cosmetic effect until the authoritative entity arrives in a snapshot.

The sim never writes `Predicted`. The client host sets it. The policy, from S3, is: the own player's ped and vehicle, plus every car and ped (including remote players) within the predict radius of the own player, with hysteresis. Remote players inside the radius are dead-reckoned on their last replicated `Controller.in`.

## Determinism rules

These are enforced in CI as before, plus one change to randomness.

1. No floating point in `sim/`.
2. No pointers in the saved state, only indices and `EntityId`s.
3. Iteration order is array order. No hash maps.
4. **Randomness comes only from `abi.rand(seed, tick, entity, salt)`**, a keyed hash, not from a generator whose state advances. A client holding only part of the world then draws the same number as the server for the entities it holds. S2's `sim/` keeps a sequential generator in `State` and must switch.
5. The state has no implicit padding (S2's layout guard stays), and every component is an `extern struct` of fixed-size integers with a size that is a multiple of 4.
6. Golden replay: recorded frames and commands run on native and WASM, and `hash()` is compared every tick.

## Entities

`EntityId` is a `u32`: index in bits 0–11, kind in bits 12–15, generation in bits 16–31. `EntityId.none` is `0xFFFFFFFF`. The low 16 bits (kind and index) are the *handle* that I3 uses.

Kind numbers are part of the ABI. They are append-only and a retired number is never reused.

| Kind | Number |
| --- | --- |
| car | 0 |
| ped | 1 |
| projectile | 2 |
| pickup | 3 |
| map_object | 4 |
| free | 5–14 |
| player row (wire only) | 15 |

Each kind's capacity is at most 4096 (12 index bits) and a multiple of 4.

## Components

Component ids are part of the ABI. They are append-only and never reused.

| Id | Component | Layout frozen here? |
| --- | --- | --- |
| 1 | `Transform { x, y, z: Fx, heading: Angle, _pad: u16 }` | yes |
| 2 | `Velocity { vx, vy, vz: Fx, spin: i32 }` | yes |
| 3 | `Collider` | owned by `sim/` |
| 4 | `Health { hp: i32, last_hit_by: EntityId }` | yes |
| 5 | `Controller { player: u32, prev_buttons: u32, in: Frame }` | yes |
| 6 | `Vehicle` | owned by `sim/` |
| 7 | `Pedestrian` | owned by `sim/` |
| 8 | `Riding { vehicle: EntityId }` | yes |
| 9 | `Weapon` | owned by `sim/` |
| 10 | `Projectile` | owned by `sim/` |
| 11 | `Predicted { on: u32 }` | yes |
| 12 | `Appearance { sprite: u16, remap: u16 }` | yes (accepted 2026-11-20) |

The frozen layouts are the ones other workstreams read: the renderer reads `Transform`, `Riding` and `Appearance`, and the netcode reads `Controller` and `Predicted`. Components owned by `sim/` can change without a proposal. Their layout still reaches the other side through `layout_hash`, and their I3 codecs are generated from the type.

`PlayerRow` (32 bytes) is one per player slot and lives in the state. It has `ped`, `car`, `kills`, `deaths`, `score`, `respawn_timer` and `flags` (`active` = 1, `connected` = 2). `kills` holds frags (kills less suicides, which decide the round) and `score` holds points from the scoring notes; until M3 both counted frags. Same layout.

## Views

`views()` returns `ColumnDesc { kind: u8, _pad: u8, component: u16, offset: u32, stride: u32, count: u32 }`, 16 bytes each. `offset` is from the start of `stateBytes()`. `component` is either a `ComponentId` or one of these special values:

| Special | Value | Element |
| --- | --- | --- |
| `slot` | 0x100 | `u8` per entity: 0 free, 1 alive, 2 spawning, 3 dying |
| `generation` | 0x101 | `u16` per entity |
| `len` | 0x102 | one `u32`, the kind's high-water mark |
| `player_rows` | 0x103 | `PlayerRow` per slot, kind 15 |
| `tick` | 0x104 | one `u32` |

A reader visits entity `i` of a kind when `slot[i] == alive`. The renderer stub can work from a recorded `stateBytes()` buffer plus the view table, with no sim linked in.

## Commands

`Command { op: u8, slot: u8, _pad: u16, arg: u32 }`, 8 bytes. Commands are the only way players enter or leave. They replace S2's `num_players` argument to `init`.

| Op | Meaning |
| --- | --- |
| `join` (1) | Activate `slot` and spawn its ped. `arg` is a spawn hint; 0 lets the sim choose. |
| `leave` (2) | Despawn the slot's entities and clear the row. The server issues this 10 s after a disconnect unless the player reconnects. |

The server records commands with frames, so a replay reproduces joins. Clients in `.predict` mode pass no commands.

## Static map

`Grid` is `blocks[z][y][x]` of `Cell = u16`, with 256 × 256 × 8 cells (1 MiB). It sits outside the saved state and is built by `formats/` from the `.gmp`.

| Bits | Field |
| --- | --- |
| 0–2 | shape: air 0, solid 1, slope 2, partial 3, water 4, slab 5 (M3: a wall-less floor such as an overpass deck; only a thin top layer is matter, so bodies pass under it) |
| 3–8 | GTA2 slope code 0–63 (0 = none) |
| 9–10 | ground: none 0, road 1, pavement 2, field 3 |
| 11–14 | lid road arrows: +y, −y, +x, −x |
| 15 | reserved, zero |

S5's lane snapping needs the arrows, and traction needs the ground type. S2's one-byte cell is not enough for the 61 real slope codes.

**Accepted in M3 (Jeff, 2026-11-20):** `Grid` also has `walls[z][y][x]` of `WallBits = u8` (0.5 MiB more), the map's wall faces. shape-and-map-collision.md makes a wall a one-block line segment on a block face, not a solid cube; with only `Cell`, a fence or a single wall face had to become a whole solid block, which players met as invisible walls.

| Bits | Field |
| --- | --- |
| 0–3 | wall on the left (x), right (x+1), top (y), bottom (y+1) face: stops cars and peds |
| 4–7 | bullet wall on the same faces: stops projectiles |

`formats/` leaves out a ramp's own side faces and every face of a partial block (codes 53–61), as the notes do. With walls carried separately, a block with wall faces is no longer `solid`: it becomes `slab` if it has ground or a lid, otherwise `air`.

## Configurations

`Config { name, max_players, car/ped/projectile/pickup/map_object_capacity, ambient_cars, ambient_peds }`. The named configuration and its capacities go into `layout_hash`, so a client must be built with the server's configuration. `dm16` is the first-release configuration. S2 measured 22.6 KB of state for a similar 16-player mix, so `dm16` stays far under the 256 KB target. Larger configurations, such as S2's `config_200`, are added the same way.

## Accepted proposals

**2026-11-20, approved by Jeff.**

1. **Component 12, `Appearance { sprite: u16, remap: u16 }`**, on cars and peds, asked for by the renderer (workstream B) and added by the sim (workstream A). `sprite` is relative to the kind's sprite group: the car model for cars, the ped type for peds. `remap` is a palette remap of that group, or `Appearance.no_remap` (`0xFFFF`). It is replicated like any other component. It is an addition old readers skip, so `abi_version` stays 1; the column changes `layout_hash`, so old builds are refused anyway.
2. **Golden replay re-recorded.** Moving to keyed randomness (`abi.rand`, determinism rule 4) changed every state hash, so `tools/replay/golden/` was recorded again from the conforming sim. The new recording is the reference for CI.

**2026-11-20, approved by Jeff (M3).**

1. **`Shape.slab` (5):** a floor with no walls, such as an overpass deck.
2. **`Grid.walls`:** the wall-face table described above.
3. **`PlayerRow` meanings:** `kills` holds frags and `score` holds points. Same layout.
4. **`Shape.water` (4) is deep water,** a surface at the top of its cell that bodies rest on (peds drown, cars sink), where it was "no floor". No map produced it before. Approved within the project under the rule below.

From here on, small additive interface changes are approved within the project and recorded in this section; changes that break compatibility or change the golden replay still go to Jeff.
