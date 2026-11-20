//! Stand-ins for the sim while workstream A is in progress:
//!
//!   - `Traffic`: a toy world that drives cars along the map's road arrows
//!     and walks peds on pavements. Its state is an extern struct described
//!     by an I1 `views()` table, so the renderer reads it exactly as it
//!     will read the real sim. It is not a sim: floats, no collisions, no
//!     handling. Player slot 0 rides car 0, which speeds up on straights
//!     and slows for turns so the camera's pull-back shows.
//!   - `Recording`: a recorded entity buffer (".grec"): the view table and
//!     one `stateBytes()` copy per tick. Any I1 sim, or this stub, can
//!     write one, and the renderer plays it back with interpolation.

const std = @import("std");
const abi = @import("interfaces").abi;
const list = @import("list.zig");
const formats = @import("formats");
const grid_mod = formats.grid;

pub fn Table(comptime cap: usize) type {
    return extern struct {
        len: u32,
        _pad: u32 = 0,
        gen: [cap]u16,
        slot: [cap]u8,
        transform: [cap]abi.Transform,
        velocity: [cap]abi.Velocity,
        riding: [cap]abi.Riding,
        appearance: [cap]list.Appearance,
    };
}

pub const car_cap = 64;
pub const ped_cap = 128;

pub const State = extern struct {
    tick: u32,
    _pad: u32 = 0,
    players: [16]abi.PlayerRow,
    car: Table(car_cap),
    ped: Table(ped_cap),
};

pub const state_size = @sizeOf(State);

fn tableViews(comptime T: type, comptime field: []const u8, kind: abi.Kind, cap: u32) [7]abi.ColumnDesc {
    const base = @offsetOf(State, field);
    const k: u8 = @intFromEnum(kind);
    const S = abi.ColumnDesc.Special;
    const C = abi.ComponentId;
    return .{
        .{ .kind = k, .component = S.len, .offset = base + @offsetOf(T, "len"), .stride = 4, .count = 1 },
        .{ .kind = k, .component = S.generation, .offset = base + @offsetOf(T, "gen"), .stride = 2, .count = cap },
        .{ .kind = k, .component = S.slot, .offset = base + @offsetOf(T, "slot"), .stride = 1, .count = cap },
        .{ .kind = k, .component = @intFromEnum(C.transform), .offset = base + @offsetOf(T, "transform"), .stride = 16, .count = cap },
        .{ .kind = k, .component = @intFromEnum(C.velocity), .offset = base + @offsetOf(T, "velocity"), .stride = 16, .count = cap },
        .{ .kind = k, .component = @intFromEnum(C.riding), .offset = base + @offsetOf(T, "riding"), .stride = 4, .count = cap },
        .{ .kind = k, .component = list.appearance_component, .offset = base + @offsetOf(T, "appearance"), .stride = 4, .count = cap },
    };
}

const view_table = blk: {
    const S = abi.ColumnDesc.Special;
    break :blk [_]abi.ColumnDesc{
        .{ .kind = 0, .component = S.tick, .offset = @offsetOf(State, "tick"), .stride = 4, .count = 1 },
        .{ .kind = @intFromEnum(abi.Kind.player_row), .component = S.player_rows, .offset = @offsetOf(State, "players"), .stride = @sizeOf(abi.PlayerRow), .count = 16 },
    } ++ tableViews(Table(car_cap), "car", .car, car_cap) ++ tableViews(Table(ped_cap), "ped", .ped, ped_cap);
};

pub fn views() []const abi.ColumnDesc {
    return &view_table;
}

const Dir = enum(u2) {
    pos_x,
    pos_y,
    neg_x,
    neg_y,
    fn dx(d: Dir) i32 {
        return switch (d) {
            .pos_x => 1,
            .neg_x => -1,
            else => 0,
        };
    }
    fn dy(d: Dir) i32 {
        return switch (d) {
            .pos_y => 1,
            .neg_y => -1,
            else => 0,
        };
    }
    fn angle(d: Dir) abi.Angle {
        return @as(abi.Angle, @intFromEnum(d)) *% abi.angle_quarter;
    }
    fn reverse(d: Dir) Dir {
        return @enumFromInt(@intFromEnum(d) +% 2);
    }
    fn arrowBit(d: Dir) abi.Cell {
        return switch (d) {
            .pos_x => grid_mod.arrow_pos_x,
            .neg_x => grid_mod.arrow_neg_x,
            .pos_y => grid_mod.arrow_pos_y,
            .neg_y => grid_mod.arrow_neg_y,
        };
    }
};

/// Movement scratch kept outside the recorded state.
const Mover = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    cz: i32 = 0,
    dir: Dir = .pos_x,
    speed: f32 = 0,
    max_speed: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    heading: f32 = 0,
};

pub const Traffic = struct {
    grid: *const abi.Grid,
    seed: u64,
    state: State,
    cars: [car_cap]Mover = @splat(.{}),
    peds: [ped_cap]Mover = @splat(.{}),
    n_cars: u32 = 0,
    n_peds: u32 = 0,

    fn cell(t: *const Traffic, x: i32, y: i32, z: i32) abi.Cell {
        if (x < 0 or y < 0 or z < 0 or x >= abi.map_x or y >= abi.map_y or z >= abi.map_z) return 0;
        return t.grid.blocks[@intCast(z)][@intCast(y)][@intCast(x)];
    }

    /// A walkable/drivable top surface: a non-air cell with open air above.
    fn surface(t: *const Traffic, x: i32, y: i32, z: i32) bool {
        const c = t.cell(x, y, z);
        if (grid_mod.cellShape(c) == .air) return false;
        return grid_mod.cellShape(t.cell(x, y, z + 1)) == .air;
    }

    fn isRoad(t: *const Traffic, x: i32, y: i32, z: i32) bool {
        return t.surface(x, y, z) and t.cell(x, y, z) & 0x7800 != 0;
    }

    fn isPavement(t: *const Traffic, x: i32, y: i32, z: i32) bool {
        return t.surface(x, y, z) and grid_mod.cellGround(t.cell(x, y, z)) == .pavement and
            grid_mod.cellShape(t.cell(x, y, z)) == .solid;
    }

    fn rand(t: *const Traffic, a: u32, b: u32) u32 {
        return abi.rand(t.seed, t.state.tick, .{ .raw = a }, b);
    }

    /// Lid height of a cell at its centre, in blocks above its base.
    fn lidHeight(t: *const Traffic, x: i32, y: i32, z: i32) f32 {
        const c = t.cell(x, y, z);
        if (grid_mod.cellShape(c) != .slope) return 1.0;
        const code = grid_mod.cellCode(c);
        const sh = formats.gmp.decodeShape(code);
        return switch (sh) {
            .ramp => |r| (@as(f32, @floatFromInt(r.low)) + @as(f32, @floatFromInt(r.high))) / 2.0 / @as(f32, @floatFromInt(r.denom)),
            else => 1.0,
        };
    }

    pub fn init(t: *Traffic, grid: *const abi.Grid, seed: u64, want_cars: u32, want_peds: u32) void {
        t.* = .{ .grid = grid, .seed = seed, .state = std.mem.zeroes(State) };
        for (&t.state.players) |*r| r.* = .{ .ped = .none, .car = .none, .kills = 0, .deaths = 0, .score = 0, .respawn_timer = 0, .flags = 0 };
        for (&t.state.car.riding) |*r| r.* = .{ .vehicle = .none };
        for (&t.state.ped.riding) |*r| r.* = .{ .vehicle = .none };

        // Sample spawn cells deterministically across the map.
        var tries: u32 = 0;
        while (t.n_cars < @min(want_cars, car_cap) and tries < 200_000) : (tries += 1) {
            const x: i32 = @intCast(t.rand(tries, 1) % abi.map_x);
            const y: i32 = @intCast(t.rand(tries, 2) % abi.map_y);
            var z: i32 = abi.map_z - 1;
            while (z >= 0) : (z -= 1) if (t.isRoad(x, y, z)) break;
            if (z < 0) continue;
            const c = t.cell(x, y, z);
            var dir: ?Dir = null;
            inline for (.{ Dir.pos_x, Dir.pos_y, Dir.neg_x, Dir.neg_y }) |d| if (c & d.arrowBit() != 0) {
                dir = d;
            };
            const m = &t.cars[t.n_cars];
            m.* = .{ .cx = x, .cy = y, .cz = z, .dir = dir.?, .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
            m.heading = @floatFromInt(dir.?.angle());
            m.max_speed = if (t.n_cars == 0) 0.4 else 0.1 + @as(f32, @floatFromInt(t.rand(tries, 3) % 100)) / 1000.0;
            m.speed = m.max_speed / 2;
            m.z = @as(f32, @floatFromInt(z)) + t.lidHeight(x, y, z);
            const i = t.n_cars;
            t.state.car.slot[i] = abi.Slot.alive;
            t.state.car.gen[i] = 1;
            t.state.car.appearance[i] = .{ .sprite = @intCast(t.rand(tries, 4) % 8), .remap = list.Appearance.no_remap };
            t.n_cars += 1;
        }
        t.state.car.len = t.n_cars;

        tries = 0;
        while (t.n_peds < @min(want_peds, ped_cap - 1) and tries < 200_000) : (tries += 1) {
            const x: i32 = @intCast(t.rand(tries, 11) % abi.map_x);
            const y: i32 = @intCast(t.rand(tries, 12) % abi.map_y);
            var z: i32 = abi.map_z - 1;
            while (z >= 0) : (z -= 1) if (t.isPavement(x, y, z)) break;
            if (z < 0) continue;
            const m = &t.peds[t.n_peds];
            const d: Dir = @enumFromInt(@as(u2, @truncate(t.rand(tries, 13))));
            m.* = .{ .cx = x, .cy = y, .cz = z, .dir = d, .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5, .z = @as(f32, @floatFromInt(z)) + 1.0 };
            m.heading = @floatFromInt(d.angle());
            m.max_speed = 0.03 + @as(f32, @floatFromInt(t.rand(tries, 14) % 20)) / 1000.0;
            m.speed = m.max_speed;
            const i = t.n_peds;
            t.state.ped.slot[i] = abi.Slot.alive;
            t.state.ped.gen[i] = 1;
            t.state.ped.appearance[i] = .{ .sprite = 0, .remap = @intCast(t.rand(tries, 15) % 53) };
            t.n_peds += 1;
        }
        // Player 0's ped, riding car 0.
        if (t.n_cars > 0) {
            const i = t.n_peds;
            t.state.ped.slot[i] = abi.Slot.alive;
            t.state.ped.gen[i] = 1;
            t.state.ped.riding[i] = .{ .vehicle = abi.EntityId.make(.car, 0, 1) };
            t.state.ped.appearance[i] = .{ .sprite = 0, .remap = list.Appearance.no_remap };
            t.state.players[0] = .{
                .ped = abi.EntityId.make(.ped, i, 1),
                .car = abi.EntityId.make(.car, 0, 1),
                .kills = 0,
                .deaths = 0,
                .score = 0,
                .respawn_timer = 0,
                .flags = abi.PlayerRow.flag_active | abi.PlayerRow.flag_connected,
            };
            t.n_peds += 1;
        }
        t.state.ped.len = t.n_peds;
        t.writeState();
    }

    fn chooseCarDir(t: *Traffic, i: u32, m: *Mover) void {
        const c = t.cell(m.cx, m.cy, m.cz);
        var options: [4]Dir = undefined;
        var n: u32 = 0;
        inline for (.{ Dir.pos_x, Dir.pos_y, Dir.neg_x, Dir.neg_y }) |d| {
            if (c & d.arrowBit() != 0 and d != m.dir.reverse()) {
                options[n] = d;
                n += 1;
            }
        }
        if (n == 0) {
            // No arrow: carry on if the road continues, else find any road.
            if (t.roadAhead(m, m.dir) != null) return;
            inline for (.{ Dir.pos_x, Dir.pos_y, Dir.neg_x, Dir.neg_y }) |d| {
                if (d != m.dir.reverse() and t.roadAhead(m, d) != null) {
                    options[n] = d;
                    n += 1;
                }
            }
            if (n == 0) {
                m.dir = m.dir.reverse();
                return;
            }
        }
        // Prefer going straight when allowed.
        for (options[0..n]) |d| if (d == m.dir and t.rand(i, 21) % 4 != 0) return;
        m.dir = options[t.rand(i, 22) % n];
    }

    /// The z of the road cell next to the mover in direction d, if any.
    fn roadAhead(t: *const Traffic, m: *const Mover, d: Dir) ?i32 {
        const nx = m.cx + d.dx();
        const ny = m.cy + d.dy();
        for ([_]i32{ 0, 1, -1 }) |dz| if (t.isRoad(nx, ny, m.cz + dz)) return m.cz + dz;
        return null;
    }

    fn pavementAhead(t: *const Traffic, m: *const Mover, d: Dir) ?i32 {
        const nx = m.cx + d.dx();
        const ny = m.cy + d.dy();
        for ([_]i32{ 0, 1, -1 }) |dz| if (t.isPavement(nx, ny, m.cz + dz)) return m.cz + dz;
        return null;
    }

    fn advance(t: *Traffic, m: *Mover, turn_rate: f32) void {
        const tx = @as(f32, @floatFromInt(m.cx + m.dir.dx())) + 0.5;
        const ty = @as(f32, @floatFromInt(m.cy + m.dir.dy())) + 0.5;
        const dx = tx - m.x;
        const dy = ty - m.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d > 1e-4) {
            const mv = @min(m.speed, d);
            m.x += dx / d * mv;
            m.y += dy / d * mv;
            // Turn the heading toward the travel direction.
            const want = std.math.atan2(dy, dx) * 65536.0 / std.math.tau;
            var diff = @mod(want - m.heading + 32768.0, 65536.0) - 32768.0;
            diff = std.math.clamp(diff, -turn_rate, turn_rate);
            m.heading = @mod(m.heading + diff, 65536.0);
        }
        _ = t;
    }

    pub fn step(t: *Traffic) void {
        for (t.cars[0..t.n_cars], 0..) |*m, i| {
            const ii: u32 = @intCast(i);
            const next_x = @as(f32, @floatFromInt(m.cx + m.dir.dx())) + 0.5;
            const next_y = @as(f32, @floatFromInt(m.cy + m.dir.dy())) + 0.5;
            if (@abs(next_x - m.x) + @abs(next_y - m.y) <= m.speed + 1e-3) {
                // Arrived at the next cell's centre.
                const nz = t.roadAhead(m, m.dir) orelse m.cz;
                m.cx += m.dir.dx();
                m.cy += m.dir.dy();
                m.cz = nz;
                m.x = next_x;
                m.y = next_y;
                const before = m.dir;
                t.chooseCarDir(ii, m);
                if (m.dir != before) m.speed = @min(m.speed, 0.12);
            }
            // Speed: build up on straights, ease off near turns.
            const target_speed = if (t.roadAhead(m, m.dir) != null) m.max_speed else 0.1;
            m.speed += std.math.clamp(target_speed - m.speed, -0.02, 0.006);
            t.advance(m, 2600);
            const fx = m.x - @as(f32, @floatFromInt(m.cx));
            const fy = m.y - @as(f32, @floatFromInt(m.cy));
            _ = fx;
            _ = fy;
            const zt = @as(f32, @floatFromInt(m.cz)) + t.lidHeight(m.cx, m.cy, m.cz);
            m.z += (zt - m.z) * 0.3;
        }
        for (t.peds[0..t.n_peds], 0..) |*m, i| {
            if (m.max_speed == 0) continue;
            const ii: u32 = @intCast(i + 1000);
            const next_x = @as(f32, @floatFromInt(m.cx + m.dir.dx())) + 0.5;
            const next_y = @as(f32, @floatFromInt(m.cy + m.dir.dy())) + 0.5;
            if (@abs(next_x - m.x) + @abs(next_y - m.y) <= m.speed + 1e-3 or t.pavementAhead(m, m.dir) == null) {
                if (t.pavementAhead(m, m.dir)) |nz| {
                    m.cx += m.dir.dx();
                    m.cy += m.dir.dy();
                    m.cz = nz;
                    m.x = next_x;
                    m.y = next_y;
                }
                var options: [4]Dir = undefined;
                var n: u32 = 0;
                inline for (.{ Dir.pos_x, Dir.pos_y, Dir.neg_x, Dir.neg_y }) |d| {
                    if (t.pavementAhead(m, d) != null) {
                        options[n] = d;
                        n += 1;
                    }
                }
                if (n > 0) {
                    var keep = false;
                    for (options[0..n]) |d| if (d == m.dir and t.rand(ii, 31) % 5 != 0) {
                        keep = true;
                    };
                    if (!keep) m.dir = options[t.rand(ii, 32) % n];
                }
            }
            t.advance(m, 4000);
            m.z = @as(f32, @floatFromInt(m.cz)) + 1.0;
        }
        t.state.tick +%= 1;
        t.writeState();
    }

    fn toFx(v: f32) abi.Fx {
        return @intFromFloat(v * @as(f32, abi.fx_one));
    }

    fn writeState(t: *Traffic) void {
        for (t.cars[0..t.n_cars], 0..) |m, i| t.writeMover(&t.state.car, i, m);
        for (t.peds[0..t.n_peds], 0..) |m, i| t.writeMover(&t.state.ped, i, m);
        // The rider sits at its car.
        if (t.n_cars > 0) {
            const pi = t.n_peds - 1;
            t.state.ped.transform[pi] = t.state.car.transform[0];
        }
    }

    fn writeMover(_: *Traffic, table: anytype, i: usize, m: Mover) void {
        const prev = table.transform[i];
        const tr: abi.Transform = .{ .x = toFx(m.x), .y = toFx(m.y), .z = toFx(m.z), .heading = @intFromFloat(@mod(m.heading, 65536.0)) };
        table.transform[i] = tr;
        table.velocity[i] = .{ .vx = tr.x -% prev.x, .vy = tr.y -% prev.y, .vz = tr.z -% prev.z, .spin = 0 };
    }

    pub fn stateBytes(t: *const Traffic) []const u8 {
        return std.mem.asBytes(&t.state);
    }
};

// ---------------------------------------------------------------------------
// Recorded entity buffers

pub const Recording = struct {
    pub const magic = "GREC";
    pub const version: u32 = 1;
    /// magic, version, state_size, view_count, tick_count, tick_hz
    pub const header_size = 24;

    views: []const abi.ColumnDesc,
    state_size: u32,
    tick_count: u32,
    tick_hz: u32,
    states: []const u8,

    pub fn state(r: *const Recording, i: u32) []const u8 {
        const k = @min(i, r.tick_count - 1);
        return r.states[@as(usize, k) * r.state_size ..][0..r.state_size];
    }

    /// Reads a recording in place; `bytes` must stay alive and be 4-byte
    /// aligned (the view table is used directly).
    pub fn parse(bytes: []align(4) const u8) error{ BadMagic, BadVersion, Truncated }!Recording {
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        const w = struct {
            fn f(b: []const u8, i: usize) u32 {
                return std.mem.readInt(u32, b[4 + i * 4 ..][0..4], .little);
            }
        }.f;
        if (w(bytes, 0) != version) return error.BadVersion;
        const ss = w(bytes, 1);
        const vc = w(bytes, 2);
        const tc = w(bytes, 3);
        const hz = w(bytes, 4);
        const vbytes = @as(usize, vc) * @sizeOf(abi.ColumnDesc);
        const total = header_size + vbytes + @as(usize, ss) * tc;
        if (bytes.len < total or tc == 0 or ss == 0) return error.Truncated;
        const vs: []const abi.ColumnDesc = @alignCast(std.mem.bytesAsSlice(abi.ColumnDesc, bytes[header_size..][0..vbytes]));
        return .{ .views = vs, .state_size = ss, .tick_count = tc, .tick_hz = hz, .states = bytes[header_size + vbytes ..][0 .. @as(usize, ss) * tc] };
    }

    pub fn writeHeader(out: *std.ArrayList(u8), gpa: std.mem.Allocator, vs: []const abi.ColumnDesc, ss: u32, tick_count: u32) !void {
        try out.appendSlice(gpa, magic);
        for ([_]u32{ version, ss, @intCast(vs.len), tick_count, abi.tick_hz }) |v| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try out.appendSlice(gpa, &b);
        }
        try out.appendSlice(gpa, std.mem.sliceAsBytes(vs));
    }
};

/// Records `ticks` ticks of the traffic stub. Caller owns the bytes.
pub fn recordTraffic(gpa: std.mem.Allocator, grid: *const abi.Grid, seed: u64, cars: u32, peds: u32, ticks: u32) ![]align(4) u8 {
    const t = try gpa.create(Traffic);
    defer gpa.destroy(t);
    t.init(grid, seed, cars, peds);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try Recording.writeHeader(&out, gpa, views(), state_size, ticks);
    for (0..ticks) |_| {
        try out.appendSlice(gpa, t.stateBytes());
        t.step();
    }
    const aligned = try gpa.alignedAlloc(u8, .@"4", out.items.len);
    @memcpy(aligned, out.items);
    out.deinit(gpa);
    return aligned;
}

const testing = std.testing;

fn testGrid(gpa: std.mem.Allocator) !*abi.Grid {
    const g = try gpa.create(abi.Grid);
    @memset(std.mem.asBytes(g), 0);
    // A ring road at z = 1: x from 10 to 30 on rows 10 and 30, both
    // columns, all arrows clockwise. Pavement next to it.
    const road_e = grid_mod.encode(.solid, 0, .road, grid_mod.arrow_pos_x);
    const road_s = grid_mod.encode(.solid, 0, .road, grid_mod.arrow_pos_y);
    const road_w = grid_mod.encode(.solid, 0, .road, grid_mod.arrow_neg_x);
    const road_n = grid_mod.encode(.solid, 0, .road, grid_mod.arrow_neg_y);
    for (10..31) |i| {
        g.blocks[1][10][i] = road_e;
        g.blocks[1][30][i] = road_w;
        g.blocks[1][i][30] = road_s;
        g.blocks[1][i][10] = road_n;
        g.blocks[1][9][i] = grid_mod.encode(.solid, 0, .pavement, 0);
    }
    g.blocks[1][10][30] = road_s;
    g.blocks[1][30][30] = road_w;
    g.blocks[1][30][10] = road_n;
    g.blocks[1][10][10] = road_e;
    return g;
}

test "traffic stays on the road and records" {
    const gpa = testing.allocator;
    const g = try testGrid(gpa);
    defer gpa.destroy(g);
    const bytes = try recordTraffic(gpa, g, 7, 4, 3, 300);
    defer gpa.free(bytes);
    const rec = try Recording.parse(bytes);
    try testing.expectEqual(@as(u32, 300), rec.tick_count);
    try testing.expectEqual(@as(u32, state_size), rec.state_size);

    const lay = list.Layout.init(rec.views);
    var out: [16]list.Instance = undefined;
    for (0..rec.tick_count) |k| {
        const n = list.build(&lay, null, rec.state(@intCast(k)), 1, .{}, &out);
        // 4 cars + 3 walking peds; the player's ped rides car 0.
        try testing.expectEqual(@as(usize, 7), n);
        for (out[0..n]) |inst| {
            if (inst.kind != 0) continue;
            const on_ring = (inst.y > 9.4 and inst.y < 11.6) or (inst.y > 29.4 and inst.y < 31.6) or
                (inst.x > 9.4 and inst.x < 11.6) or (inst.x > 29.4 and inst.x < 31.6);
            try testing.expect(on_ring);
            try testing.expectApproxEqAbs(@as(f32, 2.0), inst.z, 0.01);
        }
    }
    const t = list.target(&lay, rec.state(299), 0);
    try testing.expectEqual(@as(u32, 1), t.found);
    try testing.expect(@abs(t.vx) + @abs(t.vy) > 0.05);
    try testing.expectError(error.BadMagic, Recording.parse(@alignCast(bytes[4..])));
}
