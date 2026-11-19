# Spike S2 result: sim cost and determinism

**Question (design doc):** is a fixed-point sim cheap enough to replay, and identical on WASM and native?
**Passes when:** a WASM step takes under 0.5 ms, the native step time at 200 players is recorded, and a 10,000-tick replay hashes match on native and in three browsers.

## Answer

**Accepted (19 Nov 2026), with known caveats.** Jeff judged the results good enough to move on. Every run so far passes: native, Node, headless Chromium, and two real Chromium browsers on macOS and Windows all reach the same final hash, and the 16-player step is about 70x under budget. Firefox and Safari were never run. That's a known caveat, not a fail, because the sim is integer-only and nothing in it depends on the JS engine.

The measurements and design are in [README.md](README.md).

## Tester results

Scored from the results issues. Pass is "hashes MATCH" and a 16-player step under 0.5 ms.

| Tester | Browser, OS, machine | Replay (10,000 ticks, 100 rewinds) | Final hash | 16-player step, mean | 10-tick replay | 200-player step, mean | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Jeff (#1) | Chrome 156, macOS, MacBook Pro M3 Max, plugged in | MATCH, 123 ms | `1eab16d2aa3817a2` | 0.0054 ms | 0.047 ms | 0.107 ms | Pass |
| Paul (#4) | Brave 158 (Chromium), Windows | MATCH, 127 ms | `1eab16d2aa3817a2` | 0.0071 ms | 0.066 ms | 0.147 ms | Pass |

The final hash matches the native ReleaseFast, ReleaseSafe and Debug runs in the README. Both machines are faster than the cloud VM, so the README's headroom estimate holds on real hardware. The single-tick p99 values in the files (0.1–0.2 ms) are limited by the browser's 0.1 ms timer and not meaningful. The 100-tick batch means are the reliable figures.

Paul's issue title says "Chrome 158". The file's user-agent data shows the browser is Brave 158, which uses the same Chromium V8 engine.

**Known caveats, accepted:**
- No Firefox (SpiderMonkey) or Safari (JavaScriptCore) run, so the "three browsers" in the criterion are really one engine on two OSes. Re-run the page in both before M1 if possible. It takes about a minute and needs no build.
- The physics is a toy (see README "Caveats"). The 70x headroom is what S5 handling, real collisions, weapons and AI have to fit in.
