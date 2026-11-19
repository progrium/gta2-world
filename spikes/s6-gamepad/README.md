# Spike S6: Gamepad consistency

**Question:** Is the Gamepad API consistent enough across browsers and controllers?

**Passes when:** standard mapping and under one frame of added latency on Chrome, Firefox and Safari, for Xbox, DualSense and Switch Pro pads, with the gaps documented.

**If it fails:** ship a per-controller mapping table and make the remap screen part of M1.

Throwaway spike code. `index.html` is a single self-contained probe page with no build step.

## Running the probe

The Gamepad API only works in a secure context, so serve the page from localhost rather than opening the file:

```sh
cd spikes/s6-gamepad
python3 -m http.server 8066
# open http://localhost:8066/ in each browser
```

For each browser and pad combination (9 runs, more if you also try USB versus Bluetooth):

1. Quit Steam (or disable Steam Input for the session). It can grab pads and present them as an Xbox 360 controller.
2. Connect one pad only. Open the page and press any button. Fill in Controller, Connection and check OS and Browser.
3. **Mapping check:** click Start and press each control it names by *position*. The Switch Pro's A sits on the right, so "bottom face" is B on that pad. Skip Home/Guide/PS if the OS grabs it.
4. **Axis test:** click Start, roll both sticks round their outer edge and squeeze both triggers slowly for 6 s, then let go for 2 s.
5. **Latency test:** click Start, wiggle the left stick and tap buttons for 10 s. Keep the mouse still and the tab focused.
6. **Rumble:** click each effect and mark yes or no for whether you felt it. "Long then preempt" should give one long buzz that is cut short by a weaker one.
7. **Hot-plug:** click Mark, unplug or power off the pad, wait 3 s, reconnect and press a button. Repeat once with the tab in the background, then return to it.
8. Click **Download JSON** and drop the file in `spikes/s6-gamepad/results/` (or send it over).

About 3 minutes per run. `node summarize.mjs results/*.json` prints the comparison matrix.

## What the probe measures

| Area | How | What counts as a gap |
| --- | --- | --- |
| Mapping | `gamepad.mapping`, then a guided press of all 17 standard controls plus sticks, recording which button or axis index actually moved | `mapping !== "standard"`, any control on the wrong index, or one control firing two inputs (cross-talk) |
| Axis ranges | Min and max per axis, max magnitude per octant (square versus circular gate), rest drift, distinct trigger values | Axes not reaching ±1, diagonals over 1.15 (needs a radial clamp), rest drift over 0.1, digital triggers |
| Polling latency | A rAF reader and a setTimeout(0) reader run together. Records the pad's own update cadence (`timestamp` deltas), staleness of the state when the frame reads it (`performance.now() - timestamp`), and how many updates a per-frame read never sees | p95 staleness at frame read above one frame interval |
| Rumble | `vibrationActuator` type and `effects`, then dual-rumble strong, weak and both, trigger-rumble, preemption and `reset()`, plus the old `hapticActuators.pulse` | Promise rejected, actuator missing, or nothing felt |
| Hot-plug | `gamepadconnected`/`gamepaddisconnected` events alongside polling, with visibility and focus | Events missing, the pad changing index on reconnect, or the `id` changing |

Limits: this measures delay *inside* the browser, from the pad state's timestamp to the frame that reads it. It cannot see USB or Bluetooth transport delay or OS driver delay, which a photodiode or high-speed camera rig would need. The timestamps of Firefox and Safari are coarsened to about 1 ms, which is fine at this scale. If a browser's `timestamp` is not on the `performance.now()` clock, the page says so and reports only the cadence numbers.

## Known gaps from research (before hardware testing)

Items marked *verified* were checked against MDN or caniuse on 2026-11-19. The rest come from prior knowledge and are what the probe runs confirm or overturn.

1. **Rumble, Firefox: none.** `Gamepad.vibrationActuator` is unsupported in every Firefox version through 163 (*verified*, caniuse). Firefox has only the older `hapticActuators[].pulse()` behind the `dom.gamepad.haptic_feedback.enabled` pref, and it is off by default. The design doc's "rumble where the browser supports it" means no rumble on Firefox.
2. **Rumble, Safari: dual-rumble from 16.4** (*verified*, caniuse). No trigger-rumble.
3. **Rumble, Chrome: dual-rumble from 68, trigger-rumble from 126** (*verified*, caniuse). Trigger-rumble works in practice only on Xbox One/Series pads on Windows. DualSense adaptive triggers and HD haptics are not reachable from any browser.
4. **Polling is capped at frame rate.** Pads report at about 125 to 1000 Hz, but `getGamepads()` is read in rAF at about 60 Hz, which averages about 8 ms of added delay and drops intermediate states (*verified*, Microsoft's Gamepad Event-Driven Input explainer). Edge/Chrome have an experimental `gamepadrawinputchanged` event; the probe detects it. For a 30 Hz sim that latches input per tick this probably doesn't matter, since a tick is two frames, but a short button tap between two frames could be lost. The probe's "updates never seen by a frame" figure shows how often.
5. **Pads are hidden until a button press**, and only in secure contexts. The design doc already plans a "press a button" prompt.
6. **Switch Pro ZL/ZR are digital.** They read 0 or 1, so the analog throttle and brake plan degrades to on/off on that pad. The design should treat triggers as possibly digital and fall back to tapping or ramping.
7. **Positional mapping versus labels.** Standard mapping is by position, so `buttons[0]` is A on Xbox, Cross on PlayStation and B on Switch. UI glyphs need a per-family table even when mapping is correct.
8. **Mapping is not "standard" everywhere.** Firefox on Linux and macOS has returned `mapping: ""` for some pads, DualSense and Switch Pro in particular, with triggers on axes and the d-pad on a hat axis. Chrome on Linux has done the same for Switch Pro over Bluetooth. Firefox on Windows and Chrome on Windows and macOS generally map all three. Safari routes through Apple's GameController framework, which supports all three pads on recent macOS, but the probe should confirm this.
9. **Controller `id` strings differ per browser.** Chrome gives `"Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 0b13)"`, Firefox gives `"045e-0b13-Xbox Wireless Controller"`, and Safari gives the product name with no vendor or product ids. The doc's "remap stored per controller id" needs a normalised key (vendor:product where present, otherwise the name).
10. **The OS captures system buttons.** On Windows, Guide opens Game Bar. On macOS, the PS or Home button can open the game overlay or Launchpad. Don't bind gameplay to button 16.
11. **Background and focus.** Chrome stops delivering pad state to hidden or unfocused tabs, and connect events can be delayed until the tab is visible again. That is harmless for a game, but the probe's hot-plug background step records the behaviour.
12. **Steam Input on Windows** can hide the real pad or show it as an Xbox 360 controller, which changes the id and mapping. Tell players to turn it off or document it.
13. **Firefox `privacy.resistFingerprinting`** hides gamepads entirely.

## Results

_To be filled in from the probe JSON files._

| | Chrome | Firefox | Safari |
| --- | --- | --- | --- |
| Xbox | | | |
| DualSense | | | |
| Switch Pro | | | |

**Verdict:** pending hardware runs.
