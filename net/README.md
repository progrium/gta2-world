# net/: workstream C netcode

Client prediction with rewind-and-replay, error fading, snapshot interpolation, and per-component delta snapshots filled by priority up to a per-client byte budget, all as specified by I3. Everything is generic over an I1 sim type, so it runs unchanged on the stand-in arena sim here and on workstream A's `sim.Sim16` (checked: 35 KB state, six kinds, round trip and client replay run clean).

```sh
cd net
zig build test                                  # unit and round-trip tests
zig build wasm                                  # the netcode builds for wasm32
zig build -Doptimize=ReleaseFast && zig-out/bin/soak 120   # headless soak, 120 s per case
zig build -Dsim=real -Doptimize=ReleaseFast && zig-out/bin/soak 120 [--map file.gmp]   # same soak on sim/ (dm16)
```

## Pieces

| File | Side | What it does |
| --- | --- | --- |
| `src/schema.zig` | both | The replicated set per kind, read from `S.replicated` (tuple of kind and component types in ascending id; agreed with A). Packs an entity's replicated components into one value, diffs and codes them with the I3 generated codecs. |
| `src/encoder.zig` | server | `History`: the last 64 snapshot states, shared by every client, so bases are read from the state the client acked and nothing is copied per client. `ClientEncoder`: per-entity create/known/removing state, newest-acked base per entity, interest radius with hysteresis, priority that accumulates while an entity has unsent changes and falls off with distance squared, greedy fill to the budget with up to two snapshots of carry-over, records in handle order. |
| `src/decoder.zig` | client | Decodes against the last 64 received seqs, keeps ack bits, drops (and does not ack) stale snapshots and snapshots naming a base it lacks, writes records with `replicaPut`/`replicaRemove`. |
| `src/inputbuf.zig` | server | Per-slot input buffer: repeat-last on a missing frame, `input_ack`, `slack_q` as the 1 s minimum in quarter ticks. |
| `src/client.zig` | client | Ring of 64 predicted states and frames; on each snapshot loads the state at its tick, applies records, picks the Predicted set (own entities plus cars and peds within 6 blocks, leave at 8), replays to the present, and turns each drawn entity's jump into a fading offset. Interpolates everything else 100 ms in the past, dead-reckoning up to 8 ticks past the newest sample. Clock steering on `slack_q`. A frame gap over 250 ms (background tab) runs one tick and lets the next snapshot pull the clock forward, so there is no fast-forward burst (S3's bug). `renderState()` hands the renderer one state with display transforms written in, which B's `render.list.build(.., null, state, 1, ..)` takes. |
| `src/link.zig` | test | Fake datagram link: latency, jitter that reorders, loss, optional bursts. Seeded. |
| `src/testsim.zig` | test | Stand-in I1 sim: S3's drift handling in I1 units, car contacts, 24 AI cars and 100 peds on `abi.rand`, spawns and despawns so generations churn, `.predict` mode. Replace with `sim/` once A's branch merges. |
| `tools/soak.zig` | test | One server, one predicting client, bot players, scripted drifting. Deterministic. Its world is `tools/soak_testsim.zig` (the arena) or, with `-Dsim=real`, `tools/soak_realsim.zig` (sim/ dm16 on the test map or a `--map`). |

## Soak results

This table is the arena sim at the old 187-byte default; the sim/ (dm16) run is in [soak-results-dm16.md](soak-results-dm16.md).

120 s per case, scripted full-throttle drifting with handbrake, 16-slot arena with 24 AI cars and 100 peds. Distances in blocks (a car is 0.9 long, a block is 64 px in the original). "Corr" is the size of the jump the snapshot caused in the drawn position before fading, which is what S3 reported. "Gap at contact" is the drawn distance between two cars at the moment they touch in the predicted world. "Jerk" is the frame-to-frame change in drawn velocity at 60 fps: the snapping a player would see. Full table with counts, replay depth and timing: [soak-results.md](soak-results.md).

| case | own corr p95 | other predicted corr p95 | gap at contact p99 | own jerk p99 | near-car jerk p99 | kbit/s | B/record | stalest update (snapshots) |
|---|---|---|---|---|---|---|---|---|
| 0 ms, 0% loss, 3 chasers | 0.027 | 0.553 | 0.112 | 0.0208 | 0.0978 | 30.0 | 20.7 | 36.30 |
| 150 ms +-10, 2%, 3 chasers | 0.024 | 0.653 | 0.052 | 0.0266 | 0.1053 | 30.0 | 22.0 | 35.11 |
| same, S3 smoothing (100 ms, no cap) | 0.024 | 0.653 | 0.039 | 0.0466 | 0.1831 | 30.0 | 22.0 | 35.11 |
| same, fast fade near own car | 0.024 | 0.653 | 0.038 | 0.0466 | 0.1497 | 30.0 | 22.0 | 35.11 |
| same, predict own car only | 0.351 | 0.000 | 2.759 | 0.0515 | 0.0646 | 30.0 | 22.0 | 35.11 |
| same, predict radius 3 | 0.058 | 0.700 | 0.353 | 0.0266 | 0.1553 | 30.0 | 22.0 | 35.11 |
| 150 ms, 2%, 3 flickers | 0.455 | 2.483 | 4.192 | 0.0127 | 0.1731 | 30.0 | 19.3 | 20.56 |
| same, S3 smoothing | 0.455 | 2.483 | 1.516 | 0.0127 | 0.5465 | 30.0 | 19.3 | 20.56 |
| 150 ms, 2%, 7 wanderers | 1.067 | 6.463 | 2.519 | 0.0203 | 0.2005 | 30.0 | 21.1 | 34.25 |
| same, S3 smoothing | 1.067 | 6.463 | 0.588 | 0.0376 | 0.7022 | 30.0 | 21.1 | 34.25 |
| 150 ms, 2%, 15 chasers, 187 B | 0.821 | 1.318 | 1.163 | 0.0811 | 0.1771 | 30.0 | 25.1 | 57.18 |
| same, 300 B (48 kbit/s) | 0.109 | 0.275 | 0.769 | 0.0503 | 0.1289 | 48.1 | 23.8 | 41.21 |
| same, 400 B (64 kbit/s) | 0.067 | 0.199 | 0.606 | 0.0446 | 0.1092 | 64.1 | 23.6 | 29.05 |
| 250 ms +-30, 5% bursty, 3 chasers | 0.450 | 1.741 | 0.988 | 0.0398 | 0.1269 | 30.0 | 22.6 | 41.75 |
| 150 ms, 2%, 3 s background tab | 0.293 | 1.690 | 0.265 | 0.0301 | 0.1253 | 30.0 | 22.6 | 39.47 |

### What the numbers say

1. **The own car is solid at 150 ms and 2% loss.** Corrections are 0.024 blocks at p95, about 1.5 px, and own-car jerk is within 30% of the zero-latency run. Replay depth settles at 7 ticks (max 8) and costs about 11 µs per snapshot natively for this sim.
2. **Predicting nearby cars fixes S3's contact problem.** Drawn gap when cars touch is 0.05 blocks at p99. With only the own car predicted it is 2.8 blocks (about three car lengths, as S3 found), and own corrections grow fifteenfold.
3. **The tell in Jeff's blind trials was the remote cars' corrections, and it can be smoothed below the zero-latency level.** With S3's 100 ms fade, near-car jerk is 1.9 times the zero-latency run. Fading others over 250 ms and capping the fade at 4 blocks/s brings it to 1.08 times (chasers), and cuts it 3 to 3.5 times for human-like flick steering and wandering bots. That is the new default. The cost: a car that mispredicts badly just before touching you can be drawn up to a few blocks off at contact (flickers p99 4.2 vs 1.5, from only 26 contacts). Snapping the fade to the own rate near the own car undoes most of the jerk gain, so it is an option, off by default. This needs a new blind run to settle.
4. **187 bytes per snapshot (30 kbit/s) is too tight for a crowded scene.** A moving car costs about 21 bytes per update against a base 2 to 4 snapshots old. With 3 chasers, everything near the player still updates every snapshot because priority falls off with distance squared, and only far entities wait (up to 1.8 s). With all 16 players chasing in one spot, own corrections jump to 0.82 blocks at p95. 300 bytes (48 kbit/s) brings that to 0.11 and 400 bytes (64 kbit/s) to 0.07. I suggest a 400-byte default and measuring real crowding with bots at M2, as the I3 draft already proposed. **Settled at M2:** the same soak on sim/ (dm16), on the test map and on wil, gives the same ordering, so the default is now 400 bytes ([soak-results-dm16.md](soak-results-dm16.md)).
5. **A 3 s background tab recovers with no catch-up burst**: the first snapshots after it jump the clock forward (5 resync events in the run), at the price of one visible glide of the own car when the clock is pulled forward (max offset 3.7 blocks).

### Things to know

- Remote players inside the predict radius are dead-reckoned on their last replicated input, so predicted-remote corrections grow with how erratic the other driver is (p95 0.65 blocks for chasers, 2.5 for flickers, 6.5 for waypoint wanderers whose target jumps). The fade hides most of it; a remote-input model that decays steering toward zero is the next thing to try if blind trials still catch it.
- `max B` can exceed the budget by up to two snapshots of saved credit, never 1100.
- The baseline goes on the reliable stream and is not budgeted (643 B for A's Sim16 with three players).
- Priority weights, interest radius (28 enter, 32 leave) and predict radius (6 enter, 8 leave) are first guesses tuned on this arena. Revisit on a real map.
