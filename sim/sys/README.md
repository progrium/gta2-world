# sim/ layout and ownership (W0)

W0 of `docs/plan-notes.md` split the sim so workstreams can run in parallel without editing the same files. Each file belongs to one workstream; others call its API and do not edit it. Adding a function is fine; changing a signature goes through the merge train (Q) and the owner.

## How a system file works

Every file under `sys/`, `ai/`, `sp/` and `script/` is `pub fn Sys(comptime Self: type) type`, a struct of functions that take `self: *Self` (the `Sim(cfg)` instance). `sim.zig` instantiates each one:

- the systems and helpers that existed before W0 are aliased as methods (`self.sysMoveCars()`, `self.hurt(...)`), so their bodies moved verbatim;
- the cross-workstream APIs are namespaces: `Self.objectives.setObjective(self, ped, .{ .kind = .go_to })`.

`step()` in `sim.zig` calls the systems in one fixed order (plan-notes.md 3.7). Single-player systems run only when `Self.single_player` (configs whose name starts with `sp`); a branch on `comptime single_player` is not compiled for `dm16`, so it may read `self.state.sp`.

Shared names (imports, `Fx`, the `abi.rand` salts) come from `prelude.zig`. Reserved numbers (occupations, object kinds, salt ranges per workstream, and pointers to the component ids, event kinds and ped states) are in `ids.zig`. Animation frame timing is in `anim.zig`.

## Files and owners

| File | What | Owner |
| --- | --- | --- |
| `sim.zig` | I1 surface, `State`, `step()` order, configs, host helpers | Q (merge train) |
| `sys/input.zig` | commands and input frames | shared |
| `sys/spawn.zig` | spawn spots, ambient cars and peds, players; `sysZoneSpawn` stub | F |
| `sys/enter_exit.zig` | getting in and out of cars, riders | D2 |
| `sys/ped_ai.zig` | ambient wandering | D1 |
| `sys/ped_control.zig` | peds on foot | C |
| `sys/car_control.zig` | car handling | C |
| `sys/weapons.zig` | hand weapons | G |
| `sys/car_weapons.zig` | vehicle weapons, electro baton (stub) | G |
| `sys/explosions.zig` | fire and explosions | G |
| `sys/terrain.zig` | bodies against the map | C |
| `sys/move_peds.zig`, `sys/move_cars.zig` | movement, knock-downs, wall hits | C |
| `sys/surfaces.zig` | deep water; `sysSurfaces` stub (electrified) | C |
| `sys/projectiles.zig`, `sys/projectile_hits.zig` | shots in flight and hits | G |
| `sys/contacts.zig` | broadphase and body contacts | C |
| `sys/health.zig` | damage, status, deaths | G |
| `sys/scoring.zig` | frags and points | G |
| `sys/death.zig` | wasted and busted (stub) | G |
| `sys/pickups.zig` | deathmatch pickups | B |
| `sys/objects.zig` | objects API and `sysObjects`: phones, script pickups, oil, mines, conveyors, destructors, map objects | B |
| `sys/objects_state.zig` | the `objects` sub-struct of the SP block (doors, generators, areas, dead phones) | B |
| `sys/doors.zig`, `sys/generators.zig`, `sys/crusher.zig` | doors, generators, crushers | B |
| `sys/lights.zig` | light cycle, lamps, crossing markers, `lights` state | B |
| `sys/ambient.zig` | keeping the population near players | F |
| `sys/traffic.zig` | traffic AI | F |
| `sys/respawn.zig` | respawning | G |
| `ai/objectives.zig` | objectives API (stub) | D1 |
| `ai/car_tasks.zig`, `ai/route.zig` | car tasks and route API (stubs) | F |
| `sp/state.zig` | the SP state block layout | Q |
| `sp/career.zig` | career state and API (stub) | G |
| `sp/wanted.zig`, `sp/police.zig` | wanted and police state, API (stubs) | E |
| `sp/gangs.zig` | gang state and API (stub) | D2 |
| `script/world.zig` | the VM seam for world commands (`exec`, `coverage`), parameter decoding, A2's `world` state block | A2 |
| `script/cmd_decl.zig`, `cmd_cars.zig`, `cmd_chars.zig`, `cmd_objects.zig`, `cmd_player.zig` | declaration, car, character, object and player commands | A2 |
| `sp/hud.zig` | HUD state and API (banner, briefs, timer/counter displays, arrow) | A1 |
| `script/vm.zig`, `script/hooks.zig` | script state, VM, triggers and hooks | A1 |
| `script/cmd_flow.zig`, `cmd_counters.zig`, `cmd_messages.zig`, `cmd_missions.zig` | the VM's own command families | A1 |
| `comp/*.zig` | components: `objective` D1, `object` B, `car_task` F, `group` D2, `script_tag` A1; the rest shared | |
| `tuning/*.zig` | tuning by area, re-exported from `tuning.zig` (whose `var`s stay there) | the area's owner |
| `test/*.zig` | tests by area, with `test/harness.zig`; new workstreams add `test/<area>_*.zig` and list them in `sim_test.zig` | |

Owners create further files of their own (for example `ai/threat.zig`, `sys/doors.zig`) as the plan lists them.
