# server

The dedicated game server (workstream D). One Zig process hosts many sessions; each session is one single-threaded sim stepped from a shared 30 Hz timer. Clients reach it over WebTransport (primary) or WebSocket (fallback), both carrying the I3 wire protocol from `interfaces/`.

M1 status: the server steps workstream A's `sim/` (dm16) on real maps, replicates it to clients with per-entity delta snapshots, records every session for headless replay, and passes an end-to-end check over both transports. See "What was checked" below.

## Layout

| File | What |
| --- | --- |
| `src/main.zig` | Commands (`serve`, `replay`, `maps`, `bot`, `synth-map`), poll loop, HTTP API, signals |
| `src/manager.zig` | Sessions by link id, the shared 30 Hz timer, session create/close, metrics |
| `src/session.zig` | One session: player slots, input buffering and slack, join/resume/leave, the tick, snapshot and baseline sending |
| `src/snapshot.zig` | I3 snapshot policy: interest, priority, byte budget, per-entity bases, plus `Mirror` (the client-side decoder used by bots and tests) |
| `src/replay.zig` | Replay capture format, reader and headless re-run |
| `src/maps.zig` | Operator-installed maps: SHA-256 for I3 `map_hash`, grid built with `formats.grid` (the same builder the browser uses) |
| `src/quic.zig` | QUIC (ngtcp2 + GnuTLS) and the thin HTTP/3 + WebTransport layer from spike S4, now routing to sessions |
| `src/tcp.zig` | HTTP/1.1, the WebSocket fallback, ACME challenge serving, the port-80 redirect |
| `src/bot.zig` | Headless I3 bot clients over WebSocket |
| `src/net.zig` | The `Link`/`Hub` seam between transports and sessions |
| `scripts/` | `build-deps.sh` (ngtcp2 1.26 + nghttp3 1.19), `gen-cert.sh` (dev cert), `soak.sh` (CI), `wt-check.mjs` (WebTransport in headless Chromium) |
| `deploy/` | `setup-vm.sh`, systemd unit, certbot deploy hook |

## Build and test

Zig 0.17.0, cmake, a C compiler, pkg-config and GnuTLS headers (`apt install libgnutls28-dev`).

```sh
cd server
scripts/build-deps.sh                 # ngtcp2 + nghttp3 into deps/out, about 20 s
zig build -Doptimize=ReleaseSafe      # zig-out/bin/gta2-server, hosting sim/ (dm16)
zig build test                        # unit tests, incl. exact replication of the real sim
zig build test -Dsim=stub             # same against the I1 stub
scripts/soak.sh 30 4                  # synthetic map, 4 bots x 2 players, replay check
```

`-Dsim=stub` builds against `abi.Stub` instead of `sim/`; nothing else changes.

## Run locally

Your own GTA2 data directory supplies the maps. Never copy `.gmp` files into the repo.

```sh
scripts/gen-cert.sh certs            # ECDSA P-256, 13 days, for serverCertificateHashes
zig-out/bin/gta2-server serve --data ~/gta2/data --cert certs/cert.pem --key certs/key.pem --replay-dir /tmp/replays
zig-out/bin/gta2-server bot --url ws://127.0.0.1:8080/s/test/ws --map ~/gta2/data/wil.gmp --bots 4 --seconds 20
node scripts/wt-check.mjs $(sha256sum ~/gta2/data/wil.gmp | cut -c1-64) 10 test
zig-out/bin/gta2-server replay /tmp/replays/test-*.g2wr --data ~/gta2/data
```

## Sessions and links

- WebTransport: `https://HOST:PORT/s/<id>`; WebSocket: `wss://HOST/s/<id>/ws`. `<id>` is 1 to 64 of `[A-Za-z0-9_-]`.
- The first `hello` for an unknown id creates the session on the map whose SHA-256 the hello carries, if that map is installed. Otherwise the client gets `reject` 3 ("This server does not have your map file installed."). `--no-create` turns this off.
- `POST /sessions?map=wil[&id=party1]` creates one up front and returns `{"id","map","path"}`.
- A session closes 60 s after its last player leaves (`--idle-close`), or 60 s after creation if nobody joins.
- Hello checks run in I3 order: protocol, abi and `layout_hash`, map hash, capacity.
- A connection silent for 5 s is treated as lost. Its players stay in the world for 10 s; a `hello` carrying the resume token from `welcome` within that window gets the same slots back.

## Input buffering

Each player slot has a 64-tick ring of I2 frames keyed by tick. The step for tick T uses the frame for T if it has arrived; otherwise it repeats the previous controls with the new `seq` (counted in `gta2_slot_frames_repeated_total`). How early each frame arrived is measured in quarter ticks; the minimum over the last second is reported to the client as `slack_q` so it can steer its clock to arrive `input_buffer_ticks` (2) early. `input_ack` is the newest tick for which every frame is held, counting ticks already stepped.

## Snapshots

The I3 wire format is from `interfaces/zig/src/wire.zig`; the policy here is the server's:

- Replicated components per kind come from the sim's `replicated` list, read at comptime with its `views()` table. Codecs are generated from the component types.
- Each client has its own per-entity state: creates and removes are resent until a snapshot containing them is acked; updates name the newest acked snapshot holding the entity (`base_age`), and an entity whose base would be older than 63 is sent as a create.
- An entity unchanged since its acked base, with nothing newer in flight, is skipped until the base is 40 seqs old, then refreshed.
- Interest: entities within 40 blocks (Chebyshev) of any of the client's players (`--interest`, 0 = all).
- Priority: removes, then creates (nearest first), then updates by staleness over distance. Filled up to 400 bytes (`--budget`, 64 kbit/s at 20 Hz; set from the M2 bot soak, net/soak-results-dm16.md), never over 1100 or the transport's limit.
- The baseline goes on the reliable stream after the step that applies the join, so it includes the player's own ped. Datagram snapshots to a client start once it acks the baseline.

This is the part workstream C (netcode) is most likely to tune; it is kept in one file for that reason.

## Replays

`--replay-dir DIR` records every session to `DIR/<session>-<unix time>.g2wr`: a header (sim `layout_hash`, map hash, seed, config) and, per tick, the commands, the frames of occupied slots and `hash()` after the step. `gta2-server replay FILE --data DIR` re-runs it on the same sim build and reports the first tick whose hash differs. A replay recorded by a different sim build is refused (`layout_hash`).

## Observability

- `GET /metrics` (Prometheus text): sessions, joins, rejects by code, ticks, late and skipped ticks; per session players, tick, step time (last, max, total), snapshot encode time; per client RTT (from snapshot acks), snapshots sent and lost, records deferred by the budget, inputs received and expected (uplink loss), bytes; per slot frames received, frames repeated and current slack; QUIC and WebSocket transport counters.
- One stats line per session and client in the log every 30 s.
- Misprediction count and correction size are client-side numbers that I3 does not carry to the server; they need a small reliable message if we want them here (a proposal for I3).
- `GET /healthz`, `GET /config` (WebTransport port, dev cert hash, protocol, abi, layout hash, config), `GET /maps`, `GET /sessions`.

## Deploy

There is no public host yet. `deploy/setup-vm.sh` turns a fresh Ubuntu 24.04 VM into one:

1. Create a VM with a public IPv4 address (1 vCPU is plenty for many sessions) and point a DNS name at it.
2. Open TCP 80, TCP 443 and UDP 443 in the provider's firewall.
3. On the VM: `git clone https://github.com/progrium/gta2-world && cd gta2-world/server && sudo sh deploy/setup-vm.sh game.example.com you@example.com`.
4. Copy your own `.gmp` files to `/var/lib/gta2/data/` and `sudo systemctl restart gta2-server`.
5. Check `https://game.example.com/healthz` and `/maps`.

What the script sets up: Zig 0.17.0 (checksum-verified), the ngtcp2/nghttp3 build, `/usr/local/bin/gta2-server`, a `gta2` system user, `/var/lib/gta2/{data,certs,acme,replays}` (replays kept 14 days), larger UDP buffers, ufw rules, a Let's Encrypt certificate, and the systemd unit. The first certificate is issued with certbot's standalone mode before the server starts; renewals then go through the running server's `/.well-known/acme-challenge/` (port 80, served from `/var/lib/gta2/acme`), and the deploy hook copies the new certificate and sends SIGHUP, which reloads it without dropping games. SIGTERM (systemctl stop) sends `bye` with "shutting down" to every client and exits within 2 s.

With a CA-signed certificate the server runs with `--no-cert-hash`, so `/config` offers no `serverCertificateHashes` and every browser connects normally. The public WebTransport run in Firefox and Safari from spike S4 can use this host.

## What was checked (20 Nov 2026)

- Unit tests: replay round trip; snapshot encode/decode with 20% loss each way on the stub; exact, bit-for-bit replication of every live entity of the real dm16 sim (players, 100 ambient peds, 24 cars, projectiles; all sim-owned components) through the I3 codecs with 20% loss.
- Real maps from Jeff's data (wil, wil-multi, ste), real sim: 8 WebSocket bots with 2 players each (16 players) for 20 s: zero decode errors, zero snapshot loss on loopback, 3 repeated frames per slot at join and none after, slack about 11 quarter ticks against a target of 8, step time about 80 µs average and 340 µs max. Every recorded replay re-ran with matching hashes on every tick.
- WebTransport in headless Chromium against the same server: hello, welcome, baseline on the stream, 20 snapshots/s as datagrams, acked inputs. With `--loss 5` (5% of UDP packets dropped each way) mixed with 3 WebSocket bots in one session: 284 of 300 snapshots arrived, inputs stayed acked, and the session's replay matched.
- ACME challenge serving, the https redirect, `POST /sessions`, and SIGHUP certificate reload, by hand.
- Not checked: a public host, Firefox and Safari, the deploy script on a real VM, and anything longer than a minute.

## Known limits

- Transports from spike S4 keep its limits: no QUIC Retry, no 0-RTT, one packet per `sendto`, one thread.
- The interest centre is the player's car or ped; spectators with no ped get everything.
- Lag compensation for instant-hit weapons is not implemented (M3).
