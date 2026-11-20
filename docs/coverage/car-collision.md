# Coverage: car-collision

Rules from [docs/behaviour/car-collision.md](../behaviour/car-collision.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Moving with sub-steps | done | sim/test/cars.zig |  |
| 3.2 Unstick nudge | done |  | move_cars.zig; no dedicated test yet; diagonal-wall special case not modelled |
| 3.3 The collision impulse | done | sim/test/cars.zig |  |
| 3.4 Applying an impulse to a car | done | sim/test/cars.zig |  |
| 3.5 Damage | done | sim/test/weapons.zig |  |
| 3.6 Case details | todo |  | re-check against the note; crushing between cars (heavy crush) not in |
| 3.7 Map edge | done | sim/test/bodies_void.zig | lower levels rely on the map and its voids |
