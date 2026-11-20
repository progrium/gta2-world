# Coverage: weapons

Rules from [docs/behaviour/weapons.md](../behaviour/weapons.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Ammo bookkeeping | todo | | |
| 3.2 Spawning a shot | todo | | |
| 3.3 Hand weapons | todo | | |
| 3.4 Throwing (grenade, molotov) | todo | | |
| 3.5 Electro gun (chain lightning) | todo | | |
| 3.6 Electro baton | todo |  | No baton in the hand-weapon table yet (G). |
| 3.7 Vehicle weapons | ours | sim/test/career.zig "car weapons: ..." (three tests) | `sys/car_weapons.zig`: fitted weapons in `state.sp.arms`, built-in ones by `model_roles`. Oil and mines call B's `objects.spawnObject` (a stub until B lands). Ours: car-gun bullets are the machine gun's; car bomb fuse 150 ticks; trailer unhitching not done. |
| 3.8 AI test shots | todo | | |
