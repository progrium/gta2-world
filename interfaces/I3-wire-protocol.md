# I3. Wire protocol

**Status:** frozen at v1 (`protocol_version = 1`), 2026-11-19.
**Between:** client (`client/wasm/` and the shell's transport glue) and server.
**Code:** [`zig/src/wire.zig`](zig/src/wire.zig), [`ts/src/wire.ts`](ts/src/wire.ts). Test vectors: [`testdata/vectors.txt`](testdata/vectors.txt).

## Channels

Every connection has two channels:

| Channel | Carries | WebTransport | WebSocket fallback |
| --- | --- | --- | --- |
| **datagram** (unreliable, unordered) | `input`, `snapshot` | session datagrams | one WS binary message = byte `0x00` + one message |
| **stream** (reliable, ordered) | everything else | one client-opened bidirectional stream; each message is `uvarint length` + body | one WS binary message = byte `0x01` + one message |

Each message body starts with its type byte. A datagram is at most **1100 bytes** of I3 payload, and less if the transport reports a smaller maximum. A stream message is at most 1 MiB.

URLs: WebTransport `https://<host>:<port>/s/<session>`, WebSocket `wss://<host>/s/<session>/ws`. The link the player opens names the host and session. The client tries WebTransport first and falls back to WebSocket if the session does not open within 3 s or `WebTransport` is undefined.

S4 found that the server side is ngtcp2, GnuTLS, nghttp3's QPACK decoder and about 300 lines of Zig for HTTP/3 SETTINGS, extended CONNECT and stream routing. HTTP datagram framing (the quarter stream id) belongs to that layer, below I3.

## Encoding

- Integers are little-endian.
- `uvarint` is unsigned LEB128. `svarint` is zigzag, then uvarint.
- `str` is a uvarint byte length followed by UTF-8. Names are at most 32 bytes and chat lines at most 200.

## Message types

| Byte | Name | Channel | Direction |
| --- | --- | --- | --- |
| 0x01 | `hello` | stream | C→S |
| 0x02 | `welcome` | stream | S→C |
| 0x03 | `reject` | stream | S→C, then close |
| 0x04 | `baseline` | stream | S→C |
| 0x05 | `add_local` | stream | C→S |
| 0x06 | `local_added` | stream | S→C |
| 0x07 | `remove_local` | stream | C→S |
| 0x08 | `chat` | stream | C→S |
| 0x09 | `chat_from` | stream | S→C |
| 0x0A | `event` | stream | S→C |
| 0x0B | `player_info` | stream | S→C |
| 0x0C | `bye` | stream | both |
| 0x10 | `input` | datagram | C→S |
| 0x20 | `snapshot` | datagram | S→C |

An unknown type on the stream is a protocol error (`reject` `bad_message`). An unknown or malformed datagram is dropped silently.

## Join

1. The client opens the stream and sends **`hello`**:
   `u32 magic "G2W1"`, `u16 protocol`, `u16 abi`, `u64 layout_hash`, `[32] map_hash` (SHA-256 of the `.gmp` file), `[16] resume_token` (zero for a new join), `u8 transport`, `u8 n`, then `n` names (1–4 local players).
2. The server checks, in order: protocol, then `abi` and `layout_hash`, then map hash, then capacity. Any failure sends **`reject`** (`u8 code`, `str message`) and closes. Codes: 1 protocol, 2 layout, 3 map, 4 full, 5 no such session, 6 bad message, 7 shutting down, 8 resume expired. The shell shows the message as is. For example, code 3 says that the player's map file differs from the server's.
3. Otherwise the server sends **`welcome`**:
   `u16 protocol`, `u32 client_id`, `[16] resume_token`, `u32 server_tick`, `u8 tick_hz` (30), `u8 snapshot_hz` (20), `u8 input_buffer_ticks` (2), `u8 redundancy` (8), `u16 max_players`, `str config_name`, `u8 n`, `n × u8 slot`.
   Then it sends one `player_info` per occupied slot, and a **`baseline`**: a snapshot body (below) whose records are all `create`, covering the joining player's surroundings.
4. Snapshot datagrams follow, as deltas. The client starts sending `input` as soon as it has the baseline.

**Resume:** a `hello` that carries a token issued within the last 10 s gets the same slots, character and score back. A later attempt gets `reject` code 8, and the client retries with a zero token.

**Local players:** `add_local` (`u8 local_index`, `str name`) asks for one more slot on the same connection. The server answers `local_added` (`u8 local_index`, `u8 slot`, with slot 0xFF meaning refused). `remove_local` (`u8 slot`) gives one back. All local players share one input datagram and one snapshot stream.

`layout_hash` also ties client and server builds together: a client cached from an older deploy is refused with code 2. The shell treats that code as "reload the page".

## Input datagram (C→S), sent every client tick

```
u8  type = 0x10
u16 ack_seq      newest snapshot seq received (baselines count)
u32 ack_bits     bit i set = snapshot (ack_seq - i) received; 0 = none yet
u16 send_time    client ms clock mod 65536, echoed for RTT
u8  n_players    1..4
n_players × {
  u8  slot
  u32 newest_tick
  u8  count      1..8
  count × I2 frame (8 bytes), oldest first, for ticks newest_tick-count+1 ..= newest_tick
}
```

The client sends every frame newer than the `input_ack` the server last reported, up to 8 frames. S3 found that 8 frames make 2% loss invisible. The server checks that each frame's `seq` matches its position and drops the datagram if one does not. Frames for ticks the server has already stepped are ignored. The largest datagram is 1 + 2 + 4 + 2 + 1 + 4 × (6 + 64) = 290 bytes.

## Snapshot datagram (S→C), at `snapshot_hz`

```
u8  type = 0x20   (0x04 when sent on the stream as a baseline)
u16 seq           per-client snapshot sequence, wraps
u32 tick          the state after `tick` steps
u16 echo_time     latest input.send_time received
u16 hold_ms       ms between receiving it and sending this; RTT = now - echo_time - hold_ms
u8  n_players
n_players × { u8 slot, u32 input_ack, i8 slack_q }
records...        until the end of the datagram
```

- `input_ack`: the newest tick T for which the server holds this slot's frames for every tick up to T. The client stops resending frames at or before T.
- `slack_q`: the minimum, over the last second, of how early this slot's frames arrived relative to the tick that consumed them, in quarter ticks. A negative value means a frame was late and was repeated. The client speeds its clock up or slows it down by up to 8% to keep the slack near `input_buffer_ticks`. That is S3's clock steering, which settles in about 2 s.

### Records

Records are sorted by strictly ascending handle (`kind << 12 | index`). Player rows use kind 15, with index = slot.

```
uvarint handle_delta   handle - (previous handle + 1); the first record encodes the handle itself
u8      op | base_age << 2
          op 0 update   base_age 1..63
          op 1 create   base_age 0, then u16 generation
          op 2 remove   base_age 0, nothing follows
uvarint mask           create/update: bit i = i-th replicated component of the kind, in ascending ComponentId order
payload                one component delta per set bit, in bit order
```

- **Component delta:** each integer field of the component, in declaration order with nested structs flattened and `_`-prefixed padding skipped, is sent as `svarint(new −% base)` at the field's own width. For a `create`, the base is all zeros. Values are exact, never quantised, so a client that predicts from replicated state starts from the server's bits. Codecs are generated from the component type (`wire.encodeComponent` / `decodeComponent`). The replicated component set of each kind is declared in `sim/` and covered by `layout_hash`. It must include `Controller` for cars and peds, so that remote players can be dead-reckoned (S3).
- **Per-entity base:** `base_age` names the snapshot that holds this entity's base value: the snapshot with seq `this.seq − base_age`. The server picks, for each entity, the newest snapshot the client has acked that contained the entity. The client keeps the decoded values of each entity for the last 64 snapshot seqs it received. An entity whose base would be more than 63 seqs old is sent as `create`.
- **Reliability:** the server keeps sending a `create` until a snapshot containing it is acked, and keeps sending a `remove` until a snapshot containing the remove is acked. `remove` means either despawned or out of interest; the client frees the slot either way. Effects come from `event`s and sim intents.
- **Budget and priority:** this is server policy, not wire format. Each snapshot is filled in priority order (distance, speed, time since last sent, and creates and removes first) until the per-client byte budget is used up, and is never larger than 1100 bytes. The default budget is `64 kbit/s ÷ 20 Hz = 400 bytes`, set at M2 from the bot soak on sim/ (net/soak-results-dm16.md); it was 187 bytes (30 kbit/s) until then.

### Client application

On each snapshot, the client:

1. Decodes the records against its history and writes them into its sim with `replicaPut` or `replicaRemove` and the view columns.
2. Calls `setTick(tick)`.
3. Sets `Predicted` per the I1 policy.
4. Replays its own frames for ticks `tick ..` up to its current tick.
5. Smooths the visible error away over about 100 ms.

Entities outside the predict radius are drawn interpolated between the two most recent snapshots, about 100 ms in the past.

## Other reliable messages

| Message | Body |
| --- | --- |
| `chat` / `chat_from` | `u8 slot`, `str text` |
| `event` | `u32 tick`, `u8 kind`, `u8 a, b, c`, `svarint x, y, z`. Kinds: 1 kill (a = killer slot or 0xFF, b = victim, c = weapon: the sim's weapon index (0-9 since the M3 weapons batch), 0x80 a car, 0x81 fire or a blast with no shooter), 2 joined (a = slot), 3 left (a = slot), 4 explosion (x, y, z, a = cause: 0 rocket, 1 car), 5 round end (a = winner slot; scores have reset), 6 pickup (x, y, z, a = slot, b = what: weapon index 0-9, 10 health, 11 armour, 12 invulnerability, 13 double damage, 14 fast reload; until the M3 weapons batch 0-3 and 4 health). Kinds 5 and 6 and the meaning of c and of explosion's a were added in M3 (signed off by Jeff, 2026-11-20); receivers ignore kinds they do not know. The wider weapon and pickup numbering (same bytes, more values) was added in M3 (approved by Jeff, 2026-11-20). |
| `player_info` | `u8 slot`, `u8 flags` (1 present, 2 bot), `str name`. Sent on join and when a name or presence changes. |
| `bye` | `u8 reason`: 0 leaving, 1 timeout, 2 kicked, 3 shutting down. |

## Timeouts

The client sends `input` every tick. With no datagram from the client for 5 s, the server treats the connection as lost: the character stays in the world for 10 s, then the server issues `Command.leave`. With no snapshot for 3 s, the client shows "reconnecting" and opens a new connection with its resume token.
