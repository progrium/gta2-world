# Coverage: weapons

Rules from [docs/behaviour/weapons.md](../behaviour/weapons.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Ammo bookkeeping | todo | | |
| 3.2 Spawning a shot | todo | | |
| 3.3 Hand weapons | todo | | |
| 3.4 Throwing (grenade, molotov) | todo | | |
| 3.5 Electro gun (chain lightning) | todo | | |
| 3.6 Electro baton | todo | | |
| 3.7 Vehicle weapons | todo | | |
| 3.8 AI test shots | ours | sim/test/ped_ai_combat.zig | D1 (ai/combat.zig). A real shot hitting someone other than the target switches the shooter to test shots every 5 ticks (1 for machine guns), the shotgun's at 0, +-12, +-24; throwers test before each throw. Ours: a test shot is an instant line check (walls, and bodies within 0.15 of the line), not a flying projectile. |
