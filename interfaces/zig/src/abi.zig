//! I1. Sim ABI: the contract between `sim/` and its two hosts
//! (`client/wasm/` and `server/`), plus the read-only entity views the
//! renderer, netcode and tools read.
//!
//! Frozen interface. Spec: interfaces/I1-sim-abi.md. This file holds the
//! types every party shares and `checkSim`, a comptime conformance check that
//! `sim/` must pass:  `comptime { abi.checkSim(Sim(config_16)); }`.

const std = @import("std");
const input = @import("input.zig");

pub const abi_version: u16 = 1;

// ---------------------------------------------------------------------------
// Numbers and units

/// Signed 16.16 fixed point in an i32. One map block is 1.0 (`fx_one`).
/// Positions, velocities (blocks per tick), radii, heights.
pub const Fx = i32;
pub const fx_frac_bits = 16;
pub const fx_one: Fx = 1 << fx_frac_bits;

/// Binary angle: 65536 = one full turn, wraps.
/// 0 points along +x (east). Angles grow toward +y (south), which is
/// clockwise on screen because y grows downward (S1 map convention).
/// The unit direction for angle a is (cos a, sin a).
pub const Angle = u16;
pub const angle_quarter: Angle = 16384;

/// Ticks are counted from 0 at `init`. 30 per second.
pub const Tick = u32;
pub const tick_hz = 30;

// ---------------------------------------------------------------------------
// Entities

/// index (bits 0-11) | kind (bits 12-15) | generation (bits 16-31).
/// Identical on server and clients: clients place replicated entities at the
/// server's (kind, index) slot with the server's generation.
pub const EntityId = extern struct {
    raw: u32,

    pub const none: EntityId = .{ .raw = 0xFFFF_FFFF };

    pub inline fn make(k: Kind, idx: u32, generation: u16) EntityId {
        return .{ .raw = (idx & 0xFFF) | (@as(u32, @intFromEnum(k)) << 12) | (@as(u32, generation) << 16) };
    }
    /// kind and index together: what the wire calls the handle.
    pub inline fn handle(id: EntityId) u16 {
        return @truncate(id.raw);
    }
    pub inline fn index(id: EntityId) u32 {
        return id.raw & 0xFFF;
    }
    pub inline fn kind(id: EntityId) u4 {
        return @truncate(id.raw >> 12);
    }
    pub inline fn gen(id: EntityId) u16 {
        return @truncate(id.raw >> 16);
    }
    pub inline fn isNone(id: EntityId) bool {
        return id.raw == none.raw;
    }
};

/// Entity kinds (archetypes). The numbers are part of the ABI and of I3.
/// Append only; a retired number is never reused.
pub const Kind = enum(u4) {
    car = 0,
    ped = 1,
    projectile = 2,
    pickup = 3,
    map_object = 4,
    // 5..14 free for new kinds.
    /// Not an entity table: I3 uses handle kind 15 for player rows.
    player_row = 15,
    _,
};

pub const max_kind_capacity = 4096; // 12 index bits

/// Component ids. Used by views (`ColumnDesc`) and by I3 component masks.
/// The numbers are part of the ABI. Append only; never reuse a number.
pub const ComponentId = enum(u8) {
    transform = 1,
    velocity = 2,
    collider = 3,
    health = 4,
    controller = 5,
    vehicle = 6,
    pedestrian = 7,
    riding = 8,
    weapon = 9,
    projectile = 10,
    predicted = 11,
    _,
};

/// The components whose layout is frozen here because the renderer, the
/// netcode or the shell reads them. Other components are owned by `sim/` and
/// reach other parties only through generated codecs and `layout_hash`.
pub const Transform = extern struct {
    pub const id = ComponentId.transform;
    x: Fx,
    y: Fx,
    z: Fx,
    heading: Angle,
    _pad: u16 = 0,
};

pub const Velocity = extern struct {
    pub const id = ComponentId.velocity;
    vx: Fx,
    vy: Fx,
    vz: Fx,
    /// Angular velocity, binary angle units per tick.
    spin: i32,
};

pub const Health = extern struct {
    pub const id = ComponentId.health;
    hp: i32,
    last_hit_by: EntityId,
};

pub const Controller = extern struct {
    pub const id = ComponentId.controller;
    pub const no_player: u32 = 0xFFFF_FFFF;
    /// Player slot driving this entity, or `no_player` (AI).
    player: u32,
    prev_buttons: u32,
    /// The frame applied on the last step. Replicated so clients can
    /// dead-reckon remote players on their last known input (S3).
    in: input.Frame,
};

pub const Riding = extern struct {
    pub const id = ComponentId.riding;
    /// Vehicle this ped is in, or `EntityId.none`.
    vehicle: EntityId,
};

/// Which entities a client predicts. Written by the client host, never by
/// the sim. In `.predict` mode the sim steps only entities with `on != 0`;
/// the rest are frozen obstacles at their last replicated values.
/// The server ignores it.
pub const Predicted = extern struct {
    pub const id = ComponentId.predicted;
    on: u32,
};

/// One row per player slot, held in the saved state. I3 replicates it as
/// handle kind 15, index = slot.
pub const PlayerRow = extern struct {
    pub const flag_active: u32 = 1;
    pub const flag_connected: u32 = 2;
    ped: EntityId,
    car: EntityId,
    kills: i32,
    deaths: i32,
    score: i32,
    respawn_timer: u32,
    flags: u32,
    _pad: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Transform) == 16);
    std.debug.assert(@sizeOf(Velocity) == 16);
    std.debug.assert(@sizeOf(Health) == 8);
    std.debug.assert(@sizeOf(Controller) == 16);
    std.debug.assert(@sizeOf(Riding) == 4);
    std.debug.assert(@sizeOf(Predicted) == 4);
    std.debug.assert(@sizeOf(PlayerRow) == 32);
}

// ---------------------------------------------------------------------------
// Static map (outside the saved state)

pub const map_x = 256;
pub const map_y = 256;
pub const map_z = 8;

/// One collision cell, built from the `.gmp` by `formats/` and handed to
/// `init`. Bits:
///   0-2   shape: `Shape`
///   3-8   slope code, 0..63, as in the GTA2 block info (0 = none)
///   9-10  ground: `Ground` (traction, lane snapping)
///   11-14 road arrows on the lid: bit 11 +y, 12 -y, 13 +x, 14 -x
///   15    reserved, zero
pub const Cell = u16;

pub const Shape = enum(u3) { air = 0, solid = 1, slope = 2, partial = 3, water = 4, _ };
pub const Ground = enum(u2) { none = 0, road = 1, pavement = 2, field = 3 };

/// z-major: blocks[z][y][x]. x grows east, y grows south, z up. 1 MiB.
pub const Grid = extern struct {
    blocks: [map_z][map_y][map_x]Cell,
};

// ---------------------------------------------------------------------------
// Configuration

/// Capacities are configuration (comptime), not constants. A sim is built for
/// a named configuration; client and server must agree on it (I3 checks
/// `layout_hash`, which covers every capacity).
pub const Config = struct {
    name: []const u8,
    max_players: u16,
    car_capacity: u16,
    ped_capacity: u16,
    projectile_capacity: u16,
    pickup_capacity: u16 = 64,
    map_object_capacity: u16 = 256,
    /// Ambient traffic and peds share the entity budget with players.
    ambient_cars: u16 = 0,
    ambient_peds: u16 = 0,
};

pub const config_16: Config = .{
    .name = "dm16",
    .max_players = 16,
    .car_capacity = 64,
    .ped_capacity = 192,
    .projectile_capacity = 128,
    .ambient_cars = 24,
    .ambient_peds = 100,
};

pub const Mode = enum(u32) {
    /// Server, replay tools, golden test. Steps everything, spawns, despawns.
    authoritative = 0,
    /// Client. Steps only `Predicted` entities; spawns and despawns are
    /// reported as `Intent`s instead of applied.
    predict = 1,
};

pub const InitParams = extern struct {
    seed: u64,
    mode: Mode,
    _pad: u32 = 0,
};

// ---------------------------------------------------------------------------
// Per-tick inputs besides I2 frames

/// Session changes decided by the server host, applied at the start of the
/// tick before any system runs, in slice order. Recorded in replays with the
/// frames. Clients in `.predict` mode pass none.
pub const Command = extern struct {
    pub const Op = enum(u8) { none = 0, join = 1, leave = 2, _ };
    op: Op,
    slot: u8,
    _pad: u16 = 0,
    /// join: spawn hint (0 = sim chooses). leave: 0.
    arg: u32,
};

/// What the sim would have spawned or despawned in `.predict` mode. Cleared
/// at the start of each `step`. The client turns these into cosmetic
/// effects (muzzle flash, tracer, explosion); the authoritative entity
/// arrives in a snapshot.
pub const Intent = extern struct {
    pub const Op = enum(u8) { spawn = 1, despawn = 2, _ };
    op: Op,
    /// `Kind` number.
    kind: u8,
    _pad: u16 = 0,
    /// Entity that caused it (shooter, the dying entity).
    source: EntityId,
    x: Fx,
    y: Fx,
    z: Fx,
    heading: Angle,
    _pad2: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Command) == 8);
    std.debug.assert(@sizeOf(Intent) == 24);
    std.debug.assert(@sizeOf(InitParams) == 16);
}

// ---------------------------------------------------------------------------
// Views

/// Describes where one column (or slot/generation array) lives inside the
/// saved state, so any reader with the state bytes (Zig host, TS debug
/// overlay, recorded entity buffers for the renderer stub) can find it.
/// `offset` is from the start of the state; elements are `stride` bytes
/// apart; `count` is the kind's capacity.
pub const ColumnDesc = extern struct {
    pub const Special = struct {
        /// `component` values below 0x100 are `ComponentId`s.
        pub const slot: u16 = 0x100; // u8 per entity: 0 free, 1 alive, 2 spawning, 3 dying
        pub const generation: u16 = 0x101; // u16 per entity
        pub const len: u16 = 0x102; // one u32: high-water mark of used slots
        pub const player_rows: u16 = 0x103; // PlayerRow per slot (kind = player_row)
        pub const tick: u16 = 0x104; // one u32
    };
    kind: u8,
    _pad: u8 = 0,
    component: u16,
    offset: u32,
    stride: u32,
    count: u32,
};

pub const Slot = struct {
    pub const free: u8 = 0;
    pub const alive: u8 = 1;
    pub const spawning: u8 = 2;
    pub const dying: u8 = 3;
};

// ---------------------------------------------------------------------------
// Randomness

/// The only source of randomness in the sim: a keyed hash, not a stream.
/// Partial client worlds then draw the same numbers as the server for the
/// entities they hold, which a sequential generator cannot give.
/// `salt` names the purpose (a constant per call site).
pub fn rand(seed: u64, tick: Tick, entity: EntityId, salt: u32) u32 {
    var z: u64 = seed ^ (@as(u64, tick) << 32 | entity.raw) ^ (@as(u64, salt) *% 0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    z ^= z >> 31;
    return @truncate(z >> 16);
}

/// Hash of saved-state bytes. Wyhash with seed 0, as S2.
pub fn stateHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

// ---------------------------------------------------------------------------
// Layout hash

/// FNV-1a over the field names, offsets, sizes and type names of `T`,
/// recursively. `sim/` exports `layout_hash = layoutHash(State)` mixed with
/// `abi_version`; I3 refuses peers whose hash differs.
pub fn layoutHash(comptime T: type) u64 {
    @setEvalBranchQuota(1_000_000);
    comptime var h: u64 = 0xcbf29ce484222325;
    comptime {
        h = mixType(h, T);
        h = mixInt(h, abi_version);
    }
    return h;
}

fn mixBytes(h0: u64, bytes: []const u8) u64 {
    var h = h0;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn mixInt(h: u64, v: u64) u64 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    return mixBytes(h, &buf);
}

fn mixType(h0: u64, comptime T: type) u64 {
    var h = mixInt(h0, @sizeOf(T));
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.field_names, s.field_types) |name, FT| {
                h = mixBytes(h, name);
                h = mixInt(h, @offsetOf(T, name));
                h = mixType(h, FT);
            }
        },
        .array => |a| {
            h = mixInt(h, a.len);
            h = mixType(h, a.child);
        },
        .int => |i| {
            h = mixInt(h, i.bits);
            h = mixInt(h, @intFromEnum(i.signedness));
        },
        .@"enum" => |e| h = mixType(h, e.tag_type),
        else => @compileError("layoutHash: unsupported field type " ++ @typeName(T)),
    }
    return h;
}

// ---------------------------------------------------------------------------
// Conformance

/// Comptime check that a sim type implements I1. `sim/` calls this on every
/// configuration it builds; hosts may call it too.
pub fn checkSim(comptime S: type) void {
    const want = .{
        .{ "init", fn (*S, *const Grid, InitParams) void },
        .{ "step", fn (*S, []const input.Frame, []const Command) void },
        .{ "save", fn (*const S, []u8) usize },
        .{ "load", fn (*S, []const u8) error{BadSize}!void },
        .{ "hash", fn (*const S) u64 },
        .{ "tick", fn (*const S) Tick },
        .{ "setTick", fn (*S, Tick) void },
        .{ "stateBytes", fn (*const S) []const u8 },
        .{ "views", fn () []const ColumnDesc },
        .{ "intents", fn (*const S) []const Intent },
        .{ "playerRow", fn (*S, u32) *PlayerRow },
        .{ "replicaPut", fn (*S, EntityId) bool },
        .{ "replicaRemove", fn (*S, EntityId) void },
    };
    inline for (want) |w| {
        if (!@hasDecl(S, w[0])) @compileError("I1: sim is missing `" ++ w[0] ++ "`");
        if (@TypeOf(@field(S, w[0])) != w[1])
            @compileError("I1: `" ++ w[0] ++ "` has type " ++ @typeName(@TypeOf(@field(S, w[0]))) ++ ", want " ++ @typeName(w[1]));
    }
    if (!@hasDecl(S, "config") or @TypeOf(S.config) != Config) @compileError("I1: sim must declare `pub const config: abi.Config`");
    if (!@hasDecl(S, "state_size")) @compileError("I1: sim must declare `pub const state_size`");
    if (!@hasDecl(S, "layout_hash") or @TypeOf(S.layout_hash) != u64) @compileError("I1: sim must declare `pub const layout_hash: u64`");
}

// ---------------------------------------------------------------------------
// Tests: a minimal stub that conforms, used by workstreams B-E until sim/ lands.

pub const Stub = @import("stub.zig").Stub;

test "stub conforms" {
    comptime checkSim(Stub);
}

test "rand is keyed, not sequential" {
    const id = EntityId.make(.ped, 5, 1);
    try std.testing.expectEqual(rand(1, 10, id, 7), rand(1, 10, id, 7));
    try std.testing.expect(rand(1, 10, id, 7) != rand(1, 11, id, 7));
    try std.testing.expect(rand(1, 10, id, 7) != rand(1, 10, id, 8));
}

test "entity id packing" {
    const id = EntityId.make(.projectile, 4095, 0xBEEF);
    try std.testing.expectEqual(@as(u32, 4095), id.index());
    try std.testing.expectEqual(@as(u4, 2), id.kind());
    try std.testing.expectEqual(@as(u16, 0xBEEF), id.gen());
    try std.testing.expectEqual(@as(u16, 0x2FFF), id.handle());
}
