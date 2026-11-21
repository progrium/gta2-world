# Coverage: camera

Rules from [docs/behaviour/camera.md](../behaviour/camera.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Camera state | done | client/render/ts/src/camera.ts | ChaseCamera keeps position, height and their speeds |
| 3.2 Target each tick | ours | client/shell/test/singleplayer.test.ts | lift, lead-ahead and the dead pull-back (body held for 70 ticks after wasted or busted); heights are a perspective eye, so the base height and lead scale are ours |
| 3.3 Suspicion | stubbed | client/shell/test/singleplayer.test.ts | the 0-80 counter and the lead cut are in; the "driver is chased" input waits for police (E) and car tasks (F) |
| 3.4 Smooth movement | done | client/render/ts/src/camera.ts |  |
| 3.5 Shake | done | client/render/ts/src/camera.ts | explosion events within 12 blocks |
| 3.6 Elevation and panning | stubbed | client/shell/test/singleplayer.test.ts | elevation offset (0-20) is an input; nothing sets it until a script command does. Panning not done |
