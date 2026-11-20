# Coverage: wanted-level

Rules from [docs/behaviour/wanted-level.md](../behaviour/wanted-level.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Points and stars | done | sim/test/police_wanted.zig: star table and adding points | Cap via `wanted.setCap`; a cap of 0 holds the level at none. |
| 3.2 What earns points | ours | sim/test/police_wanted.zig: kills, destroying a car, police car impact; real kill through scoring | Gang members by occupation `gang_member` only (Group.gang is 0 on fresh peds). Guards count as emergency (+500), our reading. Mine and object kills outside the view area not filtered yet (no mines or objects). Crushed-car exemption is a flag the crusher (B) passes. Police car = driven by police/SWAT/FBI, until crews own cars. |
| 3.3 Police noticing crimes | ours | sim/test/police_wanted.zig: crime reports; shooting near a cop; innocent player and mid-jump | Ring of 8 and a 300-tick recent-crime timer are ours. Cop view is a 7x6 block box, one level of height, no sightline (ours, until D1's threat search). Armed attack = fire held on foot. Reports live through the tick after the one they were filed in. Per-crime statistics not counted yet. |
| 3.4 One-star timeout | done | sim/test/police_wanted.zig: one star wears off after 900 quiet ticks; respawn clears |  |
| 3.5 Pursuit and crews | stubbed | sim/test/police_wanted.zig: crew targets per tier, and the pursuit states | States, tier targets, new-car caps, sight clock and the cap reset run; no crews spawn until D1 and F land. Responding ends on a sighting (police-ai.md 3.1), not a timer. |
| 3.6 Busted | todo |  | Wave 2: arrest via the melee rule (D1) calling `career.bust` (G). |
