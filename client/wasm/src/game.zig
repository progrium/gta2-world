//! The browser's game module (M1: one local player, sim in WASM).
//!
//! JavaScript copies a file into memory from `alloc`, calls `loadStyle` and
//! `loadMap`, then `gameStart`. Each tick it writes I2 frames into
//! `framesPtr()` and calls `gameStep`; each animation frame it calls
//! `buildList(alpha)` and `cameraTarget(alpha, slot)` and hands the buffers
//! to the TypeScript renderer. All exported pointers stay valid until the
//! next load call.
//!
//! Two modes:
//! - offline (`gameStart`): the sim runs in `.authoritative` mode and the
//!   browser is the authority.
//! - online (`netStart`): net/'s prediction client runs the sim in
//!   `.predict` mode against server snapshots. JavaScript owns the
//!   transport: it passes snapshot and baseline bodies to `netSnapshot`,
//!   calls `netUpdate` every animation frame and sends what `netInput`
//!   encodes every tick.

const std = @import("std");
const builtin = @import("builtin");
const formats = @import("formats");
const render = @import("render");
const sim = @import("sim");
const abi = @import("interfaces").abi;
const Frame = @import("interfaces").input.Frame;
const net = @import("net");

const gpa = if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
const mesh = render.mesh;
const list = render.list;
const Sim = sim.Sim16;
const max_players = Sim.config.max_players;

var style: ?formats.sty.Style = null;
var prepared: ?render.style.Prepared = null;
var map: ?formats.gmp.Map = null;
var map_mesh: ?mesh.Mesh = null;
var grid: ?*abi.Grid = null;
var anim_table: []u16 = &.{};

var game: Sim = undefined;
var running = false;
var prev_state: [Sim.state_size]u8 align(8) = undefined;
var frames: [max_players]Frame = @splat(Frame.neutral(0));
var pending: [max_players]abi.Command = undefined;
var pending_len: usize = 0;
var layout: list.Layout = list.Layout.init(Sim.views());
var instances: [4096]list.Instance = undefined;
var target_buf: list.Target = undefined;

var err_buf: [256]u8 = undefined;
var err_len: usize = 0;

fn setError(comptime what: []const u8, e: anyerror) i32 {
    const s = std.fmt.bufPrint(&err_buf, what ++ ": {s}", .{@errorName(e)}) catch "error";
    err_len = s.len;
    return -1;
}

export fn alloc(n: usize) ?[*]u8 {
    const s = gpa.alignedAlloc(u8, .@"4", n) catch return null;
    return s.ptr;
}
export fn free(p: [*]u8, n: usize) void {
    gpa.free(@as([]align(4) u8, @alignCast(p[0..n])));
}
export fn errorPtr() [*]const u8 {
    return &err_buf;
}
export fn errorLen() usize {
    return err_len;
}

// ------------------------------------------------------------------ style

export fn loadStyle(p: [*]const u8, n: usize) i32 {
    if (prepared) |*pp| pp.deinit(gpa);
    prepared = null;
    if (style) |*s| s.deinit();
    style = null;
    style = formats.sty.parse(gpa, p[0..n]) catch |e| return setError("style", e);
    prepared = render.style.prepare(gpa, &style.?) catch |e| return setError("style", e);
    return 0;
}

/// [tile_layers, sprite_layers, sprite_count, ppal_pages, palette_base x8,
///  sprite_base x6]
var style_info: [18]u32 = undefined;
export fn styleInfo() [*]const u32 {
    const s = &style.?;
    const pp = &prepared.?;
    style_info[0] = pp.tile_layers;
    style_info[1] = pp.sprite_layers;
    style_info[2] = @intCast(s.sprites.len);
    style_info[3] = @intCast((s.ppal.len + formats.sty.page_bytes - 1) / formats.sty.page_bytes);
    for (0..8) |i| style_info[4 + i] = s.palette_base.base(@enumFromInt(i));
    for (0..6) |i| style_info[12 + i] = s.sprite_base.base(@enumFromInt(i));
    return &style_info;
}
export fn tilesPtr() [*]const u8 {
    return style.?.tiles.ptr;
}
export fn tilesLen() usize {
    return style.?.tiles.len;
}
export fn spritePagesPtr() [*]const u8 {
    return style.?.sprite_graphics.ptr;
}
export fn spritePagesLen() usize {
    return style.?.sprite_graphics.len;
}
export fn ppalPtr() [*]const u8 {
    return style.?.ppal.ptr;
}
export fn ppalLen() usize {
    return style.?.ppal.len;
}
export fn palxPtr() [*]const u16 {
    return style.?.palx.ptr;
}
export fn spriteTablePtr() [*]const u8 {
    return @ptrCast(prepared.?.sprite_table.ptr);
}
export fn spriteTableRows() usize {
    return prepared.?.sprite_table.len / render.style.sprite_table_width;
}

// ------------------------------------------------------------------ map

export fn loadMap(p: [*]const u8, n: usize, bake_lights: bool) i32 {
    running = false;
    if (map_mesh) |*m| m.deinit(gpa);
    map_mesh = null;
    if (map) |*m| m.deinit();
    map = null;
    gpa.free(anim_table);
    anim_table = &.{};
    map = formats.gmp.parse(gpa, p[0..n]) catch |e| return setError("map", e);
    map_mesh = mesh.buildChunked(gpa, &map.?, .{ .bake_lights = bake_lights }) catch |e| return setError("mesh", e);
    if (grid == null) grid = gpa.create(abi.Grid) catch |e| return setError("grid", e);
    formats.grid.build(&map.?, grid.?);
    // Animations: [count] then per anim [base, frame_rate, repeat, len, tiles...].
    var total: usize = 1;
    for (map.?.anims) |a| total += 4 + a.tiles.len;
    anim_table = gpa.alloc(u16, total) catch |e| return setError("anim", e);
    anim_table[0] = @intCast(map.?.anims.len);
    var k: usize = 1;
    for (map.?.anims) |a| {
        anim_table[k] = a.base;
        anim_table[k + 1] = a.frame_rate;
        anim_table[k + 2] = a.repeat;
        anim_table[k + 3] = @intCast(a.tiles.len);
        @memcpy(anim_table[k + 4 ..][0..a.tiles.len], a.tiles);
        k += 4 + a.tiles.len;
    }
    return 0;
}

/// Builds only the collision grid, for tests and headless tools.
pub fn loadGridOnly(bytes: []const u8) !void {
    running = false;
    if (map) |*m| m.deinit();
    map = try formats.gmp.parse(gpa, bytes);
    if (grid == null) grid = try gpa.create(abi.Grid);
    formats.grid.build(&map.?, grid.?);
}

/// Uses the sim's synthetic test map (no game files needed).
export fn loadTestMap() void {
    running = false;
    if (grid == null) grid = gpa.create(abi.Grid) catch return;
    sim.testmap.build(grid.?);
}

export fn vertexPtr() [*]const u8 {
    return @ptrCast(map_mesh.?.vertices.ptr);
}
export fn vertexCount() usize {
    return map_mesh.?.vertices.len;
}
export fn chunkPtr() [*]const u8 {
    return @ptrCast(map_mesh.?.chunks.ptr);
}
export fn chunkCount() usize {
    return map_mesh.?.chunks.len;
}
export fn animPtr() [*]const u16 {
    return anim_table.ptr;
}
export fn animLen() usize {
    return anim_table.len;
}
/// [triangles, lids, sides, transparent, dummy, hidden, lights, block defs]
var mesh_info: [8]u32 = undefined;
export fn meshInfo() [*]const u32 {
    const st = map_mesh.?.stats;
    mesh_info = .{ st.triangles, st.lids, st.sides, st.transparent, st.dummy, st.hidden, @intCast(map.?.lights.len), @intCast(map.?.blocks.len) };
    return &mesh_info;
}

// ------------------------------------------------------------------ game

/// Starts a session on the loaded map: the sim spawns its ambient cars and
/// peds, and player slot 0 joins (on a random pavement cell, or at block
/// `hint_x`, `hint_y` when `hint` is set).
export fn gameStart(seed: u32, hint: bool, hint_x: u32, hint_y: u32) i32 {
    const g = grid orelse return setError("start", error.NoMap);
    game.init(g, .{ .seed = seed, .mode = .authoritative });
    frames = @splat(Frame.neutral(0));
    pending_len = 0;
    const arg: u32 = if (hint) sim.spawnHint(@truncate(hint_x), @truncate(hint_y)) else 0;
    queue(.{ .op = .join, .slot = 0, .arg = arg });
    @memcpy(&prev_state, game.stateBytes());
    running = true;
    return 0;
}

fn queue(cmd: abi.Command) void {
    if (pending_len < pending.len) {
        pending[pending_len] = cmd;
        pending_len += 1;
    }
}

/// Joins or leaves a local player slot at the next step.
export fn gameJoin(slot: u32) void {
    if (slot < max_players) queue(.{ .op = .join, .slot = @intCast(slot), .arg = 0 });
}
export fn gameLeave(slot: u32) void {
    if (slot < max_players) queue(.{ .op = .leave, .slot = @intCast(slot), .arg = 0 });
}

/// Debug and tuning aid: drops a car 1.1 blocks in front of the slot's ped,
/// facing the same way. Returns false if the player is in a car or the car
/// table is full. Changes the state, so offline play only.
export fn gameSpawnCar(slot: u32) bool {
    if (!running or slot >= max_players) return false;
    if (!game.playerRow(slot).car.isNone()) return false;
    const ped = game.pedOf(slot) orelse return false;
    const t = game.transformOf(ped) orelse return false;
    const a = @as(f32, @floatFromInt(t.heading)) * (std.math.tau / 65536.0);
    const d: f32 = 1.1 * @as(f32, abi.fx_one);
    const x = t.x + @as(i32, @intFromFloat(@cos(a) * d));
    const y = t.y + @as(i32, @intFromFloat(@sin(a) * d));
    _ = game.spawnCarAt(x, y, t.heading, 0) orelse return false;
    @memcpy(&prev_state, game.stateBytes());
    return true;
}

/// `max_players` I2 frames, 8 bytes each, indexed by slot. JavaScript writes
/// the frames for the next step here.
export fn framesPtr() [*]u8 {
    return @ptrCast(&frames);
}

export fn gameStep() void {
    if (!running) return;
    @memcpy(&prev_state, game.stateBytes());
    for (&frames) |*f| f.* = f.sanitize();
    game.step(&frames, pending[0..pending_len]);
    pending_len = 0;
}

export fn gameTick() u32 {
    if (client) |cl| return cl.sim.tick();
    return if (running) game.tick() else 0;
}

/// State hash as two u32 halves (low, high) for display.
var hash_buf: [2]u32 = undefined;
export fn gameHash() [*]const u32 {
    const h = if (running) game.hash() else 0;
    hash_buf = .{ @truncate(h), @truncate(h >> 32) };
    return &hash_buf;
}

/// [active, in_car, hp, kills, deaths, respawn_timer, speed (fx), z (fx)]
var player_buf: [8]i32 = undefined;
export fn playerInfo(slot: u32) [*]const i32 {
    player_buf = @splat(0);
    if (slot >= max_players) return &player_buf;
    const g: *Sim = if (client) |cl| cl.sim else if (running) &game else return &player_buf;
    const row = g.playerRow(slot).*;
    player_buf[0] = @intFromBool(row.flags & abi.PlayerRow.flag_active != 0);
    player_buf[1] = @intFromBool(!row.car.isNone());
    player_buf[3] = row.kills;
    player_buf[4] = row.deaths;
    player_buf[5] = @bitCast(row.respawn_timer);
    const t = list.target(&layout, g.stateBytes(), slot);
    if (t.found != 0) {
        player_buf[6] = @intFromFloat(@sqrt(t.vx * t.vx + t.vy * t.vy) * @as(f32, abi.fx_one));
        player_buf[7] = @intFromFloat(t.z * @as(f32, abi.fx_one));
    }
    if (!row.ped.isNone()) player_buf[2] = healthOf(g, row.ped);
    return &player_buf;
}

fn healthOf(g: *Sim, id: abi.EntityId) i32 {
    for (Sim.views()) |v| {
        if (v.kind != id.kind() or v.component != @intFromEnum(abi.ComponentId.health)) continue;
        if (id.index() >= v.count) return 0;
        const bytes = g.stateBytes()[v.offset + id.index() * v.stride ..][0..@sizeOf(abi.Health)];
        return std.mem.bytesToValue(abi.Health, bytes).hp;
    }
    return 0;
}

fn bases() list.Bases {
    var b: list.Bases = .{};
    const s = &(style orelse return b);
    b.sprite_count = @intCast(s.sprites.len);
    b.sprite[@intFromEnum(abi.Kind.car)] = s.sprite_base.base(.car);
    b.sprite[@intFromEnum(abi.Kind.ped)] = s.sprite_base.base(.ped);
    b.sprite[@intFromEnum(abi.Kind.projectile)] = s.sprite_base.base(.code_obj);
    b.sprite[@intFromEnum(abi.Kind.pickup)] = s.sprite_base.base(.code_obj);
    b.sprite[@intFromEnum(abi.Kind.map_object)] = s.sprite_base.base(.map_obj);
    b.remap_palette[@intFromEnum(abi.Kind.car)] = s.palette_base.base(.car_remap);
    b.remap_palette[@intFromEnum(abi.Kind.ped)] = s.palette_base.base(.ped_remap);
    b.remap_palette[@intFromEnum(abi.Kind.projectile)] = s.palette_base.base(.code_obj_remap);
    b.remap_palette[@intFromEnum(abi.Kind.pickup)] = s.palette_base.base(.code_obj_remap);
    b.remap_palette[@intFromEnum(abi.Kind.map_object)] = s.palette_base.base(.map_obj_remap);
    return b;
}

/// Builds the render list between the last two steps at `alpha`. Returns
/// the instance count.
export fn buildList(alpha: f32) usize {
    if (client) |cl| {
        if (!cl.started) return 0;
        return list.build(&layout, null, cl.renderState(net_now), 1, bases(), &instances);
    }
    if (!running) return 0;
    return list.build(&layout, &prev_state, game.stateBytes(), alpha, bases(), &instances);
}
export fn instancePtr() [*]const u8 {
    return @ptrCast(&instances);
}

/// Camera target for player `slot`, interpolated like the list:
/// [x, y, z, angle, vx, vy, found] as f32.
export fn cameraTarget(alpha: f32, slot: u32) [*]const u8 {
    if (client) |cl| {
        target_buf = if (cl.started) list.target(&layout, cl.render, slot) else std.mem.zeroes(list.Target);
        return @ptrCast(&target_buf);
    }
    if (!running) {
        target_buf = std.mem.zeroes(list.Target);
        return @ptrCast(&target_buf);
    }
    const a = list.target(&layout, &prev_state, slot);
    const b = list.target(&layout, game.stateBytes(), slot);
    target_buf = b;
    if (a.found != 0 and b.found != 0) {
        target_buf.x = a.x + (b.x - a.x) * alpha;
        target_buf.y = a.y + (b.y - a.y) * alpha;
        target_buf.z = a.z + (b.z - a.z) * alpha;
    }
    return @ptrCast(&target_buf);
}

// ------------------------------------------------------------------ online

const NetClient = net.client.Client(Sim);
var client: ?*NetClient = null;
var net_now: f64 = 0;
var input_buf: [1100]u8 = undefined;
var input_len: usize = 0;

/// Switches to online mode as player `slot` (from `welcome`). Needs a loaded
/// map. Tuning goes back to the defaults: the server uses them.
export fn netStart(slot: u32, buffer_ticks: u32) i32 {
    netStop();
    const g = grid orelse return setError("net", error.NoMap);
    running = false;
    tuneReset();
    const cl = gpa.create(NetClient) catch |e| return setError("net", e);
    cl.* = NetClient.init(gpa, g, @intCast(slot), .{ .buffer_ticks = @floatFromInt(buffer_ticks) }) catch |e| {
        gpa.destroy(cl);
        return setError("net", e);
    };
    client = cl;
    return 0;
}

export fn netStop() void {
    if (client) |cl| {
        cl.deinit();
        gpa.destroy(cl);
    }
    client = null;
}

/// `Sim.layout_hash` as (low, high) u32 halves, for I3 `hello`.
var layout_buf: [2]u32 = .{ @truncate(Sim.layout_hash), @truncate(Sim.layout_hash >> 32) };
export fn layoutHashPtr() [*]const u32 {
    return &layout_buf;
}

/// A snapshot (datagram) or baseline (stream) body, starting at its type byte.
export fn netSnapshot(p: [*]const u8, n: usize, now_ms: f64) i32 {
    const cl = client orelse return setError("net", error.NotStarted);
    net_now = now_ms;
    cl.onSnapshot(p[0..n], now_ms) catch |e| return setError("snapshot", e);
    return 0;
}

/// Per animation frame: runs the predicted ticks that are due with the
/// frame in `framesPtr()[0]`. Returns the number of ticks run; send one
/// `netInput` datagram per tick run.
export fn netUpdate(now_ms: f64) u32 {
    const cl = client orelse return 0;
    net_now = now_ms;
    return cl.update(now_ms, frames[0].sanitize());
}

/// Encodes the input datagram for the newest tick. Returns its length; the
/// bytes are at `netInputPtr()`.
export fn netInput(now_ms: f64) usize {
    const cl = client orelse return 0;
    if (!cl.started) return 0;
    const out = cl.writeInput(&input_buf, now_ms) catch return 0;
    input_len = out.len;
    return out.len;
}
export fn netInputPtr() [*]const u8 {
    return &input_buf;
}

/// [started, rtt ms, snapshots, replays, max replay, resyncs, hitches, input_ack]
var net_stats: [8]u32 = undefined;
export fn netStats() [*]const u32 {
    net_stats = @splat(0);
    const cl = client orelse return &net_stats;
    net_stats = .{
        @intFromBool(cl.started),
        @intFromFloat(@max(cl.rtt_ms, 0)),
        @truncate(cl.stats.snapshots),
        @truncate(cl.stats.replays),
        cl.stats.max_replay,
        @truncate(cl.stats.resyncs),
        @truncate(cl.stats.hitches),
        cl.input_ack,
    };
    return &net_stats;
}

// ------------------------------------------------------------------ tuning
//
// The placeholder handling in sim/tuning.zig, adjustable live for this
// offline build. `tuneNames()` is a ';'-separated list of `name:unit`
// entries, unit `fx` (16.16 fixed point), `int` or `shift`; values are read
// and written as raw i32 by index.

const T = sim.tuning;
const Entry = struct { name: []const u8, unit: []const u8 };

const car_info = @typeInfo(T.CarModel).@"struct";
const car_fields = car_info.field_names;
const car_types = car_info.field_types;
const ped_vars = [_][]const u8{ "ped_walk", "ped_run", "ped_back", "ped_tank_turn", "ped_direct_turn", "ped_jump_vz" };

const tune_entries = blk: {
    var out: [car_fields.len + ped_vars.len]Entry = undefined;
    for (car_fields, car_types, 0..) |f, F, i| {
        out[i] = .{ .name = "car." ++ f, .unit = unitOf(F, f) };
    }
    for (ped_vars, 0..) |n, i| {
        out[car_fields.len + i] = .{ .name = n, .unit = if (std.mem.endsWith(u8, n, "turn")) "int" else "fx" };
    }
    break :blk out;
};

fn unitOf(comptime F: type, comptime name: []const u8) []const u8 {
    if (F != i32) return "shift";
    // Fx is i32 too; the fields that are plain integers are named here.
    const ints = [_][]const u8{ "mass", "hp", "steer_gain", "max_yaw", "handbrake_yaw_8ths", "pedal_rate", "steer_rate", "restitution_8ths" };
    for (ints) |n| if (std.mem.eql(u8, n, name)) return "int";
    return "fx";
}

const tune_names = blk: {
    var s: []const u8 = "";
    for (tune_entries, 0..) |e, i| s = s ++ (if (i == 0) "" else ";") ++ e.name ++ ":" ++ e.unit;
    break :blk s;
};

export fn tuneNamesPtr() [*]const u8 {
    return tune_names.ptr;
}
export fn tuneNamesLen() usize {
    return tune_names.len;
}

export fn tuneGet(i: u32) i32 {
    inline for (car_fields, 0..) |f, k| {
        if (i == k) return @intCast(@field(T.car_models[0], f));
    }
    inline for (ped_vars, 0..) |n, k| {
        if (i == car_fields.len + k) return @intCast(@field(T, n));
    }
    return 0;
}

export fn tuneSet(i: u32, v: i32) void {
    saveDefaults();
    inline for (car_fields, car_types, 0..) |f, F, k| {
        if (i == k) {
            for (&T.car_models) |*m| {
                @field(m, f) = std.math.cast(F, v) orelse return;
            }
            return;
        }
    }
    inline for (ped_vars, 0..) |n, k| {
        if (i == car_fields.len + k) {
            @field(T, n) = std.math.cast(@TypeOf(@field(T, n)), v) orelse return;
            return;
        }
    }
}

export fn tuneReset() void {
    T.car_models = T.default_car_models;
    if (!defaults_saved) return;
    inline for (ped_vars, 0..) |n, k| @field(T, n) = @intCast(ped_defaults[k]);
}

/// The on-foot numbers as they were before the first change.
var ped_defaults: [ped_vars.len]i32 = undefined;
var defaults_saved = false;
fn saveDefaults() void {
    if (defaults_saved) return;
    inline for (ped_vars, 0..) |n, k| ped_defaults[k] = @intCast(@field(T, n));
    defaults_saved = true;
}

// ------------------------------------------------------------------ tests

test "a player joins the test map, walks, gets in a car and drives" {
    loadTestMap();
    try std.testing.expectEqual(@as(i32, 0), gameStart(1, false, 0, 0));
    gameStep();
    try std.testing.expectEqual(@as(i32, 1), playerInfo(0)[0]);
    const start = list.target(&layout, game.stateBytes(), 0);
    try std.testing.expect(start.found != 0);
    // Walk forward for a second.
    for (0..30) |t| {
        frames[0] = .{ .steer = 0, .throttle = 127, .buttons = 0, .aim = 0, .seq = @truncate(t) };
        gameStep();
    }
    const moved = list.target(&layout, game.stateBytes(), 0);
    try std.testing.expect(@abs(moved.x - start.x) + @abs(moved.y - start.y) > 0.5);
    try std.testing.expect(buildList(0.5) > 0);
}

test "tuning round trip" {
    const names = tune_names;
    try std.testing.expect(std.mem.indexOf(u8, names, "car.max_speed:fx") != null);
    try std.testing.expect(std.mem.indexOf(u8, names, "car.drag_shift:shift") != null);
    const i: u32 = for (tune_entries, 0..) |e, k| {
        if (std.mem.eql(u8, e.name, "car.max_speed")) break @intCast(k);
    } else unreachable;
    const before = tuneGet(i);
    tuneSet(i, before * 2);
    try std.testing.expectEqual(before * 2, T.carModel(0).max_speed);
    tuneReset();
    try std.testing.expectEqual(before, tuneGet(i));
}
