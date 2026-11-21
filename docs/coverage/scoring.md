# Coverage: scoring

Rules from [docs/behaviour/scoring.md](../behaviour/scoring.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 How points are added | done | sim/test/career.zig "scoring: kills by class..." | `career.addScore`, with or without the multiplier; mirrored into the player row's `score`. |
| 3.2 Killing peds | ours | sim/test/career.zig "scoring: kills by class..." | Classes from `Objective.occupation`, gang from `Group.gang`. Stubbed: run over in the victim's own stolen car (x5) needs car ownership; crime reports and the bonus-system feed (E, A1). The French no-police-points variant is not done. |
| 3.3 Cars | ours | sim/test/career.zig "scoring: a wreck pays..." | Wreck, damage bands, driver cash, emergency-kind set done. Bus rules and emergency kinds need `tuning/career.zig` `model_roles` filled from data (every model reads as ordinary until then); passengers count as riders once D2 has them. Hijack is scored in D2's `board`; `scoreHijack` adds the bus case for D2 to call. |
| 3.4 Accuracy | ours | sim/test/career.zig "accuracy: ..." | Hits by weapon in the career state. Ours: "threat" means the victim's objective targets the shooter. |
