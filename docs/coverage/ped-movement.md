# Coverage: ped-movement

Rules from [docs/behaviour/ped-movement.md](../behaviour/ped-movement.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Turning (player) | done | sim/test/peds.zig | tank and direct controls |
| 3.2 Speed | done | sim/test/peds.zig | one pace; gang follower speed belongs to D1 |
| 3.3 Walls and tiles | done | sim/test/peds.zig, sim/test/bodies_void.zig | wall faces, slide at half speed, voids under decks act as walls |
| 3.4 Height on the ground | done | sim/test/peds.zig, sim/test/bodies_void.zig | a ramp under a low ceiling stops the ped where his head would hit |
| 3.5 Stepping off an edge and falling | ours | sim/test/bodies_void.zig | fall frame length 2 ticks (anim.zig, ours); peds never land on top of cars in the sim, so the landing-on-something rules are not modelled |
| 3.6 Jumping | done | sim/test/peds.zig |  |
| 3.7 Water and electrified floors | done | sim/test/surfaces.zig | the "moment after leaving a vehicle" exemption is not modelled; electrified lids need the host to pass the tile set (formats markElectrified) |
| 3.8 Being hit by a car | done |  | contacts.zig carHitPed; no dedicated test yet |
| 3.9 Collision box | ours |  | ped is a square of radius ped_radius; body height for wall tests is 0.5 (note: 0.25) |
