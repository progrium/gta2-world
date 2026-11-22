# Coverage: script-objects

Rules from [docs/behaviour/script-objects.md](../behaviour/script-objects.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 2.1 Creating an object | stubbed |  | B: `objects.spawnObject` + `setObjectValue`, pickup-model test `objects.isPickupModel` for the cleanup exemption; A2: the scrambled 47-52 routing and the cleanup list |
| 2.2 Removing an object | stubbed |  | B: `objects.removeObject` (frees door, generator and area slots); A2: 140 routing and 444 |
| 2.3 Generators (object spawners) | stubbed | sim/test/objects_furniture.zig | B: `startGenerator` (268/269, 351/352), `setCarList` + `decidePowerUp` (354; per-model table ours, all 65). A2: dispatch. Ours: a non-pickup object a generator makes rides conveyors, a destructor removes it, and it goes after `generated_life` (60 s) |
| 2.4 Object-state queries | stubbed |  | B: `objects.objectModel` (362). On-screen tests (160, 356) belong with the camera view (A2/H) |
| 2.5 Doors (runtime control) | stubbed | sim/test/objects_furniture.zig | B: `setDoor` open/closed/auto/manual (178 only when the close rule wants it), `setDoorTarget` (265). A2: dispatch |
| 2.6 Phones (runtime control) | stubbed | sim/test/objects_furniture.zig | B: `ringPhoneFor` (168), `consumeAnswer` (227), `phoneTimedOut` (228), `ringPhone(false)` (229), `killPhone` + dead list of 31 (245). A2: dispatch; gang-phone marker [obs] not done |
| 2.7 Explosions aimed at an object | todo | | |
