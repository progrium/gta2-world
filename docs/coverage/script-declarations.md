# Coverage: script-declarations

Rules from [docs/behaviour/script-declarations.md](../behaviour/script-declarations.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 2.1 Player ped | todo | | |
| 2.2 Cars | todo | | |
| 2.3 Characters (peds) | todo | | |
| 2.4 Objects | stubbed |  | B: `objects.spawnObject` (ground sentinel `objects.ground_z`) + `setObjectValue`; A2: dispatch |
| 2.5 Map zone settings | todo | | |
| 2.6 Arrows | ours | sim/test/script_vm.zig | A1: 23 reserves the arrow. Ours, from the data (no note covers them): 113 points it at a declared thing, 114 at a place, 116 removes it, all through the HUD arrow; one arrow shows at a time, the last pointed. |
| 2.7 Cranes | blocked |  | Cranes: waits on the cranes note (B) |
| 2.8 Conveyors, generators, destructors, crushers | stubbed | sim/test/objects_furniture.zig | B: `addArea` (conveyor 26/27, destructor 34/35), `addGenerator` (29-32), `addCrusher` (40). Destructor effect ours (removes cars with no player). A2: dispatch |
| 2.9 Doors | stubbed | sim/test/objects_furniture.zig | B: `addDoorAnim` (230, five), `addDoor` (375-379; rule numbering ours). A2: dispatch and the 375/378 no-resolve quirk |
| 2.10 Car, phone and area triggers (thread start points) | todo | | |
| 2.11 Gang info | todo | | |
| 2.12 Lights | todo | | |
| 2.13 Trains and radio stations | todo | | |
| 2.14 Police | stubbed |  | `wanted.setCap` is the effect; the force-enable-police side of a 0 cap has no switch to set yet. A2 wires the declaration. |
| 2.15 Ambient sound points | todo | | |
| 2.16 Mission bookkeeping | todo | | |
