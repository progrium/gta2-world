# Coverage: power-ups-death-and-arrest

Rules from [docs/behaviour/power-ups-death-and-arrest.md](../behaviour/power-ups-death-and-arrest.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Power-ups | ours | sim/test/career.zig "power-ups: every row..." | Every row and the refresh rule in `sp/career.zig` `takePowerUp`. Respect calls D2's `respectPowerUp`, instant gang D2's `instantGang` (refused in a car), cop bribe E's `wanted.clear`. Deathmatch pickups (B's `sys/pickups.zig`) still use their own five kinds; B's generators should call `career.takePowerUp`. |
| 3.2 Death (wasted) | ours | sim/test/career.zig "wasted: ..." (three tests) | `sys/death.zig`. Ours: `lives` counts spare lives, so dying with 0 is game over and a double is left whenever a life remains. Death messages go out as the `wasted` event's cause; the text keys are H's. Car weapons removed are those of the car he died in. |
| 3.3 Arrest (busted) | ours | sim/test/career.zig "busted ..." (three tests) | `career.bust` (E calls it). The player's gang is broken up (D2's `breakUpGang`). E's police seat the double in a police car 2 ticks before the end (reading the career state); a seated double is left to E. |
| 3.4 Respawn point | ours | sim/test/career.zig "wasted: a life goes..." | Nearest restart zone by zone centre. Ours: after an arrest an arrest-restart zone (public map format) is preferred when the map has one. Network round-robin: not in `sp`. |
