# host

The browser host: the native game server's session code running in a Web Worker, so a player's tab can host a game for others over WebRTC.

`host.wasm` is server/src's `Manager` (the `net.Hub`), `Session`, snapshot policy and replay recorder, unchanged, built for wasm32-freestanding and hosting the same comptime `Sim` as `gta2-server` (`sim/`, dm16). The page owns the transports and forwards whole I3 messages; the Worker never sees WebRTC.

## Build

Zig 0.17.0.

```sh
cd host
zig build                       # zig-out/web/host.wasm, ReleaseFast, stripped (~370 KB)
zig build -Dsim=stub            # against the I1 conformance stub instead of sim/
zig build -Doptimize=ReleaseSmall   # ~180 KB, slower
```

`client/build-web.sh` builds it and ships `dist/host-worker.js` (the Worker, esbuild entry `host-worker=src/host/worker.ts` in client/shell/package.json, so it does not overwrite the asset worker's `dist/worker.js`) and `dist/host.wasm` next to `game.wasm`, with versioned URLs like the other files.

There is no native build of host/: server/src/util.zig needs libc (module `c`) on every target except freestanding. The module is tested in Node and Chromium by the soak below, and server/'s own `zig build test` covers the session code natively.

## How the pieces fit

```
page (other workstream)                 host Worker (client/shell/src/host/worker.ts)
  loopback for the host's own player      HostModule (client/shell/src/host/wasm.ts)
  RTCPeerConnection per remote player       host.wasm (host/src/host.zig)
        |  protocol.ts ToHost                 server/src lib.zig: Manager, Session,
        |  opened / stream / datagram /       snapshot, replay, maps, net, util
        |  closed / start / stop                sim/ (dm16), formats/ (map -> grid)
        v                                   
  postMessage, payloads transferred  <-- FromHost: ready / stream / datagram / close / stats / stopped / error
```

- **Contract:** `client/shell/src/host/protocol.ts`. `ToHost`/`FromHost` mirror `net.Hub`/`net.Link` exactly; every payload is a whole I3 message. The Worker is transport-agnostic: any `opened.transport` value behaves the same (it only labels the client), so the host's own loopback player uses the same messages.
- **Peers:** the page picks peer ids. host.zig maps each to a `Peer` that is the `Link`'s `ptr`, and to the manager's own `PeerId` from `Hub.opened`. `Link.sendStream`/`sendDatagram`/`close` append records to one out-queue (`u32 peer, u8 kind, u32 len, bytes`) that the Worker drains after every call and posts as `stream`/`datagram`/`close` with transferred buffers. After `close`, nothing more is queued for that peer; the page sends `closed` when its transport is gone.
- **Time:** every export takes `now` (ns on the Worker's `performance.now()` clock) and sets `util.embedded.now_ns`; nothing inside reads a clock. The one other import is `hostStopwatch`, used only to time the step and the snapshot encode for stats.
- **Timer:** `tick(now)` calls `Manager.advance`, the native server's 30 Hz timer: every due tick runs, up to five late ones in a burst, beyond that it skips ahead. The Worker sets `setTimeout` for `nextDeadline()` after each call. `stats.behindTicks` = ticks run late in a burst + ticks skipped, per window.
- **Stats** (about 1 Hz): the protocol.ts fields (`tick`, `stepUsP50`, `stepUsP99`, `encodeUsP99`, `behindTicks`, per peer `slots`, `rttMs`, `txBps`, `rxBps`) plus `stepUsMax`, `encodeUsP50`, `lateTicks`, `skippedTicks`, `ticks`, `players`, `replayBytes`, per peer `snapshots`, `lost`. Per-tick samples come from `Session.step_ns_sum` and `snapshot_ns_sum` (a catch-up burst shares its average); RTT and bytes are what Session already tracks per client.
- **Session:** one, created at `start` with `create_on_join` off and no idle close (the page stops it). `maxPlayers` below the sim's 16 slots is enforced on `hello` with `reject` 4 (session_full); 0 means the sim's limit. Resume tokens come from a ChaCha CSPRNG seeded with 32 bytes of `crypto.getRandomValues`.
- **Map:** the page hands over the `.gmp` bytes; `maps.Registry.addBytes` hashes them (I3 `map_hash`) and builds the grid with `formats.grid`, the same builder the browser client uses. `synthMap()` returns the server's synthetic city (`maps.synthCity`) for tests and demos.
- **Replay:** with `record`, the session records into memory (`replay.Writer.createMem`); `stop` sends `bye` (shutting_down) and closes every client, and returns the `.g2wr` bytes. `gta2-server replay FILE --data DIR` re-runs it natively.

### What changed in server/src

Only what the wasm build needs; behaviour natively is unchanged (`zig build test` real and stub, `scripts/soak.sh`):

- `util.zig`: on freestanding, no `c` import; `now`, `wallSeconds`, `randomBytes` read `util.embedded`, file helpers return `error.Unsupported`. New `stopwatch()` (natively `now()`).
- `session.zig`: step/encode timing uses `util.stopwatch()`.
- `replay.zig`: `Writer.createMem` / `captured` for in-memory capture.
- `maps.zig`: `Registry.addBytes` (bytes instead of a path), shared `buildGrid`, and `synthCity` moved from main.zig.
- `lib.zig`: module root that re-exports the session code for other hosts.

## Soak

```sh
cd host && zig build && cd ..
(cd client/shell && npm ci)
node host/soak/run.mjs node    --seconds 30 [--replay-dir /tmp/r]   # in-process, virtual clock
node host/soak/run.mjs browser --seconds 30                        # real Worker, headless Chromium
# optional, your own data, kept outside the repo:
node host/soak/run.mjs browser --seconds 30 --map /tmp/gta2data/wil.gmp
server/zig-out/bin/gta2-server replay /tmp/r/soak-16p.g2wr --data DIR_WITH_THE_MAP
```

- `soak/players.ts`: synthetic I3 players (interfaces/ts wire codecs): hello, 30 Hz input datagrams with random steering and redundant frames, snapshot acks, clock steering from `slack_q`.
- `soak/node.ts`: host.wasm in Node on a virtual clock; checks welcome/baseline/snapshots/acks/byes and the `maxPlayers` reject.
- `soak/page.ts`: the soak page; starts the real `worker.ts` and runs the players on the main thread through protocol.ts messages.
- `soak/run.mjs`: bundles with the shell's esbuild, serves from memory with COOP/COEP (cross-origin isolated, 5 us timers), drives Chromium with Playwright, prints a table per player count (2, 4, 8, 16 by default; `--players`, `--wasm`).

## What was measured

Full tables in [soak-results.md](soak-results.md). On a 4 vCPU 2.1 GHz cloud VM, headless Chromium, real sim:

| players | step p50 / p99 us | encode p50 / p99 us | behind ticks (30 s) |
|---|---|---|---|
| 2 | 120 / 230 | 80 / 145 | 0 |
| 4 | 115 / 190 | 145 / 255 | 0 |
| 8 | 130 / 230 | 275 / 440 | 0 |
| 16 | 135 / 220 | 575 / 895 | 0 |

A 16-player tick (step + encode) is about 1.1 ms at p99, 3% of the 33 ms budget; wil.gmp (run locally on the user's own data) gives the same numbers. Replays recorded in the wasm host re-run bit-exact on the native server.

## Known limits

- Not run over real WebRTC, in a background tab, or on slow hardware; see soak-results.md.
- `Map` pointers live in a growable list in `maps.Registry`; fine for the host's single map.
- The out-queue grows without bound if the Worker stops draining (it drains after every call).
