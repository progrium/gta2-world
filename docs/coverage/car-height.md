# Coverage: car-height

Rules from [docs/behaviour/car-height.md](../behaviour/car-height.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Surface state | done | sim/test/cars.zig, sim/test/surfaces.zig | tipping over a ledge; half on water pulled in |
| 3.2 Height while on the ground | done | sim/test/cars.zig |  |
| 3.3 Ramp rate and launching | done | sim/test/cars.zig |  |
| 3.4 Height while in the air | done | sim/test/cars.zig |  |
| 3.5 Sinking | done | sim/test/surfaces.zig | every rider sinks with the car; holding an explosion timer at 50 waits on a car bomb fuse (G) |
| 3.6 Crusher riding up | todo |  | with B |
| 3.7 Towed pairs and trains | todo |  |  |
| 3.8 Physics sleep | todo |  | no observable effect in the sim beyond speed |
