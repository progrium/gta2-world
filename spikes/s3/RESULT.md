# Spike S3 result: prediction feel

**Question (design doc):** does rewind-and-replay feel right for a drifting car?
**Passes when:** driving at 150 ms round trip and 2% loss shows no visible snapping in a blind comparison with zero latency. For this spike that means 10 or more blind trials scoring no better than chance.

## Answer

**Accepted (19 Nov 2026), with known caveats.** Jeff judged the results good enough to move on. Read strictly, the one complete blind run is not at chance: Jeff got 17 of 21 right, p = 0.004. The breakdown points at the remote car, not the own car:

- **Interpolated other car (11 trials):** the own-car prediction was not detected. Jeff answered "zero latency" on all 11 and caught 0 of the 2 networked trials. The 9 he got right are just the 9 local trials, so this block shows no ability to tell the two apart.
- **Predicted other car (10 trials):** he caught 4 of the 5 networked trials, with 1 false alarm in 5 local ones (8 of 10, p = 0.055 binomial, Fisher exact p = 0.10). The quick correct guesses (6–14 s of driving) suggest an obvious tell. In this mode the networked view draws the blue car dead-reckoned with smoothed corrections, while the zero-latency view draws it exactly, so the tell is most likely the blue car's corrections rather than the own car.

The headless measurements and design are in [README.md](README.md).

## Tester results

| Tester | Browser, OS | Trials | Correct | p (one-sided) | Notes |
| --- | --- | --- | --- | --- | --- |
| Jeff (#2) | Chrome 156, macOS | 21 (11 interpolated, 10 predicted) | 17 | 0.004 | "Tells" field left blank |
| Paul (#3) | Brave 158 (Chromium), Windows | 0 recorded | — | — | Hitches at start and after the tab was in the background |

**Was the randomisation skewed?** No. Jeff's 21 trials were 14 local and 7 networked. A fair coin gives a split at least that uneven 19% of the time. The page draws each trial with `Math.random() < 0.5`, so there is no bias in the code.

**Paul's empty file.** Trials are saved to localStorage only when a guess button is pressed, and the save path looks sound. His saved settings show "Other car" on *wander* and "Draw other car" on *interpolated*. That means he never set it to *chase* as step 1 asks, so he most likely drove in free A/B mode and never pressed **Start trial**. Another possibility: he ran trials on a different copy of the page (the hosted Artifact copy has its own storage) and downloaded the file from the GitHub Pages copy.

**Paul's hitches are a real page bug, but not a prediction problem.** When a tab is hidden, the browser stops calling `requestAnimationFrame`. When the tab comes back, the client's tick accumulator (`net.js`, `update()`) adds the whole hidden time as one `dt`, then runs up to 20 ticks per frame until it has caught up. Each tick also triggers a replay. That fast-forward is the "blue car goes crazy until it catches up" Paul saw. The server model has the same catch-up. The fix for the real client is to cap `dt`, or to resync the clocks on `visibilitychange` instead of fast-forwarding. The design should carry this into M2.

**Known caveats, accepted:**
- No blind run has been at chance overall. The own car looks fine with the interpolated view. In the predicted view the blue car's corrections were noticeable. Before M2, decide whether close-range remote cars are predicted (README recommendation) with smoothing tuned until a blind run passes, or kept interpolated.
- Only one tester completed trials, in one browser.
- The page doesn't recover cleanly from a backgrounded tab (above).
