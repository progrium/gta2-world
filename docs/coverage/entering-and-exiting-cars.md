# Coverage: entering-and-exiting-cars

Rules from [docs/behaviour/entering-and-exiting-cars.md](../behaviour/entering-and-exiting-cars.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Pressing enter on foot | done | sim/test/enter_exit_cars.zig | 3 rings of blocks around the point half a block ahead; nearest within the innermost ring. Trains not modelled yet. |
| 3.2 Walking to the door | ours | sim/test/enter_exit_cars.zig | Door usable = not in a wall, not over a drop, not inside another car (the note leaves the exact test open). Door spot ours: 0.1 beyond the side, 1/8 forward of centre, driver's side first. Waits within 1 block of the door (ramp 3/4 not modelled). Garage parking not modelled yet; the car alarm rings when the door is tried (sim/test/vehicles.zig). |
| 3.3 Opening the door and getting in | ours | sim/test/enter_exit_cars.zig, sim/test/vehicles.zig | Refuse check frame 3 (script locks from `car_flags.lockedOut`; cars with no doors, towed trailers and lifted cars can't be entered), hijack frame 5, as the note. Frame counts ours (anim.zig: 8 entry, 8 pull-out, 2 ticks a frame). A traffic car's driver is spawned at the hijack so he can be pulled out. Thrown off = knocked over at the car's speed. |
| 3.4 AI peds that steal cars | done | sim/test/enter_exit_cars.zig | 600 ticks, then out; removed with a despawned car. The line he says is not modelled (audio). Drives under car_tasks wander (F). |
| 3.5 Getting out | ours | sim/test/enter_exit_cars.zig | Below 0.3, first usable door, exit animation 6 frames (ours). Handbrake set for AI, kept as the player left it. No exit while a crane holds the car. Trains not modelled yet. |
