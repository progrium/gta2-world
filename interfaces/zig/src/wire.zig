//! I3. Wire protocol between client and server.
//!
//! Frozen interface. Spec: interfaces/I3-wire-protocol.md. This file has the
//! message ids, header layouts, the varint and component-delta codecs, and
//! encoders/decoders for every message except snapshot record payloads,
//! whose per-component codecs are generated from component types with
//! `encodeComponent` / `decodeComponent`.
//!
//! All integers little-endian. uvarint = unsigned LEB128. svarint = zigzag
//! then uvarint. str = uvarint byte length + UTF-8 bytes.

const std = @import("std");
const abi = @import("abi.zig");
const input = @import("input.zig");

pub const protocol_version: u16 = 1;
/// "G2W1" read as a little-endian u32.
pub const magic: u32 = 0x3157_3247;

/// Largest datagram payload either side may send (I3 bytes, after the
/// transport's own framing). Senders must also respect a smaller
/// transport-reported maximum.
pub const max_datagram = 1100;
/// Largest reliable-stream message body.
pub const max_stream_message = 1 << 20;
/// Most input frames per player per datagram.
pub const max_redundancy = 8;
/// Most local players on one connection (split-screen).
pub const max_local_players = 4;
/// How far back an update may reference its base, in snapshot seqs.
pub const max_base_age = 63;
pub const max_name_len = 32;
pub const max_chat_len = 200;

pub const handle_player_row_base: u16 = @as(u16, @intFromEnum(abi.Kind.player_row)) << 12;

/// Message type, first byte of every message on either channel.
pub const Msg = enum(u8) {
    // Reliable stream.
    hello = 0x01,
    welcome = 0x02,
    reject = 0x03,
    baseline = 0x04,
    add_local = 0x05,
    local_added = 0x06,
    remove_local = 0x07,
    chat = 0x08,
    chat_from = 0x09,
    event = 0x0A,
    player_info = 0x0B,
    bye = 0x0C,
    // Datagrams.
    input = 0x10,
    snapshot = 0x20,
    _,

    pub fn isDatagram(m: Msg) bool {
        return @intFromEnum(m) >= 0x10;
    }
};

/// WebSocket fallback: each binary WebSocket message is one channel byte
/// followed by exactly one I3 message.
pub const WsChannel = enum(u8) { datagram = 0, stream = 1, _ };

/// 2 (webrtc) was added after the v1 freeze: browser-hosted games over
/// WebRTC data channels. Old servers never see it (they are not WebRTC peers).
pub const Transport = enum(u8) { webtransport = 0, websocket = 1, webrtc = 2, _ };

pub const RejectCode = enum(u8) {
    protocol_mismatch = 1,
    layout_mismatch = 2,
    map_mismatch = 3,
    session_full = 4,
    session_not_found = 5,
    bad_message = 6,
    shutting_down = 7,
    resume_expired = 8,
    _,
};

pub const ByeReason = enum(u8) { leaving = 0, timeout = 1, kicked = 2, shutting_down = 3, _ };

pub const EventKind = enum(u8) {
    /// a = killer slot (0xFF = world), b = victim slot, c = weapon id
    kill = 1,
    /// a = slot
    player_joined = 2,
    /// a = slot
    player_left = 3,
    /// x, y, z of an explosion; a = cause (0 rocket, 1 car)
    explosion = 4,
    /// a = winner slot; every score has been reset (M3)
    round_end = 5,
    /// x, y, z of a pickup taken; a = slot, b = what (weapon index, 4 health) (M3)
    pickup = 6,
    // 7-18: single player, reserved 2026-11-20 (W0 of docs/plan-notes.md).
    // Text ids are indices into the level's string table, carried in x.
    /// a = slot, x = text id: a one-line banner message
    message = 7,
    /// a = slot, x = text id: a mission brief (pager)
    brief = 8,
    /// a = slot, b = stars now, c = stars before
    wanted = 9,
    /// a = slot, b = cause (the kill event's weapon numbering)
    wasted = 10,
    /// a = slot
    busted = 11,
    /// a = slot, x = mission id
    mission_start = 12,
    /// a = slot, x = mission id
    mission_pass = 13,
    /// a = slot, x = mission id
    mission_fail = 14,
    /// x, y, z of the phone; a = 1 ringing, 0 stopped
    phone_ring = 15,
    /// x, y, z of the vehicle; a = 1 on, 0 off (cosmetic)
    siren = 16,
    /// a = slot: no lives left
    game_over = 17,
    /// a = slot: the level's target score was reached
    level_complete = 18,
    /// x, y, z of the speaker; a = what (0 a cop shouts "Freeze!", 1 police
    /// radio chatter), b = the pursued slot (cosmetic, police-ai.md)
    police_voice = 19,
    /// x, y, z of a spray shop; a = slot, b = the car's new remap, c = 0 no
    /// wanted level, 1 wanted level cleared (paid), 2 could not pay
    respray = 20,
    /// x, y, z of a car whose alarm went off (sim/sys/car_flags.zig)
    car_alarm = 21,
    _,
};

pub const Error = error{ Truncated, Overflow, BadMessage, TooLong };

// ---------------------------------------------------------------------------
// Cursor-style writer and reader over caller-owned buffers.

pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn bytes(w: *Writer, b: []const u8) Error!void {
        if (w.pos + b.len > w.buf.len) return error.Overflow;
        @memcpy(w.buf[w.pos..][0..b.len], b);
        w.pos += b.len;
    }
    pub fn int(w: *Writer, comptime T: type, v: T) Error!void {
        const n = @sizeOf(T);
        if (w.pos + n > w.buf.len) return error.Overflow;
        std.mem.writeInt(T, w.buf[w.pos..][0..n], v, .little);
        w.pos += n;
    }
    pub fn uvarint(w: *Writer, v0: u64) Error!void {
        var v = v0;
        while (true) {
            const b: u8 = @truncate(v & 0x7F);
            v >>= 7;
            if (v == 0) return w.int(u8, b);
            try w.int(u8, b | 0x80);
        }
    }
    pub fn svarint(w: *Writer, v: i64) Error!void {
        return w.uvarint(zigzag(v));
    }
    pub fn str(w: *Writer, s: []const u8, max: usize) Error!void {
        if (s.len > max) return error.TooLong;
        try w.uvarint(s.len);
        try w.bytes(s);
    }
    pub fn written(w: *const Writer) []const u8 {
        return w.buf[0..w.pos];
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn done(r: *const Reader) bool {
        return r.pos == r.buf.len;
    }
    pub fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (r.pos + n > r.buf.len) return error.Truncated;
        const s = r.buf[r.pos..][0..n];
        r.pos += n;
        return s;
    }
    pub fn int(r: *Reader, comptime T: type) Error!T {
        const n = @sizeOf(T);
        const s = try r.bytes(n);
        return std.mem.readInt(T, s[0..n], .little);
    }
    pub fn uvarint(r: *Reader) Error!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try r.int(u8);
            if (shift == 63 and b > 1) return error.BadMessage;
            v |= @as(u64, b & 0x7F) << @intCast(shift);
            if (b & 0x80 == 0) return v;
            shift += 7;
            if (shift > 63) return error.BadMessage;
        }
    }
    pub fn svarint(r: *Reader) Error!i64 {
        return unzigzag(try r.uvarint());
    }
    pub fn str(r: *Reader, max: usize) Error![]const u8 {
        const n = try r.uvarint();
        if (n > max) return error.TooLong;
        return r.bytes(@intCast(n));
    }
};

pub inline fn zigzag(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63));
}
pub inline fn unzigzag(u: u64) i64 {
    return @as(i64, @bitCast(u >> 1)) ^ -@as(i64, @bitCast(u & 1));
}

// ---------------------------------------------------------------------------
// Reliable stream framing (WebTransport): uvarint body length, then body.
// The body starts with the `Msg` byte. On WebSocket there is no length
// prefix; the WebSocket message boundary frames it (see `WsChannel`).

pub fn writeStreamFrame(w: *Writer, body: []const u8) Error!void {
    if (body.len > max_stream_message) return error.TooLong;
    try w.uvarint(body.len);
    try w.bytes(body);
}

/// Returns the next complete body and how many bytes it consumed, or null if
/// `buf` does not yet hold a whole frame.
pub fn readStreamFrame(buf: []const u8) Error!?struct { body: []const u8, used: usize } {
    var r: Reader = .{ .buf = buf };
    const n = r.uvarint() catch |e| switch (e) {
        error.Truncated => return null,
        else => return e,
    };
    if (n > max_stream_message) return error.TooLong;
    if (r.pos + n > buf.len) return null;
    return .{ .body = buf[r.pos..][0..@intCast(n)], .used = r.pos + @as(usize, @intCast(n)) };
}

// ---------------------------------------------------------------------------
// Handshake

pub const Hello = struct {
    protocol: u16 = protocol_version,
    abi: u16 = abi.abi_version,
    layout_hash: u64,
    /// SHA-256 of the `.gmp` file bytes.
    map_hash: [32]u8,
    /// All zero for a new join; the Welcome token to resume within 10 s.
    resume_token: [16]u8 = @splat(0),
    transport: Transport,
    /// 1..max_local_players names; one player slot is requested per name.
    names: []const []const u8,

    pub fn encode(m: Hello, w: *Writer) Error!void {
        if (m.names.len == 0 or m.names.len > max_local_players) return error.BadMessage;
        try w.int(u8, @intFromEnum(Msg.hello));
        try w.int(u32, magic);
        try w.int(u16, m.protocol);
        try w.int(u16, m.abi);
        try w.int(u64, m.layout_hash);
        try w.bytes(&m.map_hash);
        try w.bytes(&m.resume_token);
        try w.int(u8, @intFromEnum(m.transport));
        try w.int(u8, @intCast(m.names.len));
        for (m.names) |n| try w.str(n, max_name_len);
    }

    /// `names_out` receives slices into `r.buf`.
    pub fn decode(r: *Reader, names_out: *[max_local_players][]const u8) Error!Hello {
        if (try r.int(u8) != @intFromEnum(Msg.hello)) return error.BadMessage;
        if (try r.int(u32) != magic) return error.BadMessage;
        var m: Hello = undefined;
        m.protocol = try r.int(u16);
        m.abi = try r.int(u16);
        m.layout_hash = try r.int(u64);
        m.map_hash = (try r.bytes(32))[0..32].*;
        m.resume_token = (try r.bytes(16))[0..16].*;
        m.transport = @enumFromInt(try r.int(u8));
        const n = try r.int(u8);
        if (n == 0 or n > max_local_players) return error.BadMessage;
        for (0..n) |i| names_out[i] = try r.str(max_name_len);
        m.names = names_out[0..n];
        return m;
    }
};

pub const Welcome = struct {
    protocol: u16 = protocol_version,
    client_id: u32,
    resume_token: [16]u8,
    server_tick: u32,
    tick_hz: u8 = abi.tick_hz,
    snapshot_hz: u8 = 20,
    /// Server input buffer target, in ticks. Clients steer their clock so
    /// the reported `slack` stays near this.
    input_buffer_ticks: u8 = 2,
    /// Frames per player per input datagram the server expects (8).
    redundancy: u8 = max_redundancy,
    max_players: u16,
    config_name: []const u8,
    /// Player slots granted, in the order of Hello.names.
    slots: []const u8,

    pub fn encode(m: Welcome, w: *Writer) Error!void {
        if (m.slots.len == 0 or m.slots.len > max_local_players) return error.BadMessage;
        try w.int(u8, @intFromEnum(Msg.welcome));
        try w.int(u16, m.protocol);
        try w.int(u32, m.client_id);
        try w.bytes(&m.resume_token);
        try w.int(u32, m.server_tick);
        try w.int(u8, m.tick_hz);
        try w.int(u8, m.snapshot_hz);
        try w.int(u8, m.input_buffer_ticks);
        try w.int(u8, m.redundancy);
        try w.int(u16, m.max_players);
        try w.str(m.config_name, max_name_len);
        try w.int(u8, @intCast(m.slots.len));
        try w.bytes(m.slots);
    }

    pub fn decode(r: *Reader) Error!Welcome {
        if (try r.int(u8) != @intFromEnum(Msg.welcome)) return error.BadMessage;
        var m: Welcome = undefined;
        m.protocol = try r.int(u16);
        m.client_id = try r.int(u32);
        m.resume_token = (try r.bytes(16))[0..16].*;
        m.server_tick = try r.int(u32);
        m.tick_hz = try r.int(u8);
        m.snapshot_hz = try r.int(u8);
        m.input_buffer_ticks = try r.int(u8);
        m.redundancy = try r.int(u8);
        m.max_players = try r.int(u16);
        m.config_name = try r.str(max_name_len);
        const n = try r.int(u8);
        if (n == 0 or n > max_local_players) return error.BadMessage;
        m.slots = try r.bytes(n);
        return m;
    }
};

pub const Reject = struct {
    code: RejectCode,
    /// Human-readable, shown to the player as is.
    message: []const u8,

    pub fn encode(m: Reject, w: *Writer) Error!void {
        try w.int(u8, @intFromEnum(Msg.reject));
        try w.int(u8, @intFromEnum(m.code));
        try w.str(m.message, max_chat_len);
    }
    pub fn decode(r: *Reader) Error!Reject {
        if (try r.int(u8) != @intFromEnum(Msg.reject)) return error.BadMessage;
        return .{ .code = @enumFromInt(try r.int(u8)), .message = try r.str(max_chat_len) };
    }
};

// ---------------------------------------------------------------------------
// Input datagram (client to server)

pub const InputHeader = struct {
    /// Newest snapshot seq received (meaningful only if ack_bits != 0).
    ack_seq: u16,
    /// Bit i set = snapshot (ack_seq - i) received. Includes baselines.
    ack_bits: u32,
    /// Client clock, ms mod 65536. Echoed in snapshots for RTT.
    send_time: u16,
    players: u8,
};

pub const InputPlayer = struct {
    slot: u8,
    /// Tick of the last frame in `frames`. Frames are oldest first, for
    /// ticks newest_tick - frames.len + 1 ..= newest_tick.
    newest_tick: u32,
    frames: []const input.Frame,
};

pub fn encodeInput(w: *Writer, h: InputHeader, players: []const InputPlayer) Error!void {
    if (players.len == 0 or players.len > max_local_players or players.len != h.players) return error.BadMessage;
    try w.int(u8, @intFromEnum(Msg.input));
    try w.int(u16, h.ack_seq);
    try w.int(u32, h.ack_bits);
    try w.int(u16, h.send_time);
    try w.int(u8, h.players);
    for (players) |p| {
        if (p.frames.len == 0 or p.frames.len > max_redundancy) return error.BadMessage;
        try w.int(u8, p.slot);
        try w.int(u32, p.newest_tick);
        try w.int(u8, @intCast(p.frames.len));
        for (p.frames) |f| {
            var b: [8]u8 = undefined;
            f.encode(&b);
            try w.bytes(&b);
        }
    }
}

/// Decodes into caller storage. A frame whose `seq` does not match its
/// position is a protocol error.
pub fn decodeInput(
    r: *Reader,
    players_out: *[max_local_players]InputPlayer,
    frames_out: *[max_local_players][max_redundancy]input.Frame,
) Error!struct { header: InputHeader, players: []InputPlayer } {
    if (try r.int(u8) != @intFromEnum(Msg.input)) return error.BadMessage;
    const h: InputHeader = .{
        .ack_seq = try r.int(u16),
        .ack_bits = try r.int(u32),
        .send_time = try r.int(u16),
        .players = try r.int(u8),
    };
    if (h.players == 0 or h.players > max_local_players) return error.BadMessage;
    for (0..h.players) |i| {
        const slot = try r.int(u8);
        const newest = try r.int(u32);
        const n = try r.int(u8);
        if (n == 0 or n > max_redundancy) return error.BadMessage;
        for (0..n) |k| {
            const f = input.Frame.decode((try r.bytes(8))[0..8]);
            const t = newest -% @as(u32, @intCast(n - 1 - k));
            if (f.seq != input.seqOf(t)) return error.BadMessage;
            frames_out[i][k] = f;
        }
        players_out[i] = .{ .slot = slot, .newest_tick = newest, .frames = frames_out[i][0..n] };
    }
    if (!r.done()) return error.BadMessage;
    return .{ .header = h, .players = players_out[0..h.players] };
}

// ---------------------------------------------------------------------------
// Snapshot datagram (server to client) and Baseline stream message

pub const SnapshotPlayer = struct {
    slot: u8,
    /// Newest tick T such that the server holds this player's frames for
    /// every tick up to T. The client stops resending frames <= T.
    input_ack: u32,
    /// Minimum input arrival slack over the last second, in quarter ticks:
    /// how early frames arrived relative to the tick that consumed them.
    /// Negative = late (a frame was repeated). Clamped to -128..127.
    slack_q: i8,
};

pub const SnapshotHeader = struct {
    seq: u16,
    /// The state after `tick` steps (the value I1 `tick()` returns).
    tick: u32,
    /// Latest Input.send_time received from this client, and the ms the
    /// server held it before sending this. RTT = now - echo_time - hold_ms.
    echo_time: u16,
    hold_ms: u16,
    players: []const SnapshotPlayer,

    pub fn encode(h: SnapshotHeader, w: *Writer, as_baseline: bool) Error!void {
        if (h.players.len > max_local_players) return error.BadMessage;
        try w.int(u8, @intFromEnum(if (as_baseline) Msg.baseline else Msg.snapshot));
        try w.int(u16, h.seq);
        try w.int(u32, h.tick);
        try w.int(u16, h.echo_time);
        try w.int(u16, h.hold_ms);
        try w.int(u8, @intCast(h.players.len));
        for (h.players) |p| {
            try w.int(u8, p.slot);
            try w.int(u32, p.input_ack);
            try w.int(i8, p.slack_q);
        }
    }

    pub fn decode(r: *Reader, players_out: *[max_local_players]SnapshotPlayer) Error!struct { header: SnapshotHeader, baseline: bool } {
        const t = try r.int(u8);
        const baseline = switch (t) {
            @intFromEnum(Msg.snapshot) => false,
            @intFromEnum(Msg.baseline) => true,
            else => return error.BadMessage,
        };
        var h: SnapshotHeader = undefined;
        h.seq = try r.int(u16);
        h.tick = try r.int(u32);
        h.echo_time = try r.int(u16);
        h.hold_ms = try r.int(u16);
        const n = try r.int(u8);
        if (n > max_local_players) return error.BadMessage;
        for (0..n) |i| players_out[i] = .{ .slot = try r.int(u8), .input_ack = try r.int(u32), .slack_q = try r.int(i8) };
        h.players = players_out[0..n];
        return .{ .header = h, .baseline = baseline };
    }
};

/// Record op, low 2 bits of the op byte. The high 6 bits are base_age
/// (update only; 1..63 = this seq minus the base snapshot's seq).
pub const RecordOp = enum(u2) { update = 0, create = 1, remove = 2, _ };

pub const RecordHeader = struct {
    handle: u16,
    op: RecordOp,
    base_age: u6 = 0,
    /// create only.
    generation: u16 = 0,
    /// create/update: bit i = i-th replicated component of the kind, in
    /// ascending ComponentId order. Player rows have one component (bit 0).
    mask: u32 = 0,
};

/// Records are written in strictly ascending handle order. `prev` is the
/// previous record's handle, or null for the first.
pub fn encodeRecordHeader(w: *Writer, prev: ?u16, h: RecordHeader) Error!void {
    const base: u32 = if (prev) |p| @as(u32, p) + 1 else 0;
    if (h.handle < base) return error.BadMessage;
    try w.uvarint(h.handle - base);
    switch (h.op) {
        .update => if (h.base_age == 0) return error.BadMessage,
        .create, .remove => if (h.base_age != 0) return error.BadMessage,
        _ => return error.BadMessage,
    }
    try w.int(u8, @as(u8, @intFromEnum(h.op)) | (@as(u8, h.base_age) << 2));
    if (h.op == .create) try w.int(u16, h.generation);
    if (h.op != .remove) try w.uvarint(h.mask);
}

pub fn decodeRecordHeader(r: *Reader, prev: ?u16) Error!RecordHeader {
    const base: u64 = if (prev) |p| @as(u64, p) + 1 else 0;
    const handle = base + try r.uvarint();
    if (handle > 0xFFFF) return error.BadMessage;
    const ob = try r.int(u8);
    var h: RecordHeader = .{ .handle = @intCast(handle), .op = @enumFromInt(@as(u2, @truncate(ob))), .base_age = @truncate(ob >> 2) };
    switch (h.op) {
        .update => if (h.base_age == 0) return error.BadMessage,
        .create, .remove => if (h.base_age != 0) return error.BadMessage,
        _ => return error.BadMessage,
    }
    if (h.op == .create) h.generation = try r.int(u16);
    if (h.op != .remove) {
        const m = try r.uvarint();
        if (m > 0xFFFF_FFFF) return error.BadMessage;
        h.mask = @intCast(m);
    }
    return h;
}

// ---------------------------------------------------------------------------
// Component delta codec, generated from the component type.
//
// Every integer field (nested extern structs flattened, depth first, in
// declaration order; fields whose name starts with '_' skipped) is sent as
// svarint(signed(new -% base)) at the field's own width. `base` is all zero
// for a create. Values are exact: no quantisation, so a client that loads
// replicated state predicts from the same bits the server has.

pub fn encodeComponent(comptime T: type, w: *Writer, base: *const T, val: *const T) Error!void {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (name[0] == '_') continue;
        const FT = @FieldType(T, name);
        switch (@typeInfo(FT)) {
            .@"struct" => try encodeComponent(FT, w, &@field(base, name), &@field(val, name)),
            .int => |info| {
                const U = @Int(.unsigned, info.bits);
                const S = @Int(.signed, info.bits);
                const d: S = @bitCast(@as(U, @bitCast(@field(val, name))) -% @as(U, @bitCast(@field(base, name))));
                try w.svarint(d);
            },
            .@"enum" => |e| {
                const info = @typeInfo(e.tag_type).int;
                const U = @Int(.unsigned, info.bits);
                const S = @Int(.signed, info.bits);
                const nv: U = @bitCast(@intFromEnum(@field(val, name)));
                const bv: U = @bitCast(@intFromEnum(@field(base, name)));
                try w.svarint(@as(S, @bitCast(nv -% bv)));
            },
            else => @compileError("I3 codec: unsupported field " ++ name ++ " in " ++ @typeName(T)),
        }
    }
}

pub fn decodeComponent(comptime T: type, r: *Reader, base: *const T, out: *T) Error!void {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const FT = @FieldType(T, name);
        if (name[0] == '_') {
            @field(out, name) = std.mem.zeroes(FT);
            continue;
        }
        switch (@typeInfo(FT)) {
            .@"struct" => try decodeComponent(FT, r, &@field(base, name), &@field(out, name)),
            .int => |info| {
                const U = @Int(.unsigned, info.bits);
                const S = @Int(.signed, info.bits);
                const d = try r.svarint();
                if (d < std.math.minInt(S) or d > std.math.maxInt(S)) return error.BadMessage;
                const sum: U = @as(U, @bitCast(@field(base, name))) +% @as(U, @bitCast(@as(S, @intCast(d))));
                @field(out, name) = @bitCast(sum);
            },
            .@"enum" => |e| {
                const info = @typeInfo(e.tag_type).int;
                const U = @Int(.unsigned, info.bits);
                const S = @Int(.signed, info.bits);
                const d = try r.svarint();
                if (d < std.math.minInt(S) or d > std.math.maxInt(S)) return error.BadMessage;
                const bv: U = @bitCast(@intFromEnum(@field(base, name)));
                @field(out, name) = @enumFromInt(@as(e.tag_type, @bitCast(bv +% @as(U, @bitCast(@as(S, @intCast(d)))))));
            },
            else => @compileError("I3 codec: unsupported field " ++ name ++ " in " ++ @typeName(T)),
        }
    }
}

// ---------------------------------------------------------------------------
// Small reliable messages

pub const Chat = struct {
    /// chat: sender's own slot. chat_from: the slot that said it.
    slot: u8,
    text: []const u8,

    pub fn encode(m: Chat, w: *Writer, from_server: bool) Error!void {
        try w.int(u8, @intFromEnum(if (from_server) Msg.chat_from else Msg.chat));
        try w.int(u8, m.slot);
        try w.str(m.text, max_chat_len);
    }
    pub fn decode(r: *Reader) Error!Chat {
        const t = try r.int(u8);
        if (t != @intFromEnum(Msg.chat) and t != @intFromEnum(Msg.chat_from)) return error.BadMessage;
        return .{ .slot = try r.int(u8), .text = try r.str(max_chat_len) };
    }
};

pub const Event = struct {
    tick: u32,
    kind: EventKind,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    x: abi.Fx = 0,
    y: abi.Fx = 0,
    z: abi.Fx = 0,

    pub fn encode(m: Event, w: *Writer) Error!void {
        try w.int(u8, @intFromEnum(Msg.event));
        try w.int(u32, m.tick);
        try w.int(u8, @intFromEnum(m.kind));
        try w.int(u8, m.a);
        try w.int(u8, m.b);
        try w.int(u8, m.c);
        try w.svarint(m.x);
        try w.svarint(m.y);
        try w.svarint(m.z);
    }
    pub fn decode(r: *Reader) Error!Event {
        if (try r.int(u8) != @intFromEnum(Msg.event)) return error.BadMessage;
        var m: Event = .{ .tick = try r.int(u32), .kind = @enumFromInt(try r.int(u8)) };
        m.a = try r.int(u8);
        m.b = try r.int(u8);
        m.c = try r.int(u8);
        inline for (.{ "x", "y", "z" }) |f| {
            const v = try r.svarint();
            if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return error.BadMessage;
            @field(m, f) = @intCast(v);
        }
        return m;
    }
};

pub const PlayerInfo = struct {
    pub const flag_present: u8 = 1;
    pub const flag_bot: u8 = 2;
    slot: u8,
    flags: u8,
    name: []const u8,

    pub fn encode(m: PlayerInfo, w: *Writer) Error!void {
        try w.int(u8, @intFromEnum(Msg.player_info));
        try w.int(u8, m.slot);
        try w.int(u8, m.flags);
        try w.str(m.name, max_name_len);
    }
    pub fn decode(r: *Reader) Error!PlayerInfo {
        if (try r.int(u8) != @intFromEnum(Msg.player_info)) return error.BadMessage;
        return .{ .slot = try r.int(u8), .flags = try r.int(u8), .name = try r.str(max_name_len) };
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "varints" {
    var buf: [64]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    const vals = [_]i64{ 0, -1, 1, 63, -64, 64, 300, -300, std.math.maxInt(i32), std.math.minInt(i32), std.math.minInt(i64) };
    for (vals) |v| try w.svarint(v);
    var r: Reader = .{ .buf = w.written() };
    for (vals) |v| try testing.expectEqual(v, try r.svarint());
    try testing.expect(r.done());
}

test "component delta round trip" {
    var buf: [128]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    const base: abi.Transform = .{ .x = 100 * abi.fx_one, .y = 3, .z = abi.fx_one, .heading = 65000 };
    const val: abi.Transform = .{ .x = 100 * abi.fx_one + 1234, .y = -7, .z = abi.fx_one, .heading = 200 };
    try encodeComponent(abi.Transform, &w, &base, &val);
    try testing.expect(w.pos <= 8);
    var r: Reader = .{ .buf = w.written() };
    var out: abi.Transform = undefined;
    try decodeComponent(abi.Transform, &r, &base, &out);
    try testing.expectEqual(val, out);
}
