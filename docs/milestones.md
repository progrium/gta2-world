# Milestones: where the build stands

Integration branch: `claude/project-thread-6bbchu`. It merges every M1 workstream branch (sim `claude/project-thread-t3gec3`, formats and renderer `claude/project-thread-84o8wj`, server `claude/project-thread-exyid4`, shell `m1/shell`, netcode `m1/net`) and adds the pieces that join them.

## M1. Drive (done, 2026-11-20)

Demo: one player drives and walks an original map with a gamepad, the sim running in WASM; the headless server steps the same sim.

- `client/wasm` builds `game.wasm` (about 90 KB): `sim/` (dm16), `formats/`, the renderer's Zig side and `net/`.
- The shell's game screen loads the player's own `.gmp` and `.sty` from the OPFS cache, steps the sim at 30 Hz and draws with the WebGL2 renderer and chase camera.
- Offline play is the tester site's `play/` page. Keys: V drops a car in front of you, Enter/F gets in and out, T opens live tuning of `sim/tuning.zig` (persisted, copy as Zig, submit as an issue), N night, R respawn.
- Checked headlessly on wil (software GL): walking, entering a car, driving, 46 to 58 fps. Not checked: a real gamepad and a real GPU.
- The server steps the same sim on the same maps; its replays re-run with matching hashes (see `server/README.md`).
- I1 sign-off recorded: `Appearance` is component 12, and the re-recorded golden replay is the reference.

## M2. Two-player (in progress)

Demo: two browsers on different networks share a session over the real transport, with prediction on.

Done, checked locally:

- Online mode in `game.wasm`: `net/`'s prediction client runs the sim in `.predict` mode against server snapshots (rewind and replay, error fading, interpolation, clock steering).
- `client/shell/src/net/connection.ts`: I3 over WebTransport (dev certificate hash from the server's `/config`), falling back to WebSocket after 3 s or when WebTransport is missing.
- Two headless Chromium tabs on wil, one session, over WebTransport and over WebSocket: both join, each predicts its own player (replay depth 7 to 8 ticks at about 25 ms RTT), and B draws A within 0.02 blocks of where A draws itself. The server's replay of the session matches on every tick.

How to play it locally:

```sh
cd server && scripts/build-deps.sh && zig build -Doptimize=ReleaseSafe
scripts/gen-cert.sh certs
zig-out/bin/gta2-server serve --data ~/gta2/data --cert certs/cert.pem --key certs/key.pem
# then open, in two browser windows:
#   https://progrium.github.io/gta2-world/play/?server=http://127.0.0.1:8080#s=party1
```

Chrome may ask to allow the page to reach devices on your local network; allow it. `&transport=websocket` forces the fallback. Tuning and the V car are offline only, because tuning numbers are not part of the state.

Open for M2:

- **A public host** for "different networks" and for Firefox and Safari (Jeff: not now).
- **Spawning near each other.** Done: a player joining without a spawn hint lands on pavement 3 to 12 blocks from the first player already in the world (sim/tuning.zig `spawn_near_*`), so the default interest radius works and `--interest 0` is no longer needed.
- **Snapshot budget.** Done: 400 bytes (64 kbit/s), from the bot soak on sim/ on the test map and wil (net/soak-results-dm16.md). The soak on sim/ runs in CI (net.yml).
- Blind feel trials of online driving. (CI already runs the server bot soak with replay checks, server.yml, and the netcode soak on sim/, net.yml.)
