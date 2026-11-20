//! Render-list building: turns a sim state (I1 `stateBytes()` plus the
//! `views()` table) into a flat array of sprite instances the WebGL2
//! renderer draws in one instanced call.
//!
//! The builder reads only through `ColumnDesc`s, so it works the same on a
//! live sim, a client's blended display state (workstream C writes display
//! transforms into a scratch copy of the state) and a recorded buffer.
//!
//! What it reads per kind: `slot`, `generation`, `len`, `Transform`, and
//! when present `Riding` (peds in a vehicle are not drawn), `Velocity` (for
//! the camera) and `Appearance` (below).
//!
//! Appearance is I1 component 12. It is read if a sim lists it; without it
//! every entity gets its kind's first sprite. Sprite numbers
//! in it are relative to the kind's sprite group; the renderer adds the
//! group base from the style. Mapping a car model to its sprite needs the
//! style's car info, which waits for the clean-room notes.

const std = @import("std");
const abi = @import("interfaces").abi;

pub const appearance_component: u16 = @intFromEnum(abi.ComponentId.appearance);

/// I1 component 12 (accepted 2026-11-20): what to draw for an entity.
pub const Appearance = abi.Appearance;

pub const Instance = extern struct {
    /// Blocks, I1 axes (x east, y south, z up).
    x: f32,
    y: f32,
    z: f32,
    /// Radians, I1 convention: 0 along +x, growing toward +y.
    angle: f32,
    /// Absolute sprite number in the style.
    sprite: u16,
    /// Virtual palette, or `own_palette` for the sprite's own.
    palette: u16,
    kind: u8,
    flags: u8,
    _pad: u16 = 0,

    pub const own_palette: u16 = 0xFFFF;
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 24);
    std.debug.assert(@sizeOf(Appearance) == 4);
}

/// The entity kinds the renderer draws, in `abi.Kind` order.
pub const drawn_kinds = 5;

pub const KindColumns = struct {
    slot: ?abi.ColumnDesc = null,
    generation: ?abi.ColumnDesc = null,
    len: ?abi.ColumnDesc = null,
    transform: ?abi.ColumnDesc = null,
    velocity: ?abi.ColumnDesc = null,
    riding: ?abi.ColumnDesc = null,
    appearance: ?abi.ColumnDesc = null,
};

pub const Layout = struct {
    kinds: [drawn_kinds]KindColumns = @splat(.{}),
    player_rows: ?abi.ColumnDesc = null,
    tick: ?abi.ColumnDesc = null,

    pub fn init(views: []const abi.ColumnDesc) Layout {
        var l: Layout = .{};
        const S = abi.ColumnDesc.Special;
        for (views) |v| {
            switch (v.component) {
                S.player_rows => l.player_rows = v,
                S.tick => l.tick = v,
                else => {
                    if (v.kind >= drawn_kinds) continue;
                    const k = &l.kinds[v.kind];
                    switch (v.component) {
                        S.slot => k.slot = v,
                        S.generation => k.generation = v,
                        S.len => k.len = v,
                        @intFromEnum(abi.ComponentId.transform) => k.transform = v,
                        @intFromEnum(abi.ComponentId.velocity) => k.velocity = v,
                        @intFromEnum(abi.ComponentId.riding) => k.riding = v,
                        appearance_component => k.appearance = v,
                        else => {},
                    }
                },
            }
        }
        return l;
    }
};

/// Per-kind sprite group bases and remap palette bases from the style.
pub const Bases = struct {
    sprite: [drawn_kinds]u32 = @splat(0),
    remap_palette: [drawn_kinds]u32 = @splat(0),
    /// Sprites past this are clamped to 0 (a sim and style mismatch).
    sprite_count: u32 = 0xFFFF,
};

fn at(comptime T: type, state: []const u8, c: abi.ColumnDesc, i: usize) ?T {
    const off = @as(usize, c.offset) + i * c.stride;
    if (off + @sizeOf(T) > state.len) return null;
    var v: T = undefined;
    @memcpy(std.mem.asBytes(&v), state[off..][0..@sizeOf(T)]);
    return v;
}

fn count(state: []const u8, k: KindColumns) usize {
    const slot = k.slot orelse return 0;
    var n: usize = slot.count;
    if (k.len) |l| n = @min(n, at(u32, state, l, 0) orelse 0);
    return n;
}

fn alive(state: []const u8, k: KindColumns, i: usize) bool {
    return (at(u8, state, k.slot.?, i) orelse 0) == abi.Slot.alive;
}

fn generation(state: []const u8, k: KindColumns, i: usize) u16 {
    const g = k.generation orelse return 0;
    return at(u16, state, g, i) orelse 0;
}

const fx_to_f: f32 = 1.0 / @as(f32, abi.fx_one);
const angle_to_rad: f32 = std.math.tau / 65536.0;

fn lerpAngle(a: abi.Angle, b: abi.Angle, t: f32) f32 {
    const d: i16 = @bitCast(b -% a);
    return (@as(f32, @floatFromInt(a)) + @as(f32, @floatFromInt(d)) * t) * angle_to_rad;
}

/// Writes instances for every alive entity of kinds 0-4 into `out` and
/// returns how many were written. `prev`, if given, must have the same
/// layout; entities alive there with the same generation are interpolated
/// by `alpha` (0 = prev, 1 = cur).
pub fn build(lay: *const Layout, prev: ?[]const u8, cur: []const u8, alpha: f32, bases: Bases, out: []Instance) usize {
    var n: usize = 0;
    for (lay.kinds, 0..) |k, kind| {
        const tcol = k.transform orelse continue;
        const len = count(cur, k);
        for (0..len) |i| {
            if (n == out.len) return n;
            if (!alive(cur, k, i)) continue;
            if (k.riding) |rc| {
                const r = at(abi.Riding, cur, rc, i) orelse continue;
                if (!r.vehicle.isNone()) continue;
            }
            const t = at(abi.Transform, cur, tcol, i) orelse continue;
            var x = @as(f32, @floatFromInt(t.x)) * fx_to_f;
            var y = @as(f32, @floatFromInt(t.y)) * fx_to_f;
            var z = @as(f32, @floatFromInt(t.z)) * fx_to_f;
            var angle = @as(f32, @floatFromInt(t.heading)) * angle_to_rad;
            if (prev) |p| {
                if (alive(p, k, i) and generation(p, k, i) == generation(cur, k, i)) {
                    if (at(abi.Transform, p, tcol, i)) |pt| {
                        const pf = struct {
                            fn f(a: abi.Fx, b: abi.Fx, s: f32) f32 {
                                return (@as(f32, @floatFromInt(a)) + @as(f32, @floatFromInt(b -% a)) * s) * fx_to_f;
                            }
                        }.f;
                        x = pf(pt.x, t.x, alpha);
                        y = pf(pt.y, t.y, alpha);
                        z = pf(pt.z, t.z, alpha);
                        angle = lerpAngle(pt.heading, t.heading, alpha);
                    }
                }
            }
            var look: Appearance = .{ .sprite = 0, .remap = Appearance.no_remap };
            if (k.appearance) |ac| look = at(Appearance, cur, ac, i) orelse look;
            var sprite = bases.sprite[kind] + look.sprite;
            if (sprite >= bases.sprite_count) sprite = 0;
            out[n] = .{
                .x = x,
                .y = y,
                .z = z,
                .angle = angle,
                .sprite = @intCast(sprite),
                .palette = if (look.remap == Appearance.no_remap) Instance.own_palette else @intCast(bases.remap_palette[kind] + look.remap),
                .kind = @intCast(kind),
                .flags = 0,
            };
            n += 1;
        }
    }
    return n;
}

/// What the camera follows: a player's car if they are in one, else their
/// ped. Blocks and blocks per tick.
pub const Target = extern struct {
    x: f32,
    y: f32,
    z: f32,
    angle: f32,
    vx: f32,
    vy: f32,
    found: u32,
    _pad: u32 = 0,
};

pub fn target(lay: *const Layout, state: []const u8, slot: u32) Target {
    const none: Target = .{ .x = 0, .y = 0, .z = 0, .angle = 0, .vx = 0, .vy = 0, .found = 0 };
    const rows = lay.player_rows orelse return none;
    if (slot >= rows.count) return none;
    const row = at(abi.PlayerRow, state, rows, slot) orelse return none;
    const id = if (!row.car.isNone()) row.car else row.ped;
    if (id.isNone() or id.kind() >= drawn_kinds) return none;
    const k = lay.kinds[id.kind()];
    const tcol = k.transform orelse return none;
    const i = id.index();
    if (k.slot == null or i >= k.slot.?.count or !alive(state, k, i)) return none;
    const t = at(abi.Transform, state, tcol, i) orelse return none;
    var v: abi.Velocity = std.mem.zeroes(abi.Velocity);
    if (k.velocity) |vc| v = at(abi.Velocity, state, vc, i) orelse v;
    return .{
        .x = @as(f32, @floatFromInt(t.x)) * fx_to_f,
        .y = @as(f32, @floatFromInt(t.y)) * fx_to_f,
        .z = @as(f32, @floatFromInt(t.z)) * fx_to_f,
        .angle = @as(f32, @floatFromInt(t.heading)) * angle_to_rad,
        .vx = @as(f32, @floatFromInt(v.vx)) * fx_to_f,
        .vy = @as(f32, @floatFromInt(v.vy)) * fx_to_f,
        .found = 1,
    };
}

const testing = std.testing;

test "render list from the I1 stub" {
    const Stub = abi.Stub;
    var grid: abi.Grid = undefined;
    var s: Stub = undefined;
    s.init(&grid, .{ .seed = 1, .mode = .authoritative });
    const input = @import("interfaces").input;
    var frames: [16]input.Frame = @splat(input.Frame.neutral(0));
    s.step(&frames, &.{ .{ .op = .join, .slot = 0, .arg = 0 }, .{ .op = .join, .slot = 3, .arg = 0 } });
    var prev: [Stub.state_size]u8 = undefined;
    _ = s.save(&prev);
    frames[0].throttle = 127;
    s.step(&frames, &.{});

    const lay = Layout.init(Stub.views());
    var bases: Bases = .{};
    bases.sprite[@intFromEnum(abi.Kind.ped)] = 100;
    var out: [8]Instance = undefined;
    const n = build(&lay, &prev, s.stateBytes(), 0.5, bases, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, 100), out[0].sprite);
    try testing.expectEqual(@as(u8, 1), out[0].kind);
    // Halfway between the two ticks.
    const moved = @as(f32, @floatFromInt(s.state.ped.transform[0].x)) * fx_to_f - 128.0;
    try testing.expectApproxEqAbs(@as(f32, 128.0) + moved / 2, out[0].x, 1e-3);
    try testing.expectEqual(@as(f32, 128.0), out[1].x);

    const t = target(&lay, s.stateBytes(), 0);
    try testing.expectEqual(@as(u32, 1), t.found);
    try testing.expect(t.vx > 0);
    try testing.expectEqual(@as(u32, 0), target(&lay, s.stateBytes(), 1).found);
}
