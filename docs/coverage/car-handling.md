# Coverage: car-handling

Rules from [docs/behaviour/car-handling.md](../behaviour/car-handling.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| Units and conventions | done | sim/test/cars.zig |  |
| Values derived once per model at load | done | sim/test/cars.zig | tuning carModel from the .gci and style car info |
| Per-tick rules for a driven car on the ground | done | sim/test/cars.zig, sim/test/surfaces.zig | steep-slope roll-back in; conveyor push (order steps 1, 11, 16) waits on conveyor data in the grid |
| Oil slick | done | sim/test/surfaces.zig | API Self.surfaces.oilCar for the oil object (B) and oil weapon (G); oil damage goes through anti-strength (ours) |
| Coasting | blocked |  | who sets the coast state is an open question in the note |
