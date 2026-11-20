# Coverage: police-ai

Rules from [docs/behaviour/police-ai.md](../behaviour/police-ai.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Dispatch and the drive to get there (idle → responding) | todo | | |
| 3.2 The chase: boxing in and ramming | todo | | |
| 3.3 Losing the target and searching | stubbed | sim/test/police_wanted.zig: crew targets per tier, and the pursuit states | The 250-tick sight clock drops an active pursuit to searching; crews and the leash wait for wave 2. |
| 3.4 Roadblocks | todo | | |
| 3.5 Chasing and arresting on foot | todo | | |
| 3.6 SWAT, FBI and army specifics | todo | | |
| 3.7 Sirens and lights | todo | | |
