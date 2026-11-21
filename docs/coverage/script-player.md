# Coverage: script-player

Rules from [docs/behaviour/script-player.md](../behaviour/script-player.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 2.1 Score, cash and the multiplier | todo | | |
| 2.2 Lives | todo | | |
| 2.3 Wanted level | done | sim/test/police_wanted.zig: star table and adding points (set, raise, cap) | `wanted.clear` (163), `setStars` (164), `raiseToStars` (421), `setCap` (418); A2 wires the commands. |
| 2.4 Locking the player's own controls | todo | | |
| 2.5 Death/arrest and respect snapshot | todo | | |
