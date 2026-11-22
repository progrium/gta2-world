# Coverage: script-cars

Rules from [docs/behaviour/script-cars.md](../behaviour/script-cars.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 2.1 Creating or acquiring a car | todo | sim/test/vehicles.zig | 188 (car on a crane's hook) done; the rest not tracked here yet. |
| 2.2 Handing a car to AI control | todo | | |
| 2.3 Driver and passengers | todo | | |
| 2.4 Trailers | ours | sim/test/vehicles.zig | `sys/trailers.zig`. Create with a trailer model spawns it hitched behind; 316 attaches, 246/247 test the pair. The hitch, kingpin, 110 degree jack-knife stop, turn x 2.5 and re-hitch rules (slow, within 3/4 block and 30 degrees) are ours; a cab tows at full speed, any other car feels the trailer's mass. Fire with no car weapon unhitches. PUT_CAR_ON_TRAILER and transporters not done. |
| 2.5 Protective and cosmetic properties | ours | sim/test/vehicles.zig | `sys/car_flags.zig`: bullet, rocket and flame proofs (311-313), locks (278; the lock numbering is ours), alarm (310, event `car_alarm` 21, 250 ticks), jammed throttle (374), siren (361/417), roof number (303). A car bomb within a block still hurts a rocketproof car. Dents (200) stubbed. |
| 2.6 Destruction, explosions and car bombs | todo | | |
| 2.7 Car-state conditions | todo | | |
