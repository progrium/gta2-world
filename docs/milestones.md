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

## M3. Deathmatch (in progress, sim and client done locally)

Demo: eight players in one session with weapons, pedestrians, traffic, scoring and sound.

Done, checked locally:

- Sim (`sim/README.md`, "What M3 adds"): four weapons, pickups, rockets and car explosions, burning and wrecked cars, lane-following traffic, ambient recycling, kills, suicides and a frag limit of 10 per round. Golden replay re-recorded; native and WASM match.
- Server: sim events go out as I3 events. Bots fight (aim at the nearest enemy, fire, switch weapons). CI's soak runs 8 players for 30 s with kills, deaths and explosions, and every replay tick matches.
- Client: projectiles, spinning pickups, fire, wrecks and explosions; weapon and ammo HUD, kill feed, round banner, Tab scoreboard; sound cues for shots, hits, deaths, explosions, pickups and weapon switches. Z/X (or LB/RB) switch weapons. Checked headlessly on wil.

- I3 sign-off recorded: event kinds `round_end` (5) and `pickup` (6), the kill's weapon in `c` and the explosion's cause in `a`.
- Fixed from play-testing: cars, peds and players were drawn back to front (GTA2 sprites face down in the style).
- Aligned with Jeff's behaviour notes (`docs/behaviour/`, `sim/README.md`): weapon damage, rates, ranges and ammo in tenths; explosions as 99-tick entities with square blasts, throws and knock-downs and chaining; car damage on the 0-32000 scale with anti-strength, impulse damage, the fire stages and occupants dying in the explosion; car hits that knock peds over, down or dead; peds with one running pace, turn build-up, ground-level jumps and wall sliding; entering and exiting speed limits; full-health pickups; a 70-tick respawn; traffic speed ramps, straight-on junctions and stopping after hitting someone.
- Car handling rebuilt from `car-handling.md` (S5 clean room): pedal, gears, turbo, damage, axle tyre forces, damping, speed caps and the lane-arrow snap, with per-model numbers from the player's `.gci` and the style's car info (`formats/gci.zig`, CARI in `formats/sty.zig`, `formats/cars.zig`). Offline only for now: online games use one default model until the server loads car info too.
- Deep water from car-height.md and ped-movement.md: walking into the sea drowns you (credited to a recent attacker), cars are drawn in, lose drive and sink with their driver.
- Points from scoring.md alongside frags (Jeff's choice): rounds still end at 10 frags; the HUD and scoreboard show points for player and civilian kills with combos, car hits, hijacks and wrecks.
- Car collision from car-collision.md: cars bounce off each other and off walls by impulse at the contact corner, with spin, instead of stopping dead.
- Fixed from play-testing: invisible walls and sticking at ramp tops. Walls are now the map's wall faces (lines on block boundaries, from shape-and-map-collision.md) instead of whole blocks, held in a new `Grid.walls` table (I1, approved by Jeff 2026-11-20). Picking up a weapon you did not have now puts it in your hand.
- More of the notes: the other weapons (dual pistols, silenced machine gun, flamethrower, electro gun, grenades, molotovs) and the armour, invulnerability, double damage and fast reload power-ups. Offline, P drops each kind of pickup in turn for trying them.
- Car height from `car-height.md`: ramp jumps at the climb rate, gravity 1/64, cars tipping off ledges.
- Fixed from play-testing: cars could not drive under overpasses. A ground block with no wall faces (an overpass deck) is now a `slab` (I1 shape 5): a floor you can pass under. Checked natively by driving a car under 40 overpasses on wil, ste and bil.

Open for M3:

- Sounds play the sound board's mapping; cues with no sound mapped are silent.
- Feel trials: weapon balance, traffic density and speed, pickup rates.
- Eight real players needs the public host (parked).

## Behaviour note coverage

Rolled up from `docs/coverage/` by `node tools/coverage/rollup.mjs`. A rule is a numbered "N.M" heading in its note.

<!-- coverage:begin (tools/coverage/rollup.mjs) -->

| note | rules | done | ours | stubbed | blocked | todo | no file / stale rows |
|---|---:|---:|---:|---:|---:|---:|---|
| [camera](coverage/camera.md) | 6 | 3 | 1 | 2 | 0 | 0 |  |
| [car-collision](coverage/car-collision.md) | 7 | 7 | 0 | 0 | 0 | 0 |  |
| [car-handling](coverage/car-handling.md) | 5 | 4 | 0 | 0 | 1 | 0 |  |
| [car-height](coverage/car-height.md) | 8 | 6 | 0 | 0 | 1 | 1 |  |
| [crushers-and-garages](coverage/crushers-and-garages.md) | 4 | 1 | 1 | 0 | 2 | 0 |  |
| [entering-and-exiting-cars](coverage/entering-and-exiting-cars.md) | 5 | 0 | 0 | 0 | 0 | 5 |  |
| [explosions-and-damage](coverage/explosions-and-damage.md) | 9 | 0 | 0 | 0 | 0 | 9 |  |
| [gangs-and-respect](coverage/gangs-and-respect.md) | 3 | 0 | 0 | 0 | 0 | 3 |  |
| [map-geometry](coverage/map-geometry.md) | 3 | 2 | 1 | 0 | 0 | 0 |  |
| [mission-scripts](coverage/mission-scripts.md) | 5 | 2 | 2 | 0 | 1 | 0 |  |
| [ped-ai](coverage/ped-ai.md) | 15 | 5 | 10 | 0 | 0 | 0 |  |
| [ped-movement](coverage/ped-movement.md) | 9 | 7 | 2 | 0 | 0 | 0 |  |
| [police-ai](coverage/police-ai.md) | 7 | 0 | 0 | 1 | 0 | 6 |  |
| [power-ups-death-and-arrest](coverage/power-ups-death-and-arrest.md) | 4 | 0 | 4 | 0 | 0 | 0 |  |
| [projectiles](coverage/projectiles.md) | 4 | 0 | 1 | 0 | 0 | 3 |  |
| [scoring](coverage/scoring.md) | 4 | 1 | 3 | 0 | 0 | 0 |  |
| [script-cars](coverage/script-cars.md) | 7 | 0 | 0 | 0 | 0 | 7 |  |
| [script-characters](coverage/script-characters.md) | 11 | 0 | 0 | 0 | 0 | 11 |  |
| [script-counters](coverage/script-counters.md) | 6 | 2 | 3 | 0 | 1 | 0 |  |
| [script-declarations](coverage/script-declarations.md) | 16 | 0 | 0 | 4 | 1 | 11 |  |
| [script-flow-control](coverage/script-flow-control.md) | 7 | 5 | 2 | 0 | 0 | 0 |  |
| [script-messages](coverage/script-messages.md) | 7 | 5 | 2 | 0 | 0 | 0 |  |
| [script-missions](coverage/script-missions.md) | 7 | 4 | 2 | 1 | 0 | 0 |  |
| [script-objects](coverage/script-objects.md) | 7 | 0 | 0 | 6 | 0 | 1 |  |
| [script-player](coverage/script-player.md) | 5 | 1 | 0 | 0 | 0 | 4 |  |
| [shape-and-map-collision](coverage/shape-and-map-collision.md) | 5 | 4 | 1 | 0 | 0 | 0 |  |
| [traffic-and-car-ai](coverage/traffic-and-car-ai.md) | 7 | 1 | 0 | 0 | 0 | 6 |  |
| [wanted-level](coverage/wanted-level.md) | 6 | 2 | 2 | 1 | 0 | 1 |  |
| [weapons](coverage/weapons.md) | 8 | 0 | 2 | 0 | 0 | 6 |  |
| **all notes** | **197** | **62** | **39** | **15** | **7** | **74** | |

<!-- coverage:end -->
