# Coverage: projectiles

Rules from [docs/behaviour/projectiles.md](../behaviour/projectiles.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Flight | todo | | |
| 3.2 Hitting a pedestrian | todo | | |
| 3.3 Hitting a car | todo | | |
| 3.4 Death causes | ours | sim/test/career.zig "wasted: ..." | `deathCause` in `sys/health.zig`: electrocuted, burning, run over, or the weapon that hit last; carried by the `wasted` event. |
