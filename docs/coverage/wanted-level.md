# Coverage: wanted-level

Rules from [docs/behaviour/wanted-level.md](../behaviour/wanted-level.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Points and stars | done | sim/test/police_wanted.zig: star table and adding points | Cap via `wanted.setCap`; a cap of 0 holds the level at none. |
| 3.2 What earns points | ours | sim/test/police_wanted.zig: kills, destroying a car, police car impact; real kill through scoring | Gang members by occupation `gang_member` only (Group.gang is 0 on fresh peds). Guards count as emergency (+500), our reading. Mine and object kills outside the view area not filtered yet (no mines or objects). Crushed-car exemption is a flag the crusher (B) passes. Police car = driven by police/SWAT/FBI, until crews own cars. |
| 3.3 Police noticing crimes | ours | sim/test/police_wanted.zig: crime reports; shooting near a cop; innocent player and mid-jump | Ring of 8 and a 300-tick recent-crime timer are ours. Cops notice through D1's threat search and crew officers' view box (7x6 blocks, one level, ours) calling `copSees`; invisible on foot is unseen. Armed attack = fire held on foot. Per-crime statistics not counted yet. |
| 3.4 One-star timeout | done | sim/test/police_wanted.zig: one star wears off after 900 quiet ticks; respawn clears |  |
| 3.5 Pursuit and crews | done | sim/test/police_wanted.zig: crew targets per tier; two stars want two crews; four stars add SWAT | Responding ends on a sighting (police-ai.md 3.1), not a timer. The new-car cap is per pursuit. |
| 3.6 Busted | done | sim/test/police_wanted.zig: a one-star player on foot is chased down and arrested | Via D1's melee rule and G's `career.bust`; a police car takes the body double away two ticks before the countdown ends. |
