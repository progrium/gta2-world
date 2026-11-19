# Spike S3: prediction feel

Question (design doc, "Initial spikes"): does rewind-and-replay feel right for a drifting car?
Pass: driving at 150 ms round trip and 2% loss shows no visible snapping in blind comparison with zero latency.

Throwaway code. The car is a simple fixed-point model of my own, not S5's handling.

## Result

**Yes for the own car, provisionally.** The numbers say the networked car is indistinguishable from zero latency at 150 ms / 2% loss: with nothing to bump into there are zero corrections, and bumping the other car gives corrections of under 3 world units (a car is 40 long) that the 100 ms smoothing hides. What the numbers cannot settle is how it feels to a person, so the pass is final only once Jeff has run 10+ blind trials (below) and scored no better than chance.

**New problem found: remote cars drawn interpolated are far from where you hit them.** The design doc draws remote entities interpolated 100 ms in the past. With the own car predicted ahead of the server by about half the round trip plus the input buffer, the other car is drawn about 270 ms behind the own car at 150 ms RTT. At contact, the drawn gap between the two cars is a median of 126 units (about 3 car lengths) at 150 ms, and 56 units even at 0 ms. Drawing the other car from the predicted world instead (dead-reckoned on its last known input, corrections smoothed the same way) brings the gap at contact down to 2 units median, 5 max. The page has a toggle for this ("Draw other car"). Recommendation for the design doc: predict and draw from the predicted world anything the own player can touch at close range (cars near you), and keep snapshot interpolation for the rest. This also answers part of S2: replaying 2 cars for about 7 ticks per snapshot is trivial, and that is the depth S2 should cost with 16 cars.

Other settings that held up:

- 30 Hz sim with 20 Hz snapshots is fine. Replay depth settles at 6 to 7 ticks at 150 ms RTT.
- A 2-tick server input buffer with clock steering (client speeds up or slows down by up to 8% to keep the minimum arrival slack at the buffer target) settles in about 2 seconds; the client then runs 5 to 6 ticks ahead of the server at 150 ms.
- Sending the last 8 frames per datagram makes 2% loss invisible: after warm-up the server never had to repeat a frame because of loss.
- At 250 ms RTT, ±30 ms jitter and 5% loss, the largest correction was 22 units. That is visible as a short glide, not a snap.

## How to judge it (Jeff)

Open `s3.html` straight from disk in Chrome, Firefox or Safari (the WASM is inlined, no server needed), or use the hosted copy linked in the project thread.

1. Leave the network settings at their defaults: 150 ms RTT, ±10 ms jitter, 2% loss, 100 ms smoothing. Set "Other car" to "chases you" so there is something to bump into.
2. Press **Start trial**. Each trial resets the world and secretly picks zero latency or networked. Drive and drift (Space is the handbrake) for 20 to 30 seconds, bump the blue car, then press **Felt like zero latency** or **Felt networked**.
3. Do at least 10 trials. The tally shows your score and the chance of doing that well by guessing. At 10+ trials, p < 0.05 means you can tell them apart (fail); otherwise it passes.
4. Run it once with "Draw other car" set to interpolated and once set to predicted. Both views get the same remote-car treatment, so the trials test the own car; the toggle shows the remote-car problem above.

**Free A/B**: outside a trial, Tab flips between A and B, one of which is networked; "Reveal and reshuffle" tells you which. The debug overlay (G) shows the latest server state in green and the unsmoothed prediction in yellow, plus lead, replay depth and correction sizes; it is turned off during trials.

Note: in free A/B the two views can drift apart after you hit the other car, so a flip can jump. That jump is not a prediction snap; judge the driving within each view.

## How it works

- `sim.zig`: fixed-point (Q16.16) car physics with a drift model (grip drops when sliding or on the handbrake), circle collisions with walls, pillars and the other car, no floats at runtime and no allocation. Up to 8 world slots in linear memory; `save`/`load` is a byte copy of a slot. Compiled with Zig 0.17.0 to `wasm32-freestanding` (19 KB).
- `net.js`: the fake network (one-way latency, uniform jitter that also reorders, loss), the server (input buffer, repeat-last on a missing frame, bot driver, 20 Hz full snapshots with the measured input slack), the client (I2-like input frames, last 8 unacknowledged per datagram, rewind-and-replay on each snapshot, exponential error smoothing with a 100 ms window, snaps only above 200 units, clock steering), and the zero-latency reference (the same sim stepped on the same client ticks with the same inputs, no network). The bot stands in for another player: the server decides its input and the client only knows its last one.
- `main.js`, `index.html`: the page. `build.sh` builds the WASM and inlines everything into `s3.html`.
- `headless.mjs`: runs scripted drifting for 2 minutes per case in Node and prints correction sizes, replay depth and frame-to-frame jerk. `node headless.mjs`.

Headless results (2 minutes each, scripted full-throttle drifting with random steer and handbrake; errors in world units, car is 40 long):

| Case | Corrections | p95 error | Max error | Max shown offset |
| --- | --- | --- | --- | --- |
| 150 ms / ±10 / 0%, no other car | 0 | 0 | 0 | 0 |
| 150 ms / ±10 / 2%, no other car | 0 | 0 | 0 | 0 |
| 150 ms / ±10 / 2%, other car wanders | 1 | 2.1 | 2.1 | 1.3 |
| 150 ms / ±10 / 2%, other car chases | 198 | 0.27 | 2.5 | 1.4 |
| 150 ms / ±30 / 2%, chases, 1-tick buffer | 194 | 0.23 | 2.9 | 1.9 |
| 250 ms / ±30 / 5%, chases | 220 | 1.25 | 21.8 | 12.5 |

Limits of this spike: the bot drives smoothly, so it is easier to dead-reckon than a human who flicks the stick; a second human player would produce larger corrections. Snapshots are full state (80 bytes), not delta-encoded. Only one remote entity exists.
