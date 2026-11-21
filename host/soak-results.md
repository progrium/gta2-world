# Host soak results (20 Nov 2026)

host.wasm (ReleaseFast, real `sim/` dm16) with 2, 4, 8 and 16 synthetic players, 30 s each. Every player is one I3 client with one local player: hello on the stream, then input datagrams at 30 Hz with random steering (redundant frames back to the last acked tick, clock steered from `slack_q`), every snapshot acked. Produced by `host/soak/run.mjs`; see host/README.md for how to run it.

Machine: cloud VM, 4 vCPU Intel Xeon @ 2.10 GHz. Headless Chromium 157.0.8103.78 (Playwright), Node 22.23.5.

Times are per 30 Hz tick. "step" is the sim step plus input handling (Session.tick up to the snapshots); "encode" is building and queuing every client's snapshot or baseline that tick. Both are measured inside the module with the Worker's `performance.now()` (cross-origin isolated, so 5 us resolution; the browser numbers are multiples of 5). p50 is the median of the 1-second windows' p50; p99 is given as the median and the worst of the windows' p99; the first 3 windows (joins, baselines, JIT warm-up) are left out. The budget per tick is 33 333 us.

## Browser: the real host Worker in headless Chromium

`node host/soak/run.mjs browser --seconds 30` (synthetic city from `maps.synthCity`, no game data)

| players | step p50 us | step p99 us (median / worst 1 s) | step max us | encode p50 us | encode p99 us (median / worst) | ticks | behind ticks | skipped | input timer late p99 ms | down kbit/s per peer |
|---|---|---|---|---|---|---|---|---|---|---|
| 2 | 120.0 | 230.0 / 5335.0 | 5335.0 | 80.0 | 145.0 / 525.0 | 788 | 0 | 0 | 4.2 | 58.4 |
| 4 | 115.0 | 190.0 / 995.0 | 995.0 | 145.0 | 255.0 / 2775.0 | 788 | 0 | 0 | 4.3 | 58.5 |
| 8 | 130.0 | 230.0 / 4005.0 | 4005.0 | 275.0 | 440.0 / 1510.0 | 790 | 0 | 0 | 4.3 | 58.5 |
| 16 | 135.0 | 220.0 / 685.0 | 685.0 | 575.0 | 895.0 / 14760.0 | 788 | 0 | 0 | 4.3 | 58.2 |

`node host/soak/run.mjs browser --seconds 30 --map /tmp/gta2data/wil.gmp`: **run locally on wil.gmp** from the user's own data, extracted to a scratch directory outside the repo and served from memory; nothing from it is committed.

| players | step p50 us | step p99 us (median / worst 1 s) | step max us | encode p50 us | encode p99 us (median / worst) | ticks | behind ticks | skipped | input timer late p99 ms | down kbit/s per peer |
|---|---|---|---|---|---|---|---|---|---|---|
| 2 | 105.0 | 185.0 / 1635.0 | 1635.0 | 85.0 | 145.0 / 220.0 | 788 | 0 | 0 | 4.2 | 58.8 |
| 4 | 115.0 | 205.0 / 1100.0 | 1100.0 | 150.0 | 240.0 / 425.0 | 787 | 0 | 0 | 4.3 | 58.7 |
| 8 | 130.0 | 220.0 / 1410.0 | 1410.0 | 295.0 | 485.0 / 1355.0 | 788 | 0 | 0 | 4.3 | 58.6 |
| 16 | 130.0 | 225.0 / 785.0 | 785.0 | 595.0 | 905.0 / 3050.0 | 789 | 0 | 0 | 4.2 | 58.4 |

- Every run: all players welcomed with a baseline, at least 15 snapshots/s each, no rejects, no host-side closes, no Worker errors; `stop` returned the replay (28 KB at 2 players to 129 KB at 16 for 30 s).
- **Behind ticks 0 in every run**: the Worker's setTimeout never woke late enough to need a catch-up tick. "input timer late" is how late the page's own 30 Hz setTimeout loop (the synthetic players) fired: about 4 ms at p99.
- A 16-player tick costs about 0.7 ms at p50 and 1.1 ms at p99 (step + encode), about 3% of the tick budget, on one core. The sim step barely grows with players (dm16 always simulates its ambient peds and cars); snapshot encoding grows linearly, about 36 us per client per tick.
- The worst single ticks (up to 15 ms once, in one window) are isolated: no window's p99 came near the budget and no tick was ever behind. Likely GC or a tier-up in the Worker; not investigated.
- Downlink per peer is about 58 kbit/s, the server's 400-byte budget at 20 Hz, unchanged from native.

## Node: host.wasm in-process on a virtual clock

`node host/soak/run.mjs node --seconds 30 --replay-dir DIR` (pure compute: messages delivered instantly, ticks run back to back).

Synthetic city:

| players | step p50 us | step p99 us (median / worst 1 s) | step max us | encode p50 us | encode p99 us (median / worst) | ticks | wall time for the run |
|---|---|---|---|---|---|---|---|
| 2 | 57.2 | 92.3 / 4086.2 | 4086.2 | 42.9 | 78.3 / 268.9 | 810 | 0.1 s |
| 4 | 78.9 | 134.9 / 202.5 | 202.5 | 121.3 | 179.5 / 5116.7 | 810 | 0.2 s |
| 8 | 45.2 | 86.8 / 295.2 | 295.2 | 153.0 | 200.7 / 373.9 | 810 | 0.2 s |
| 16 | 63.5 | 115.6 / 5155.1 | 5155.1 | 435.5 | 565.8 / 10181.7 | 810 | 0.4 s |

wil.gmp (run locally, as above):

| players | step p50 us | step p99 us (median / worst 1 s) | step max us | encode p50 us | encode p99 us (median / worst) | ticks | wall time for the run |
|---|---|---|---|---|---|---|---|
| 2 | 70.3 | 117.1 / 1492.5 | 1492.5 | 67.0 | 100.8 / 1030.9 | 810 | 0.2 s |
| 4 | 45.4 | 75.5 / 340.8 | 340.8 | 91.0 | 127.7 / 4948.1 | 810 | 0.1 s |
| 8 | 49.7 | 95.1 / 10389.8 | 10389.8 | 192.0 | 250.6 / 556.8 | 810 | 0.2 s |
| 16 | 57.2 | 93.1 / 242.7 | 242.7 | 445.9 | 514.8 / 877.7 | 810 | 0.4 s |

- All 8 runs passed the protocol checks (welcome, baseline, snapshots, no unacked snapshots at the end, one `bye` per player on stop), plus the capacity check: `maxPlayers` 2 with 3 players rejects the third with `session_full`.
- **Determinism across builds:** every replay these runs recorded inside host.wasm (4 on the synthetic city, 4 on wil) was re-run by the native `gta2-server replay` (x86_64): "every tick matches" for all 900 ticks of each. The wasm host and the native server step the same sim bit for bit.
- Step time in Node is about half the Chromium Worker's (warm, tight loop, no timer wake-ups between ticks). Encode is close to Chromium's.

## For comparison: the native server

`server/scripts/soak.sh 8 4` on the same VM (ReleaseSafe gta2-server, 4 WebSocket bots x 2 players = 8 players, synthetic city): step time 96 us on average over 302 ticks, 1.0 ms max. server/README.md reports about 80 us average on wil with 16 players on another machine. host.wasm in a Chromium Worker is in the same range (about 130 us p50 step).

## Not measured

- Real WebRTC transports (the page side is another workstream): here the page posts messages straight to the Worker, so these numbers have no network, no DTLS/SCTP cost and no loss.
- A host tab in the background (Chrome throttles timers in hidden pages' main threads; dedicated Workers are throttled less, but this was not tested), a slow laptop or phone, or anything longer than 30 s per run.
- The host player's own game running in the same tab alongside the Worker (rendering competes for the CPU, though the Worker has its own thread).
