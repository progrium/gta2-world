# Plan: all the behaviour notes in, single player first

Status: draft for Jeff, 2026-11-20. Written from `docs/behaviour/` (29 notes), the integration branch `claude/project-thread-6bbchu` at `fda31ac`, and `sim/README.md`.

Goal: set online aside and make the offline game behave as close to the original as the notes allow: a level loads its own script, the city is populated by it, phones ring and give missions, gangs and police react, the player has lives, a multiplier, wanted stars and a death/arrest cycle, and it all holds up under replay, soak and headless play tests.

Clean-room rule, unchanged: implementers use only `docs/behaviour/`, the public format docs, footage and Jeff's own data files. Never open gta2_re or the tainted S5 branches (`spike/s5`, `s5-car-loader`). Never commit game data. Tests that need a real level read it from a local `--data` folder and are not run in CI.

---

## 1. Where the code stands

- `sim/` is one 2,949-line `sim.zig` plus `tuning.zig`, `components.zig`, `map.zig` and one 949-line `sim_test.zig`. Every system is a function in `sim.zig`, called in one fixed order from `step()`.
- Configurations: only `dm16` (16 players) and the 200-player load config. No single-player config, no per-level data beyond the `Grid`.
- `formats/` parses `.gmp` (including zones, map objects, lights), `.sty` (tiles, sprites, car info) and `.gci`. Zones and map objects are parsed but never reach the sim. There is no `.scr` or `.gxt` parser.
- The grid carries shape, slope, ground type and the four green lane arrows per cell, plus wall faces. It has no water or electrified surface, and no red arrow bits.
- The client (`client/wasm/src/game.zig`, `client/shell/src/ui/gameScreen.ts`) is a deathmatch HUD: weapon, ammo, kill feed, scoreboard. The camera in `client/render/ts/src/camera.ts` already follows `camera.md` (lift, lead-ahead, smoothing, shake).
- Golden replay: 10,000 ticks of 16 bots on the synthetic test map, `dm16`, hashed every tick, native and WASM, in CI.

## 2. Gap analysis, note by note

"Done" means the sim follows the note today (named in `sim/README.md` or `tuning.zig`). The last column is the workstream from section 4 that owns the gap.

| Note | Done today | Missing | Owner |
|---|---|---|---|
| car-handling | All of the per-tick driven-car rules, gears, turbo, damage cut, arrow snap, `.gci` and CARI numbers | Oil slick (30-tick spin, axle effects, 30 damage), slope roll-back, conveyor push, trailers, AI-driver differences beyond gears | C |
| car-collision | Sub-steps, impulses, spin, wall hits, impact damage, unstick nudge | Re-check 3.6 case details and 3.7 map edge against the note; crushing between cars; ramming a police car feeds wanted (E) | C |
| shape-and-map-collision | Wall faces, slopes, partial blocks, diagonal walls | Diagonal slopes 49-52 are diagonal walls for now; 3.5 map edge; object sprites (B) | C |
| map-geometry | All 44 ramp codes | Diagonal slopes 49-52 as real slopes | C |
| car-height | 3.1-3.4 (ground follow, ramp launch, air, tipping) | 3.5 sinking in deep water, 3.6 crusher riding up, 3.7 towed pairs and trains, 3.8 physics sleep | C (3.6 with B) |
| ped-movement | Turning, the one pace, walls, ramps, jumps, being hit by a car | 3.5 falling with fall damage and lethal landings (needs frame timing), 3.7 drowning and electrified floors, knocked-down animation states for the renderer | C |
| entering-and-exiting-cars | Instant enter within 1.5 blocks, exit by side | 3.2 walking to the door, door choice, 3.3 door animation, carjack with pull-out, refused (script-locked) cars, thrown off a moving car, passengers, 3.4 AI car thieves, 3.5 exit sequence | D2 |
| weapons | 3.1-3.5 (all ten hand weapons) | 3.6 electro baton, 3.7 vehicle weapons (car guns, jeep, tank, water cannon, oil, mines, car bomb), 3.8 AI test shots | G (3.8 in D1) |
| projectiles | 3.1-3.3 | 3.4 death causes (for the death message), per-entity "hit by weapon X" record for scripts, grenade bounce (note open) | G, A1 |
| explosions-and-damage | All of it | Fire spread waits for the fire note | none until the note |
| camera | Follow, lift, lead, smoothing, shake (client) | 3.3 suspicion, 3.6 elevation (script-driven) and panning, staying on the body double after death | H |
| scoring | Kill and car scores, combos, wreck and hijack values, with the multiplier fixed at 1 | The multiplier, cash vs points, victim classes (police, gang, emergency, Elvis), run-over in a stolen car, buses, drowning, 3.4 accuracy statistics | G |
| wanted-level | Nothing | All: points and stars, what earns points, crime reports, cops noticing, one-star timeout, pursuit state machine and crew targets, busted | E |
| police-ai | Nothing | All: dispatch, chase box-in and ram, searching, roadblocks, on-foot arrest, SWAT/FBI/army, sirens | E |
| power-ups-death-and-arrest | Health, armour, invulnerability, double damage, fast reload; 70-tick respawn | Multiplier, extra life, jail card, cop bribe, electro-fingers, invisibility, respect, instant gang; 3.2 wasted with lives, body double, losing weapons and game over; 3.3 busted; 3.4 nearest restart zone | G (electro-fingers, invisibility and instant gang effects in D1/D2) |
| gangs-and-respect | Nothing | Respect per gang, kill and hijack reactions, mission respect steps, weapon choice | D2 |
| ped-ai | Wandering on pavement | All of it: two-layer objectives, threat detection, best-target search, fleeing, reacting, chasing, weapon choice and aim, melee, following, groups and recruiting, gang fights, gangs toward the player, electro-fingers, invisibility, occupations | D1 (groups and gangs in D2) |
| traffic-and-car-ai | Lane following, straight-on junctions, speed ramp, braking for bodies, halt after a hit, backing out | Red arrow bits, junction right-of-way sweep, settle into lane, seek road and abandoning, car-ahead and overtaking a stalled queue, honking, crossing markers, 3.6 the light cycle, 3.7 chase/follow/patrol tasks with a route planner | F |
| crushers-and-garages | Nothing | Crusher sequence; garage parking and cranes are only outlined in the note | B |
| mission-scripts | Nothing | All: `.scr` loading, mission sub-scripts, declaration pass, threads, triggers, fail on death or arrest | A1 |
| script-flow-control | Nothing | All | A1 |
| script-counters | Nothing | All | A1 |
| script-messages | Nothing | All (sim side: message, brief queue, timer, counter displays; client draws them) | A1, H |
| script-missions | Nothing | All: start (274, the 263 gang-phone gate), end (273, 391 cleanup), bonus challenges 288-294 and 402, kill frenzy 422/423 | A1 |
| script-declarations | Nothing | All 16 families | A2 (with B, D2, E, F) |
| script-cars | Nothing | All | A2 (with C, F) |
| script-characters | Nothing | All | A2 (with D1) |
| script-objects | Nothing | All | A2 (with B) |
| script-player | Nothing | All | A2 (with G, E) |

Notes the README lists as still to write, which block parts of this plan: spawning (zone densities), objects (pickups, mines, doors, phones), fire, public transport, emergency services, cranes, skid marks and particles, HUD, animation frame timing, save games. Section 7 says how each workstream works around them.

## 3. Foundation first: W0 (one thread, before the others)

Today every workstream would edit `sim.zig`, `components.zig`, `tuning.zig`, `sim_test.zig` and `step()`. W0 removes that overlap and fixes the interfaces so the rest can run in parallel. It changes no behaviour.

1. **Split `sim.zig` by system** into `sim/sys/*.zig` (input, ped control, car control, weapons, explosions, movement, contacts, projectile hits, pickups, health, scoring, respawn, ambient, traffic). `sim.zig` keeps the I1 surface, the state, and `step()`. Check: the golden replay matches byte for byte, native and WASM.
2. **Split `components.zig`, `tuning.zig` and `sim_test.zig`** the same way (`sim/comp/`, `sim/tuning/`, `sim/test/`), each re-exported from the old file so imports keep working.
3. **Add the `sp` configuration**: one player, larger ped and car capacities, an `objects` kind used for real (phones, doors, generators, crossing markers, oil, mines). `dm16` keeps its layout until Jeff's golden decision (section 6).
4. **Add the level input.** `Level` is static data next to the `Grid`, outside the saved state, built by `formats/`: the parsed `.scr` program and string table, the map zones (restart, gang areas, lights, named zones) and map objects. `sim.attachLevel(*const Level)` is a non-I1 call, like `spawnCarAt`. With no level attached the sim runs as today.
5. **Extend the grid** (small additive I1 change, recorded in I1's accepted section): a `Grid.surface` table per cell with the red arrow bits (traffic-and-car-ai 2), deep water and electrified tiles (ped-movement 3.7, car-height 3.5). `formats/grid.zig` fills it from the `.gmp` and, when given, the style's tile flags.
6. **Reserve the shared numbers once**, so no two branches pick the same: new component ids (Objective, Object, CarTask, Career, ...), new sim event kinds (message, brief, wanted change, wasted, busted, mission start, pass and fail, phone ring), new `Pedestrian` occupation and state values, and the SP state block layout (`career`, `police`, `gangs`, `script`, `hud`, `lights`), each sub-struct in its own file owned by one workstream.
7. **Fix the `step()` order** with every new system present as an empty stub in its owner's file: script threads, gang and wanted bookkeeping, police, ped objectives, traffic and car tasks, controls, weapons, movement, contacts, hits, objects (doors, generators, crushers, conveyors), surfaces (water, electrified), death and arrest, respawn, ambient, lights.
8. **Write the cross-workstream API stubs** (section 5) as real functions that compile and do nothing or return defaults, so A2 and the client can build against them from day one.
9. **Frame timing:** `sim/anim.zig` holds the ped animation frame delays the notes leave open, tagged "ours" until the animation-timing note lands. Fall damage, door entry and melee all count frames through it.

Size: medium. It touches every sim file, so nothing else on `sim/` starts until it merges. Q's tooling and H's level loading can start alongside it (they touch `tools/` and `client/` only).

## 4. Workstreams

Each runs on its own branch off the integration branch after W0 merges, and owns the files listed. "Reads" means it calls another workstream's API (section 5) and does not edit that file.

### A1. Script engine

Notes: mission-scripts, script-flow-control, script-counters, script-messages, script-missions.

- `formats/scr.zig`: the main file (6000 offsets, 64 KB of commands, string table) and mission sub-scripts.
- `tools/scrasm/`: a small assembler that writes `.scr` files from a text form of command types and parameters, so tests and CI use hand-written scripts and never game data.
- `sim/script/vm.zig`: threads in creation order, one command a tick, EXEC and WHILE_EXEC blocks, the 0xFFFF end, gosub stack, the combinator and its "not", wait and delay, start and stop thread, the handle table looked up by command number, the fail-on-death-or-arrest two-level unwind with the random fail message, phone, car and area triggers, the per-entity weapon-hit record.
- `sim/script/cmd_flow.zig`, `cmd_counters.zig`, `cmd_messages.zig`, `cmd_missions.zig`: those families, including the 263 gate, 391 cleanup list, bonus challenges and the kill frenzy.
- `sim/sp/hud.zig`: the sim-side display state (banner, brief queue, timer, counters, arrow target) that the client reads.
- Owns: `formats/scr.zig`, `tools/scrasm/`, `sim/script/vm.zig` and the four family files, `sim/sp/hud.zig`, `sim/test/script_*`.
- Verify: one test per numbered rule in the five notes, written with `scrasm`; a coverage report (`replay scr-coverage <file.scr>`) listing every command type a real level uses and whether it has a handler. On Jeff's data: every level's script loads and its declaration pass runs without an unknown type.
- Depends on: W0. Size: large.

### A2. Script world commands

Notes: script-declarations, script-cars, script-characters, script-objects, script-player.

- One file per family, `sim/script/cmd_decl.zig`, `cmd_cars.zig`, `cmd_chars.zig`, `cmd_objects.zig`, `cmd_player.zig`, each a thin layer over the owning workstream's API. A command whose system has not landed yet calls the stub and is marked "stubbed" in the coverage report.
- Settles the heading question for script positions from data: parked cars declared on roads must line up with the lane arrows, and declared peds on pavements with the kerb. That fixes the script heading convention without guessing.
- Owns: those five files and `sim/test/script_world_*`.
- Verify: per-command tests with `scrasm`; on Jeff's data, the declaration pass of each level puts parked cars on road or parking cells (no car inside a wall), peds on walkable cells, and the coverage report goes from "stubbed" to "done" as systems land.
- Depends on: A1's VM interface (from W0's stub, so it can start in wave 1 with the families that already exist: player ped, cars, characters, score). Size: large, but in many small pieces.

### B. Objects and city furniture

Notes: crushers-and-garages, the object parts of script-declarations (2.4, 2.7-2.9, 2.12) and script-objects, traffic-and-car-ai 3.6 (lamps and crossing markers).

- The `Object` component and kind: model, value byte, state, timer. Phones (ring, answer, timeout, dead phone), doors (face doors, the shared animation list, open and close rules, presence area), generators (random respawn between two delays, the by-car-model power-up list), destructor and conveyor areas, crushers (the four-piston sequence; not reported as a crime), the light cycle (526 ticks) with lamp objects and crossing markers placed once from the arrows, oil patches and mines as objects (dropped by G's vehicle weapons).
- Pickups move under objects where the script places them (power-up and weapon pickups from generators and declarations), keeping today's deathmatch spawner for `dm16`.
- Garages and cranes: only the outlines in the notes, so the API exists (park in garage, crane hooks) with "ours" behaviour flagged until the cranes note lands.
- Owns: `sim/sys/objects.zig`, `sim/sys/doors.zig`, `sim/sys/generators.zig`, `sim/sys/crusher.zig`, `sim/sys/lights.zig`, `sim/comp/object.zig`, `sim/test/objects_*`.
- Verify: tests per rule (door rules each open and close for the right body, a generator never spawns faster than its minimum, the light cycle phases, a crushed car is destroyed without a wanted point). Headless: a door declared in a synthetic script opens for a car and closes after its delay.
- Depends on: W0. Size: large.

### C. Bodies and surfaces

Notes: the remaining parts of ped-movement, car-height, car-handling, car-collision, shape-and-map-collision, map-geometry.

- Falling with fall damage (frames 12 and 13 deal 4, frame 14 lethal, thrown off a car on a lethal landing, a non-lethal landing on a car becomes a jump), drowning (fire out, kill credit within 50 ticks), electrified floors (+3 shock a tick), sinking cars (shrink, stop, hold an explosion timer at 50, destroy with occupants), oil slick handling, slope roll-back, conveyor push, physics sleep, map edge, diagonal slopes 49-52 as slopes, towed pairs and trailers, the crusher ride-up (with B).
- The ped `state` and `anim` values for falling, drowning, lying down and getting up, so the renderer can draw the knocked-down animation.
- Owns: `sim/sys/move_peds.zig`, `sim/sys/move_cars.zig`, `sim/sys/surfaces.zig`, `sim/map.zig`, `sim/test/bodies_*`.
- Verify: tests per numbered rule; the original-map soak (zero falls through the world, zero bodies inside matter) on Jeff's maps, extended to count drownings and fall deaths; the `replay handling` numbers unchanged except where the note says so.
- Depends on: W0 (the surface table). Size: medium.

### D1. Ped AI core

Notes: ped-ai (all but groups and gangs), weapons 3.8.

- Two-layer objectives with timeouts and the coarse movement modes, default behaviour per occupation (mugger, car thief, customers, carjacked driver), threat rule and best-target search, fleeing, reacting to attack, chasing and keeping range, weapon choice with aim jitter, melee punch with knock-down, following, electro-fingers and invisibility effects, AI test shots.
- The objective API (section 5) that script-characters, police and gangs call.
- Owns: `sim/ai/objectives.zig`, `sim/ai/threat.zig`, `sim/ai/combat.zig`, `sim/ai/follow.zig`, `sim/comp/objective.zig`, `sim/test/ped_ai_*`.
- Verify: one scenario test per objective handler (set objective, step, check outcome and failure on timeout), threat-rule table tests, a soak with 200 peds and armed occupations checking no ped is stuck in a wall and every objective ends.
- Depends on: W0. Size: large.

### D2. Gangs, groups and getting in cars

Notes: gangs-and-respect, ped-ai 3.11-3.13, entering-and-exiting-cars, script-declarations 2.11 (gang info).

- Respect per gang (-100 to 100, wrap-safe cap), kill, run-over, hijack and destroy reactions, rival knock-ons, mission respect steps, weapon tier by respect; gang areas from the map zones; gang members toward the player; gang fights; groups, formation and recruiting, instant gang.
- The full enter and exit sequence for players and AI: walk to the door, door choice, door frames, carjack and pull-out, refused cars, thrown off a moving car, passengers, AI car thieves (600 ticks), exit.
- Owns: `sim/sp/gangs.zig`, `sim/ai/groups.zig`, `sim/ai/gang.zig`, `sim/sys/enter_exit.zig`, `sim/test/gangs_*`, `sim/test/enter_exit_*`.
- Verify: the respect table as tests; a carjack test (driver ends on the pavement, hijack scored, gang respect drops); entering speed and distance limits per the note.
- Depends on: D1's objective API. Size: large. Wave 2, but respect arithmetic and the enter/exit sequence can start in wave 1.

### E. Wanted level and police

Notes: wanted-level, police-ai, script-declarations 2.14.

- Wanted points and stars, what earns them, the crime report ring, exempt shooters, cops noticing (never mid-jump), the 900-tick one-star timeout, the pursuit state machine, crew targets per tier and the new-car cap, the busted flag.
- Crews: dispatch on the nearest road to the last known position after 200 ticks, the drive there, box-in and ram with the shared side table, losing the target and searching, roadblocks from the traffic spawner (barriers, guards, army tanks with the lane gap), the on-foot arrest, SWAT/FBI/army specifics, sirens as cosmetic events.
- Owns: `sim/sp/wanted.zig`, `sim/sp/police.zig`, `sim/ai/police_crew.zig`, `sim/ai/roadblock.zig`, `sim/test/police_*`.
- Verify: tier and points tables as tests; scenario tests (shoot near a cop: one star; 900 ticks with no pursuit: cleared; kill a cop: +500); a headless pursuit on a real map where a 3-star player is chased by two crews and eventually busted on foot.
- Depends on: D1 (cops are peds with objectives) and F (car tasks and the route planner). Wave 1 for wanted points, crime reports and the timeout; wave 2 for crews. Size: large.

### F. Traffic, car tasks and spawning

Notes: traffic-and-car-ai (rest), script-declarations 2.5 and 2.13.

- Red arrows, right-of-way sweep, settle into lane, seek road and abandon after 200 ticks, car ahead and overtaking a stalled queue, honking, crossing markers, emergency vehicle differences.
- Car tasks: chase, follow, patrol, send to point, with a deterministic route planner over the road grid (block-level search, bounded per tick).
- Spawning by zone: the zone density and ratio settings from declaration 102, despawn and recycle. The spawning note is not written, so the mix of types is "ours" and flagged; trains and radio wait for their notes.
- Owns: `sim/sys/traffic.zig`, `sim/ai/car_tasks.zig`, `sim/ai/route.zig`, `sim/sys/spawn.zig`, `sim/test/traffic_*`.
- Verify: rule tests; a junction test (cross traffic held, no collision); a route test (a chase car reaches the target over 30 blocks of real road); a 10,000-tick traffic soak on Jeff's maps with counts of stuck, abandoned and collided cars, compared run to run.
- Depends on: W0. Size: large.

### G. Player career: lives, death, arrest, score, car weapons

Notes: power-ups-death-and-arrest, scoring (rest), weapons 3.6-3.7, projectiles 3.4, script-player's state.

- Career state per player: lives, multiplier, cash and points, jail cards, power-up timers that are not yet there, kill-frenzy weapon slot.
- The wasted and busted sequences with the body double, the 70-tick countdown, losing weapons, jail card, multiplier halving, game over, nearest restart zone; death messages by cause.
- The remaining power-ups, scoring with the multiplier and every victim class, accuracy statistics, the electro baton and vehicle weapons (dropping B's oil and mine objects).
- Owns: `sim/sp/career.zig`, `sim/sys/death.zig`, `sim/sys/scoring.zig`, `sim/sys/car_weapons.zig`, `sim/test/career_*`.
- Verify: tests for every row of the power-up table and every step of 3.2-3.4; a game-over test; scoring tests with the multiplier above 1.
- Depends on: W0. Size: medium.

### H. Client single-player

Notes: camera (rest), script-messages (drawing), plus the HUD note when it lands.

- Level select in the shell, loading the level's `.gmp`, `.sty`, `.scr`, mission sub-scripts and the `.gxt` text from the player's own files (OPFS), and attaching the level to the sim.
- `formats/gxt.zig` for the text table (public format), used only by the client.
- HUD from `sim/sp/hud.zig` and events: banner message, brief queue with portrait, pager, countdown timer, counters, arrow pointer, wanted stars, lives, multiplier, cash; WASTED and BUSTED screens; game over and level complete.
- Drawing: objects, doors, lamps and traffic lights, knocked-down, drowning and sinking sprites, sirens; camera suspicion, elevation and the body-double hold; sound cues for the new events.
- Owns: `client/` (including `client/wasm/src/game.zig`, which other workstreams ask H to extend rather than editing), `formats/gxt.zig`, `site/play/` rebuilds.
- Verify: the shell's unit tests; a Playwright smoke run of `site/play/` on the synthetic level (loads, messages appear, a mission passes); on Jeff's data, locally, the first level loads and the first phone gives a briefing.
- Depends on: W0's HUD and event shapes. Size: large.

### Q. Solidity and QA (runs the whole time)

- **Merge train.** Q merges finished workstream branches into the integration branch one at a time, re-running everything below, and owns the golden replay files. Workstreams do not re-record goldens themselves.
- **Golden replays.** Keep `dm16`'s golden (section 6 for the policy). Add an `sp` golden: a synthetic map and a `scrasm` script exercising threads, a phone mission, police, gangs and death, with a scripted player, hashed every tick native and WASM in CI.
- **Behaviour diff.** For every re-record, a report of what changed in play terms (kills, deaths, wrecks, distance driven, stars reached, missions passed) between the old and new recording, committed next to the new golden, so a re-record is reviewed, not waved through.
- **Headless play tests.** `tools/level`: a native runner that loads a real level from `--data`, runs its script with an autopilot player that goes where the mission arrow points (and may teleport after a time limit), and reports per mission: started, passed or failed, ticks taken, threads stuck on one command for over 3,000 ticks, unimplemented command types reached, invariant breaks. Run locally on Jeff's levels, never in CI; the results file (no game data in it) is committed.
- **Invariants and soak.** A checker run every tick in debug: no body inside matter, nobody below the world, every handle the script holds is alive or cleared, no entity count at capacity for more than N ticks, wanted points in range. A 100,000-tick random-input soak on the synthetic level in CI, and on Jeff's maps locally.
- **Determinism and budget.** Native vs WASM hash for `sp`, save/load mid-mission, and the step time budget (0.5 ms in WASM) for `sp` with a full city.
- **Note conformance.** Each workstream keeps `docs/coverage/<note>.md` with one row per numbered rule: done, ours, stubbed or blocked, and the test that checks it. Q rolls them up into one table in `docs/milestones.md`.
- **Play-test checklist** for Jeff: what to compare against the original or footage per area, and the open questions each comparison would settle.
- Owns: `tools/replay/`, `tools/level/`, `docs/coverage/` roll-up, CI workflows, `docs/milestones.md`.
- Depends on: nothing to start; the `sp` golden needs A1 and a few systems.

## 5. Interfaces between workstreams

W0 writes these as stubs with their final signatures. Owners fill them in; callers never edit them. Adding a function is fine; changing a signature goes through Q and the owner.

| API | Owner | Called by |
|---|---|---|
| `objectives`: set, clear and query a ped's main and internal objective (kill, flee, follow, go to, enter car, guard, ...) with a timeout | D1 | A2, E, D2 |
| `carTasks`: chase, follow, patrol, go to point, park in garage, stop; query arrived | F | A2, E |
| `route`: next road direction from a block toward a target | F | E |
| `career`: add score or cash (with or without multiplier), lives, multiplier, jail card, death and arrest state, power-up timers | G | A2, A1 (rewards), D2, E |
| `wanted`: add points, set at least one star, clear, cap, file a crime report | E | A2, G, D1, C (crusher and drowning exemptions) |
| `gangs`: respect get, change by steps, kill reaction, weapon for the player, gang of an area | D2 | A2, G, D1 |
| `objects`: spawn, remove, door open/close/auto, phone ring/answer, generator on/off, crusher, light state | B | A2, G, F (crossing markers) |
| `script hooks`: phone touched, car entered by ped, area entered, entity hit by weapon, car model destroyed | A1 | B, D2, C, `sys/projectile_hits` |
| `hud`: post banner, queue brief, set timer, counter and arrow | A1 | G (death messages), E (none), A2 |
| `Level`: zones, map objects, script program | W0 / formats | everyone, read only |

Rule for state: each workstream adds fields only to its own sub-struct in the SP block and its own components. The reserved ids from W0 are the only shared numbers.

## 6. Order, waves and decisions

```
wave 0   W0 foundation ─────────┐      Q tooling (tools/, CI)   H level loading (client/)
                                │
wave 1   A1  A2(partial)  B  C  D1  F  G  H  Q   E(wanted only)  D2(respect, enter/exit)
                                │
wave 2   A2(rest)  D2(groups, gang AI)  E(crews, roadblocks, arrest)
                                │
wave 3   first level end to end: Q's level runner passes the opening missions; Jeff play-tests
```

- **Merges** go through Q's merge train in this order where several are ready: C, G, B, F, D1, A1, D2, E, A2, H. Systems before the script layer, so A2's stubs turn into real calls as each lands.
- **Done for a workstream** means: its coverage files have no "stubbed" rows except ones blocked on a missing note, its tests pass in all three optimize modes, the golden and `sp` goldens pass after Q's merge, and Q's level runner shows no new invariant breaks.

**Decision for Jeff: golden replay policy.** Almost every workstream changes the state layout or gameplay, so the `dm16` golden hash changes with each merge. Options:

1. **Recommended:** a blanket approval for re-records that come from this plan, made only by Q's merge train, each with the behaviour-diff report committed beside it. Interface changes that break compatibility (I1 frozen types, I3 wire) still come to you one by one.
2. Freeze `dm16`: new state and behaviour only in `sp` (comptime-gated), so the `dm16` golden never changes. Safer for online later, but shared fixes (fall damage, water, getting in cars) would then need two code paths.

Choices made in this plan that you can overturn:

- Shared mechanics (falling, water, entering cars, traffic) apply to both `sp` and `dm16`; single-player systems (scripts, lives, police, gangs) run only in `sp`.
- New components are not added to `replicated`, so the server and netcode keep building and online stays as it is. CI for `server/` and `net/` stays green but gets no new work.
- Where a note is silent, numbers are ours, tagged "ours" in `tuning/` and in the coverage file, as today.

## 7. Notes that block work (for the reader side)

These go to Codex through `docs/behaviour/BRIEF.md`, not to implementer threads. Until each lands, the named workstream uses its own numbers and marks the rows "ours".

| Missing note or question | Blocks | Workaround |
|---|---|---|
| Animation frame timing (cross-cutting) | C fall damage, D2 door entry, D1 melee | `sim/anim.zig` delays, ours |
| Absolute heading convention (cross-cutting) | A2 script positions, D1 cones, E maneuvers | A2 settles it from parked cars on roads in the data |
| Spawning (generators, zone densities, despawning) | F | Zone settings read, mix ours |
| Objects (pickups, mines, doors, phones) | B | script-objects and script-declarations, plus ours |
| Fire (burning peds and cars, spread) | none critical | today's fire |
| Public transport (trains, buses) | F, A2 (2.13) | trains not run; train declarations stored |
| Emergency services (ambulances, fire trucks) | F, G | not spawned |
| Cranes | B | outline only |
| HUD (messages, arrows, pager) | H | script-messages plus footage |
| Save games | A1 counters persistence | in-session `save()` only |
| Open questions inside notes (FBI-only search leash, door usability, grenade bounce, police note conflict) | E, D2, G | the reading in the note's main text, flagged |

## 8. Thread summary for the coordinator

| Thread | Branch suggestion | Starts | Size |
|---|---|---|---|
| W0 Foundation: split sim, `sp` config, level input, grid surfaces, reserved ids, API stubs | `notes/w0` | now | M |
| Q Solidity and QA: merge train, goldens, level runner, soak, coverage roll-up | `notes/qa` | now | ongoing |
| A1 Script engine | `notes/script-vm` | after W0 | L |
| A2 Script world commands | `notes/script-world` | after W0 | L |
| B Objects and city furniture | `notes/objects` | after W0 | L |
| C Bodies and surfaces | `notes/bodies` | after W0 | M |
| D1 Ped AI core | `notes/ped-ai` | after W0 | L |
| D2 Gangs, groups and entering cars | `notes/gangs` | after W0 (part), after D1 (rest) | L |
| E Wanted level and police | `notes/police` | after W0 (wanted), after D1 and F (crews) | L |
| F Traffic, car tasks and spawning | `notes/traffic` | after W0 | L |
| G Player career and car weapons | `notes/career` | after W0 | M |
| H Client single-player | `notes/client-sp` | level loading now, HUD after W0 | L |
