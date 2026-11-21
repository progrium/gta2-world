# Coverage: script-missions

Rules from [docs/behaviour/script-missions.md](../behaviour/script-missions.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 2.1 Starting a mission | ours | sim/test/script_vm.zig | 274 and the 263 gate (329 has the same layout and is read the same way). Layout from the data: base, passed, failed, mission 2, general flag, own gang, two other gangs, gang, respect, mission 1. Ours: which canned line goes with which reason (base-7 low respect, -6 zero, -5 own job, -4 negative, -3/-2 other gangs' jobs), read from the text layout. Ours: while a mission sub-script runs, the gate gives the own-job line, so a second phone answered before the mission sets its flags cannot load over it. A phone trigger's target object is made a phone (no note says which object models are phones). |
| 2.2 Ending a mission | ours | sim/test/script_vm.zig | 273 = RETURN; ours: when the mission body returns, a pass event if the gate's passed counter is set, a fail event if only its failed counter is, and a pass for a 274 launch (no counters); 391 removes the cleanup list. The follower group and the wanted-car-model marker are not cleared yet (D2, unclaimed). |
| 2.3 Timed bonus challenges | ours | sim/test/script_vm.zig | 288-294 and 402, results kept in the handle slot. Ours: field order from the data, but the kind, vehicle and cause numbering is not settled, so any ped kill (or car of the given model) by the player in the zone counts. Needs hooks.pedKilled and carModelDestroyed from G. |
| 2.4 The kill-frenzy weapon template | stubbed | sim/test/script_vm.zig | 422/423 flow, displays, rewards (1 score, 2 multiplier, 3 lives: ours) and the keyframe bit. The weapon grant and take-back wait on G; the secrets totals on A2. |
| 2.5 Bonus-stage start/end | done |  | No script command, per the note. |
| 2.6 Rewards | done |  | Through the player family (A2). |
| 2.7 Retrying a mission | done | sim/test/script_vm.zig | Through the gate's passed/failed counters. |
