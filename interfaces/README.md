# Frozen interfaces

These are the three contracts that let workstreams A–E proceed in parallel. They were written at the end of the spike phase (M0) from the design doc and the S1–S6 results.

| Interface | Spec | Zig | TypeScript |
| --- | --- | --- | --- |
| I1. Sim ABI | [I1-sim-abi.md](I1-sim-abi.md) | [zig/src/abi.zig](zig/src/abi.zig), [zig/src/stub.zig](zig/src/stub.zig) | [ts/src/abi.ts](ts/src/abi.ts) |
| I2. Input frame | [I2-input-frame.md](I2-input-frame.md) | [zig/src/input.zig](zig/src/input.zig) | [ts/src/input.ts](ts/src/input.ts) |
| I3. Wire protocol | [I3-wire-protocol.md](I3-wire-protocol.md) | [zig/src/wire.zig](zig/src/wire.zig) | [ts/src/wire.ts](ts/src/wire.ts) |

## Checking conformance

```sh
cd interfaces/zig
zig build test                          # Zig tests, including the I1 stub's conformance check
zig build wasm                          # the interfaces also compile for wasm32-freestanding
zig build vectors 2> ../testdata/vectors.txt   # regenerate the cross-language vectors

cd ../ts
npm test                                # tsc, then decode and re-encode every vector byte for byte
```

The vectors are the bytes Zig produces for a frame, a hello, a welcome, a framed reject, a two-player input datagram, a snapshot with update, create, remove and player-row records, an event, a chat line, a player info and a run of varints. TypeScript must decode each one to the expected fields and re-encode it to identical bytes. CI should run both and fail if regenerating `vectors.txt` changes it.

`sim/` must contain `comptime { abi.checkSim(Sim(cfg)); }` for each configuration it builds. Until it does, `abi.Stub` is a conforming sim that hosts and tools can link.

Requires Zig 0.17.0. The TypeScript side has no dependencies beyond `tsc`.

## Changing an interface

As the design doc says: by written proposal, accepted by every affected owner. In practice:

- Open a branch that changes the spec, both language twins and the vectors together.
- Bump `abi_version` (I1) or `protocol_version` (I3) for any change to bytes on the wire or in the state. I2 changes count as both.
- Additions that old readers can ignore still need the proposal. Examples are a new kind number, a new component id, a new event kind or a new message type. They do not need a version bump if old peers reject or skip the addition cleanly.
- Components owned by `sim/` (`Collider`, `Vehicle`, `Pedestrian`, `Weapon`, `Projectile`) change without a proposal. `layout_hash` catches mismatched builds.

## Changes the design doc needs

The spikes change or sharpen these parts of the design doc. Each item names the section, the current text in short, and the replacement.

1. **Architecture, I1 row.** It currently reads `init(map, seed)`, `step(inputs)`, …. It becomes `init(grid, {seed, mode})` and `step(frames, commands)`, plus `tick`/`setTick`, `intents`, `replicaPut`/`replicaRemove`, `views()` and `layout_hash`. Players join and leave through `Command`s in `step`, so replays reproduce joins. S2 passed a player count to `init`.
2. **Simulation core, state layout: "One seeded random number generator inside the state."** This becomes: randomness only from a keyed hash `rand(seed, tick, entity, salt)`. Clients hold only part of the world, and a sequential generator advanced by entities the client cannot see would make every random outcome a misprediction. S2's `sim/` has to switch.
3. **Ambient traffic and pedestrians, and the Netcode summary ("each client predicts only its own player").** S3 measured the problem. With remote cars drawn interpolated 100 ms in the past, the car you hit is drawn about 3 car lengths away at 150 ms RTT. Predicting nearby cars instead brings that to 2 units. The replacement is: predict the own player and vehicle, plus every car and ped within a predict radius, dead-reckoning remote players on their last known input. Snapshot interpolation stays for everything outside the radius. Netcode steps 3 and 4 change to match.
4. **Scaling, "rewind buffer saving only the `Predicted` set."** This becomes: the client saves its whole (partial) state. S2 measured `save`/`load` at about 1 µs and 22.6 KB for 16 players. `Predicted` decides which entities step during replay, not what is saved.
5. **Netcode, "Projectiles predicted cosmetically."** This is now concrete. In `.predict` mode the sim suppresses spawns and despawns and reports them as `Intent`s, which the client draws as effects until the authoritative entity arrives.
6. **Determinism rule 1, "32-bit fixed point; angles are 16-bit."** This should say 16.16 fixed point, one block = 1.0, and angle 0 along +x, growing toward +y (clockwise on screen). S5 uses 14-bit fixed point, 1440-step angles and heading 0 along +y. Workstream A has to convert it when the handling moves into `sim/`.
7. **Static map, "256 by 256 by 8 block grid with per-block slope and collision type."** This becomes a 16-bit cell: shape, the GTA2 slope code (61 codes do not fit S2's byte), ground type and lid road arrows. S5's lane snapping needs the arrows. The grid is 1 MiB.
8. **Input and gamepad, "analog triggers for throttle and brake."** Add: triggers may be digital (S6: Switch Pro ZL/ZR read only 0 or 1), in which case they give full deflection. The sim's pedal ramp, taken from the original by S5, provides the build-up. Also add the I2 button set, and that direct mode is a per-frame bit with `aim` as the target heading. There is no independent twin-stick aim in v1.
9. **Netcode, server: "delta-encoded against that client's last acknowledged snapshot."** This becomes per-entity bases. Because snapshots are partial, each record names its own base snapshot (`base_age`), and the client acks with a 32-snapshot bitfield. The join snapshot is a `baseline` message on the reliable stream.
10. **Bandwidth target, "under 30 kbit/s down per client."** That is about 187 bytes per snapshot at 20 Hz, room for roughly 12 to 15 moving entities with exact deltas (my estimate, not measured). It is kept as the default budget, but it is the number most likely to move. I suggest measuring it at M2 with bots and allowing up to 64 kbit/s if crowded scenes starve. *M2: measured; crowded scenes starve at 187, so the default is now 400 bytes (64 kbit/s).*
11. **Transport and Server and operations, "a C QUIC and HTTP/3 library."** S4 settled this: ngtcp2 with GnuTLS for QUIC and TLS, nghttp3 only for QPACK, and a Zig HTTP/3 and WebTransport layer of about 300 lines that the server owns. nghttp3 cannot send the WebTransport SETTINGS or route its stream types. Close the open question "Which C QUIC library does S4 try first?". Development can use self-signed certificates through `serverCertificateHashes` (ECDSA, at most 14 days).
12. **Joining.** Add `layout_hash` alongside the map hash. Client and server must come from the same sim build, so a client cached from an older deploy is refused and reloads. Deploys of the client and server go out together.
13. **Input and gamepad, local split-screen.** I3 carries up to 4 local players per connection, with `add_local`/`remove_local` mid-session.

Still open, and not blocking the freeze:

- S2 browser runs in desktop Chrome, Firefox and Safari.
- S4 Firefox and Safari against a public host. If they fail, those browsers use the WebSocket path, which I3 already defines.
- S5 feel rating on real data.
- S6 hardware runs.

None of these changes the three interfaces. Whatever they find changes policy (transport choice, mapping tables, tuning).

## What `sim/` changes from S2 to conform

- Add `Command` handling and drop the player count argument to `init`.
- Replace the sequential RNG with `abi.rand`.
- Add `Mode`, make systems skip non-`Predicted` entities in `.predict` mode, and divert spawns and despawns to intents.
- Use `abi.Transform`, `Velocity`, `Health`, `Controller`, `Riding` and `Predicted`. S2's versions already have the same layouts.
- Add `pickup` and `map_object` kinds, in that kind order.
- Replace S2's `Player` with `abi.PlayerRow`.
- Switch the map to the 16-bit `abi.Grid` cell.
- Export `views()`, `layout_hash`, `replicaPut` and `replicaRemove`.
