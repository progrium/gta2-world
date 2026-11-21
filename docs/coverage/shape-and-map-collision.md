# Coverage: shape-and-map-collision

Rules from [docs/behaviour/shape-and-map-collision.md](../behaviour/shape-and-map-collision.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Two things touching (sprite against sprite) | ours | sim/test/cars.zig | broadphase with circles for peds and boxes for cars (contacts.zig) |
| 3.2 Touching a wall | done | sim/test/peds.zig, sim/map.zig | wall faces are lines; partial blocks never wall a body |
| 3.3 Slopes | done | sim/map.zig | ramp side faces left out (formats/grid.zig); a step up a ramp is tested at the higher floor |
| 3.4 Diagonal walls | done | sim/test/bodies_void.zig | 45-48 and the closed half of 49-52 as half-block walls; the diagonal-wall object for contacts is not modelled |
| 3.5 Map edge | done | sim/test/bodies_void.zig |  |
