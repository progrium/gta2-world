# Coverage: ped-ai

Rules from [docs/behaviour/ped-ai.md](../behaviour/ped-ai.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Objectives | todo | | |
| 3.2 Default behaviour (no objective) | todo | | |
| 3.3 Threat detection | todo | | |
| 3.4 Best-target search | todo | | |
| 3.5 Fleeing | todo | | |
| 3.6 Reacting to being attacked | todo | | |
| 3.7 Chasing and keeping range | todo | | |
| 3.8 Weapon selection and aim | todo | | |
| 3.9 Melee (punch) | todo | | |
| 3.10 Following | todo | | |
| 3.11 Group formation and recruiting | ours | sim/test/gangs_groups.zig | D2 (ai/groups.zig). Which front-rank follower each second-rank slot trails is ours (groups.wedge_parent). Movement waits on D1's follow objective. |
| 3.12 Gang-vs-gang fighting | ours | sim/test/gangs_groups.zig | D2 (groups.attack). Pairing and the 4-block leash done; the fights themselves run on D1's kill objective. |
| 3.13 Gang members toward the player | stubbed |  | D2 gives respect, isHighRespect, hostile and weaponForPlayer; D1's threat rule applies them. Turf kills count via Group.flag_turf (spawning sets it, F). |
| 3.14 Electro-fingers | todo | | |
| 3.15 Invisibility | todo | | |
