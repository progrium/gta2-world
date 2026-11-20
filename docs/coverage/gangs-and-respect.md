# Coverage: gangs-and-respect

Rules from [docs/behaviour/gangs-and-respect.md](../behaviour/gangs-and-respect.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 The respect value | done | sim/test/gangs_respect.zig | Clamped to -100..100 in 32-bit arithmetic; high respect at 80. |
| 3.2 Events that change respect | done | sim/test/gangs_respect.zig | Kills via health (onPedDeath), run over 1, hijack and destroyed gang car 1 (by car model), steps of 20 with opposite moves for reacting gangs, power-up +20 with the zone's gang. Gangs tie to zones by name. |
| 3.3 Weapon choice against the player | done | sim/test/gangs_respect.zig | weaponForPlayer; ped AI (D1) calls it when arming. |
