# Spike S6 result: gamepad consistency

**Question (design doc):** is the Gamepad API consistent enough across browsers and controllers?
**Passes when:** standard mapping and under one frame of added latency on Chrome, Firefox and Safari, for Xbox, DualSense and Switch Pro pads, with the gaps documented.

## Answer

**Accepted (19 Nov 2026), with known caveats.** Jeff judged the results good enough to move on. Two of the nine browser and pad pairs now have a probe run: an Xbox 360 pad in Brave (Chromium) on Windows, and a DualSense over USB in Chrome on macOS (added 21 Nov). Both pass, with standard mapping on every control and added delay under one frame. The other eight pairs are untested. Until they are run, the gaps listed in [README.md](README.md) under "Known gaps from research" are the working assumptions. In particular, Firefox has no rumble, Switch Pro triggers are digital, and some pads report `mapping: ""` in Firefox and Safari. Those gaps argue for the design doc's fallback anyway: a per-controller mapping table, with the remap screen in M1.

## Probe runs

| | Chrome / Chromium | Firefox | Safari |
| --- | --- | --- | --- |
| Xbox | **Pass** (Xbox 360 pad, XInput, Brave 158 on Windows; Paul, #5) | not run | not run |
| DualSense | **Pass** (USB, Chrome 156 on macOS; Jeff, `results/chrome156-macos-dualsense-usb-jeff.json`) | not run | not run |
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

### Jeff: DualSense over USB, Chrome 156 on macOS

The id is `DualSense Wireless Controller (STANDARD GAMEPAD)`. Chrome on macOS gives no Vendor and Product here, unlike Chrome on Windows, so this pad gets a name-only controller key, the same as Safari would.

| Area | Result | Verdict |
| --- | --- | --- |
| Mapping | `mapping: "standard"`, 18 buttons, 4 axes. All 22 guided controls landed on the expected index with no cross-talk, including Home (16) and the touchpad click (17) | Pass |
| Triggers | Analog. The mapping step read partial values of 0.78 (L2) and 0.647 (R2). The axis test recorded max 0 for both, see below | Pass (from the mapping step) |
| Sticks | Not measured. During the 6 s sweep the left stick peaked at 0.041 and the right stick never left 0. Stick movement only shows up in the last 2 s (axis 0 up to 0.735). The mapping step saw both sticks travel past 0.5 on the expected axes | Not measured; probe fixed |
| Latency | The pad updates at ~196 Hz. State is a median of 2.3 ms old and a p95 of 5.3 ms old when the frame reads it, on a 120 Hz display (8.3 ms frames). Frame polling adds 0.2 ms median, 4.7 ms p95. 348 of 899 pad updates (39%) were never seen by a frame. `gamepadrawinputchanged` is absent in Chrome 156 on macOS | Pass (under one frame) |
| Rumble | `vibrationActuator` lists only `dual-rumble`. Strong, weak and both were felt. Preemption worked. The trigger effect resolved "complete" but was not felt, as expected for a DualSense. `hapticActuators` is absent | Pass for dual-rumble; no trigger rumble |
| Hot-plug | Unplug gave `gamepaddisconnected` and the pad vanished from polling at once. Replug reconnected on the same index with the same id. Background-tab reconnect wasn't tried | Pass (foreground) |

**Why the axis test came back empty, and the fix.** The probe's reading code is the same one the other stages use, and those stages saw the sticks and triggers move. What differs is timing: the 6 s sweep clock started on the mouse click. In this run and in Paul's (both had triggers at max 0), the window seems to have closed before the hand got back to the pad. The probe now arms on Start and starts the clock on the first stick or trigger movement, cancelling after 30 s with nothing. A trigger that never moves is reported as "not measured" instead of "digital", and a sweep that doesn't reach full travel asks for a rerun. `summarize.mjs` shows unmeasured triggers as `?`. The copy on the tester site (`site/s6/` on main) still has the old timing until it is updated.

**What this changes in the shell (`client/shell`, branch m1/shell):** nothing in behaviour. The name-only key, the button glyphs, dual-rumble without trigger-rumble, same-index reconnect and ORing buttons between ticks are already handled there. Tests now cover this pad's id.

**Known caveats, accepted:**
- Seven of the nine browser and pad pairs, all of Firefox and Safari, and the Switch Pro are untested. Stick ranges and the gate shape are unmeasured on the DualSense. The research gaps in the README stand in for them.
- The only Chromium run is Brave, not Chrome. Brave uses the same Gamepad implementation, so it is treated as Chrome here.
- The 26% (Xbox, ~99 Hz) and 39% (DualSense, ~196 Hz) of pad updates that per-frame polling never sees means a very short tap between two frames can be lost. The input layer should latch button presses between ticks rather than sampling once per frame.
- Rumble was never confirmed as felt, and hot-plug and rest drift weren't measured.
