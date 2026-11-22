# Coverage: crushers-and-garages

Rules from [docs/behaviour/crushers-and-garages.md](../behaviour/crushers-and-garages.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Crusher layout | done | sim/test/objects_furniture.zig | B: one centre object; piston and base distances in sim/tuning/objects.zig; the client draws the pistons from `objects.crusherPistons` |
| 3.2 Crushing a car | ours | sim/test/objects_furniture.zig | B: sim/sys/crusher.zig. Ours: what "touching the centre marker" means (centre within 1/4 block), a 4 px floor on the shrink, and the wreck ageing like any wreck. Not-a-crime: `objects.beingCrushed` for E |
| 3.3 Scripted garage parking (outline) | blocked |  | Garage parking: the note is an outline (speeds, alignment, door timing open) |
| 3.4 Cranes (outline) | ours | sim/test/vehicles.zig | `sys/cranes.zig`: picks a still, non-AI car within 4 blocks, lifts it to its target and lets go; a crane linked to a home crane takes the crushed wreck from beside the crusher and, with a 439 generator, drops it for a power-up. Swing, trolley and lift speeds, wait and grip times are ours. The driver can't get out while lifted. No hook graphic yet. |
