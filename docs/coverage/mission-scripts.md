# Coverage: mission-scripts

Rules from [docs/behaviour/mission-scripts.md](../behaviour/mission-scripts.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Level start | done | sim/test/script_vm.zig | Declaration pass over 1-5999 on the first tick with a level attached, then the level-start (59) thread. Non-A1 declarations go to A2's world.zig. Missions are not declared at load: loading one resets its slots to their compiled values (counters live in their commands). |
| 3.2 Threads | ours | sim/test/script_vm.zig | One command a tick, EXEC blocks, WHILE_EXEC runs, 0xFFFF ends, stopped threads inert, creation order. Ours: 64 threads, gosub depth 8, 2000 commands a block a tick. From the data: an end-exec line (64) also closes a WHILE_EXEC run for the tick (every WHILE_EXEC body path in the player's scripts ends with one; without that rule wil's main loop spins). |
| 3.3 Mission fail on death or arrest | ours | sim/test/script_vm.zig | Checked for the thread running the mission, needs `career.isOut` (G, stub until G lands). Ours: pops two frames and resumes at the second one's return point (the line after the launch, which is where the player's phone threads reset their flags); notes read either way. Ours: then clears the notify flag and the in-progress counters so it fires once; busted vs wasted from whether the ped is alive. |
| 3.4 Triggers | done | sim/test/script_vm.zig | Phone (edge per touch), car (hooks.carEntered), block and area (polled, fire on entering, re-arm on leaving). Declarations decoded by A2 call ctx.addTrigger. Weapon hits per entity in ScriptTag.hits (hooks.entityHit). Saving answered phones waits for the save-game note. |
| 3.5 Counters and saves | blocked |  | No save-game note yet: counters, phones and map changes live in the sim state, so in-session save()/load() keeps them; a separate save file is not written. |
