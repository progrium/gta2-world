# Spike S6 result: gamepad consistency

**Question (design doc):** is the Gamepad API consistent enough across browsers and controllers?
**Passes when:** standard mapping and under one frame of added latency on Chrome, Firefox and Safari, for Xbox, DualSense and Switch Pro pads, with the gaps documented.

## Answer

**Accepted (19 Nov 2026), with known caveats.** Jeff judged the results good enough to move on. Only one of the nine browser and pad pairs has a probe run: an Xbox 360 pad in Brave (Chromium) on Windows. It passes cleanly, with standard mapping on all 21 controls and added delay under one frame. The other eight pairs are untested. Until they are run, the gaps listed in [README.md](README.md) under "Known gaps from research" are the working assumptions. In particular, Firefox has no rumble, Switch Pro triggers are digital, and some pads report `mapping: ""` in Firefox and Safari. Those gaps argue for the design doc's fallback anyway: a per-controller mapping table, with the remap screen in M1.

## Probe runs

| | Chrome / Chromium | Firefox | Safari |
| --- | --- | --- | --- |
| Xbox | **Pass** (Xbox 360 pad, XInput, Brave 158 on Windows; Paul, #5) | not run | not run |
| DualSense | not run | not run | not run |
| Switch Pro | not run | not run | not run |

### Paul (#5): Xbox 360 Controller (XInput), Brave 158 on Windows

The issue title and file name say "Chrome 158 … unknown-unknown". The file's user-agent data shows the browser is Brave 158, and the Controller and Connection fields were left blank. The pad identifies itself as `Xbox 360 Controller (XInput STANDARD GAMEPAD)`, which is the Windows XInput path that Xbox One and Series pads also use.

| Area | Result | Verdict |
| --- | --- | --- |
| Mapping | `mapping: "standard"`, 17 buttons, 4 axes. All 21 guided controls landed on the expected index with no cross-talk. The optional extra button was skipped because the pad has none | Pass |
| Triggers | Analog. The mapping step read partial values of 0.541 (LT) and 0.776 (RT). The axis test reported them as digital with max 0, but only because the triggers weren't squeezed during that test | Pass (the axis-test reading is a tester miss) |
| Sticks | Full ±1 range, 124–176 distinct values per axis. The gate is square-ish: diagonals reach 1.15 (left) and 1.22 (right), so the game needs a radial clamp. Rest drift wasn't measured, because the sticks were still moving in the last 2 s (rest max 1.0) | Gap noted: clamp needed |
| Latency | The pad updates at ~99 Hz. State is a median of 8.6 ms old and a p95 of 15.9 ms old when the frame reads it, under the 16.7 ms frame. Frame polling adds 4.6 ms median, 12.5 ms p95. 140 of 536 pad updates (26%) were never seen by a frame. The ~29 s maxima are idle gaps with no input | Pass (under one frame) |
| Rumble | `vibrationActuator` is dual-rumble. Strong, weak, both and reset all resolved, and preemption worked (first preempted, second complete). The "trigger" effect also resolved, even though the pad only lists `dual-rumble`. Whether each effect was felt wasn't marked. The legacy `hapticActuators` API is absent | API works; felt not confirmed |
| Hot-plug | Not run (no disconnects, no marks). Connect event and polling both saw the pad | Not tested |

**Known caveats, accepted:**
- Eight of the nine browser and pad pairs, all of Firefox and Safari, and both DualSense and Switch Pro are untested. The research gaps in the README stand in for them.
- The only Chromium run is Brave, not Chrome. Brave uses the same Gamepad implementation, so it is treated as Chrome here.
- The 26% of pad updates that per-frame polling never sees means a very short tap between two frames can be lost. The input layer should latch button presses between ticks rather than sampling once per frame.
- Rumble was never confirmed as felt, and hot-plug and rest drift weren't measured.
