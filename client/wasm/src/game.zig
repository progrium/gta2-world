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
const skids = @import("skids.zig");
const list = render.list;
const Sim = sim.Sim16;
/// Single player (story levels): one player, the SP state block and systems.
const SimSp = sim.Sim(sim.config_sp);
/// Online deathmatch with police on (the host's room setting): dm16's
/// players with the living city (`sim.config_16_police`).
const SimP = sim.Sim16Police;
const max_players = Sim.config.max_players;

var style: ?formats.sty.Style = null;
var prepared: ?render.style.Prepared = null;
var map: ?formats.gmp.Map = null;
var map_mesh: ?mesh.Mesh = null;
var grid: ?*abi.Grid = null;
var anim_table: []u16 = &.{};

var game: Sim = undefined;
var game_sp: SimSp = undefined;
/// Which offline game runs: deathmatch (`gameStart`, dm16) or single
/// player (`spStart`). Online (`netStart`) is neither.
const Offline = enum { dm, sp };
var offline: Offline = .dm;
var running = false;
var prev_state: [@max(Sim.state_size, SimSp.state_size)]u8 align(8) = undefined;
var frames: [max_players]Frame = @splat(Frame.neutral(0));
var pending: [max_players]abi.Command = undefined;
var pending_len: usize = 0;
var layout: list.Layout = list.Layout.init(Sim.views());
var layout_sp: list.Layout = list.Layout.init(SimSp.views());
var layout_p: list.Layout = list.Layout.init(SimP.views());

/// The views, layout and state of whatever is drawn now.
fn isSp() bool {
    return !online() and offline == .sp;
}
fn curViews() []const abi.ColumnDesc {
    return if (isSp()) SimSp.views() else if (client_p != null) SimP.views() else Sim.views();
}
fn curLayout() *const list.Layout {
    return if (isSp()) &layout_sp else if (client_p != null) &layout_p else &layout;
}
fn curState() []const u8 {
    return if (offline == .sp) game_sp.stateBytes() else game.stateBytes();
}
fn prevState() []const u8 {
    return prev_state[0..curState().len];
}
fn savePrev() void {
    const st = curState();
    @memcpy(prev_state[0..st.len], st);
}
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

/// Car models from the loaded style's car info and a `.gci` file's text
/// (`n` 0 for none: sizes and sprites from the style, default handling).
/// Call after `loadStyle` and before `gameStart`. Returns the model count.
export fn loadCarInfo(p: [*]const u8, n: usize) i32 {
    const s = &(style orelse return setError("cars", error.NoStyle));
    const recs = if (n == 0) &[_]formats.gci.Record{} else formats.gci.parse(gpa, p[0..n]) catch |e| return setError("gci", e);
    defer if (n != 0) gpa.free(recs);
    const specs = formats.cars.build(gpa, s, recs, copyFields(formats.cars.Spec, sim.tuning.default_spec)) catch |e| return setError("cars", e);
    defer gpa.free(specs);
    var models: [sim.tuning.max_car_models]sim.tuning.CarModel = undefined;
    const count = @min(specs.len, models.len);
    for (specs[0..count], models[0..count]) |sp, *m| m.* = sim.tuning.deriveModel(copyFields(sim.tuning.CarSpec, sp));
    sim.tuning.setCarModels(models[0..count]);
    // Police, emergency and army models by the standard numbering.
    sim.tuning_career.setStandardRoles(count);
    loaded_models = models;
    loaded_count = count;
    return @intCast(count);
}

/// Back to the one default model (online: the server does not load car
/// info yet, and both sides must agree).
/// Hash of the installed car models (sim.tuning.carModelsHash): a client and
/// the host it joins must agree, or prediction drifts.
export fn carModelsHash() u64 {
    return sim.tuning.carModelsHash();
}

export fn useDefaultCars() void {
    sim.tuning.setCarModels(&.{});
    sim.tuning_career.setStandardRoles(0);
    loaded_count = 0;
}

/// The models `loadCarInfo` installed, for `tuneReset`.
var loaded_models: [sim.tuning.max_car_models]sim.tuning.CarModel = undefined;
var loaded_count: usize = 0;

/// Copy the fields two structs share by name.
fn copyFields(comptime To: type, from: anytype) To {
    var out: To = undefined;
    inline for (@typeInfo(To).@"struct".field_names) |name| @field(out, name) = @field(from, name);
    return out;
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
    level_data.deinit(gpa);
    level_sp = .empty;
    skids.clear();
    map = formats.gmp.parse(gpa, p[0..n]) catch |e| return setError("map", e);
    level_data = .{ .inner = formats.level.build(gpa, &map.?) catch |e| return setError("level", e) };
    level_sp = level_data.inner.?.level;
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
    level_data.deinit(gpa);
    level_sp = .empty;
    if (map) |*m| m.deinit();
    map = try formats.gmp.parse(gpa, bytes);
    if (grid == null) grid = try gpa.create(abi.Grid);
    formats.grid.build(&map.?, grid.?);
}

/// Uses the sim's synthetic test map (no game files needed).
export fn loadTestMap() void {
    running = false;
    level_data.deinit(gpa);
    level_sp = .empty;
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

// ------------------------------------------------------------------ level

/// The level the single-player sim reads (zones, map objects and lights
/// from the map; the script once formats/scr.zig loads it).
var level_sp: sim.Level = .empty;
/// Offline deathmatch's level: the main script only, for its car shops.
var level_dm: sim.Level = .empty;
var level_data: LevelData = .{};
const LevelData = struct {
    inner: ?formats.level.LevelData = null,
    fn deinit(d: *LevelData, a: std.mem.Allocator) void {
        if (d.inner) |*i| i.deinit(a);
        d.* = .{};
    }
};

/// The level's script files, by name: the main `.scr` and its mission
/// sub-scripts. Kept as bytes for formats/scr.zig (workstream A1), which
/// builds `level_sp.script` and `.missions` from them; until it lands the
/// level runs without a script.
const ScriptFile = struct { name: []u8, bytes: []u8 };
var script_files: [64]ScriptFile = undefined;
var script_count: usize = 0;

export fn scriptsClear() void {
    for (script_files[0..script_count]) |f| {
        gpa.free(f.name);
        gpa.free(f.bytes);
    }
    script_count = 0;
}

/// Adds one script file (`name` lower case, e.g. "wil.scr" or
/// "wil_lm1.scr"). Returns the file count, or -1.
export fn scriptAdd(name_p: [*]const u8, name_n: usize, p: [*]const u8, n: usize) i32 {
    if (script_count == script_files.len) return setError("script", error.TooManyFiles);
    const name = gpa.dupe(u8, name_p[0..name_n]) catch |e| return setError("script", e);
    const bytes = gpa.dupe(u8, p[0..n]) catch |e| {
        gpa.free(name);
        return setError("script", e);
    };
    script_files[script_count] = .{ .name = name, .bytes = bytes };
    script_count += 1;
    return @intCast(script_count);
}

/// The parsed scripts the level points into (freed on the next load).
var parsed_main: ?formats.scr.Parsed = null;
var parsed_missions: std.ArrayList(formats.scr.Parsed) = .empty;
var mission_scripts: []sim.level.Script = &.{};

fn freeScripts() void {
    if (parsed_main) |*m| m.deinit();
    parsed_main = null;
    for (parsed_missions.items) |*m| m.deinit();
    parsed_missions.clearAndFree(gpa);
    gpa.free(mission_scripts);
    mission_scripts = &.{};
    level_sp.script = .{};
    level_sp.missions = &.{};
}

/// Parses the added script files into the level: the first one added is
/// the main script, the rest its mission sub-scripts (sorted by name; the
/// VM finds a mission by its name).
fn loadScripts() !void {
    freeScripts();
    if (script_count == 0) return;
    parsed_main = try formats.scr.parseMain(gpa, script_files[0].bytes);
    level_sp.script = parsed_main.?.script;
    const subs = script_files[1..script_count];
    std.mem.sort(ScriptFile, subs, {}, struct {
        fn lt(_: void, x: ScriptFile, y: ScriptFile) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    for (subs) |f| try parsed_missions.append(gpa, try formats.scr.parseMission(gpa, f.bytes, formats.scr.stem(f.name)));
    mission_scripts = try gpa.alloc(sim.level.Script, parsed_missions.items.len);
    for (parsed_missions.items, mission_scripts) |p, *o| o.* = p.script;
    level_sp.missions = mission_scripts;
}

/// A loaded script file by name, for the script loader.
pub fn scriptFile(name: []const u8) ?[]const u8 {
    for (script_files[0..script_count]) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.bytes;
    return null;
}

// ------------------------------------------------------------------ text

/// The `.gxt` text table (formats/gxt.zig), kept for the HUD.
var text_bytes: []u8 = &.{};
var text_table: ?formats.gxt.Table = null;
var text_out: []const u8 = &.{};

export fn loadText(p: [*]const u8, n: usize) i32 {
    text_table = null;
    gpa.free(text_bytes);
    text_bytes = &.{};
    text_bytes = gpa.dupe(u8, p[0..n]) catch |e| return setError("text", e);
    text_table = formats.gxt.parse(text_bytes) catch |e| return setError("text", e);
    buildTextLengths() catch |e| return setError("text", e);
    return @intCast(text_table.?.count());
}

/// Characters shown for each numeric text id (markup and the portrait
/// marker left out), for `Level.text_lengths`: the sim times briefs by it.
var text_lengths: []u16 = &.{};

fn buildTextLengths() !void {
    gpa.free(text_lengths);
    text_lengths = &.{};
    const t = &text_table.?;
    var max: u32 = 0;
    for (0..t.count()) |i| {
        const id = std.fmt.parseInt(u32, t.keyAt(i), 10) catch continue;
        if (id < 1 << 16) max = @max(max, id);
    }
    if (max == 0) return;
    text_lengths = try gpa.alloc(u16, max + 1);
    @memset(text_lengths, 0);
    for (0..t.count()) |i| {
        const id = std.fmt.parseInt(u32, t.keyAt(i), 10) catch continue;
        if (id > max) continue;
        const units = t.get(t.keyAt(i)) orelse continue;
        var n: u32 = 0;
        var k: usize = 0;
        while (k + 1 < units.len) : (k += 2) {
            const u = std.mem.readInt(u16, units[k..][0..2], .little);
            if (u == '#' or (k == 0 and u >> 8 == 0x21)) continue;
            n += 1;
        }
        text_lengths[id] = @intCast(@min(n, 0xFFFF));
    }
}

/// Looks up a script message number; returns its length in 16-bit units
/// (at `textPtr()`), or -1 when missing.
export fn textById(id: u32) i32 {
    const t = &(text_table orelse return -1);
    text_out = t.getId(id) orelse return -1;
    return @intCast(text_out.len / 2);
}

/// Looks up a named key (e.g. a fixed message); as `textById`.
export fn textByKey(p: [*]const u8, n: usize) i32 {
    const t = &(text_table orelse return -1);
    text_out = t.get(p[0..n]) orelse return -1;
    return @intCast(text_out.len / 2);
}

/// The last looked-up text, 16-bit little-endian code units. May be
/// unaligned (it points into the file).
export fn textPtr() [*]const u8 {
    return text_out.ptr;
}

// ------------------------------------------------------------------ single-player HUD

/// The single-player HUD state, i32 each:
///   0 lives, 1 multiplier, 2 points, 3 jail cards, 4 stars, 5 wanted
///   points, 6 career flags, 7 out (wasted or busted)
///   8 banner text id, 9 banner ticks left, 10 banner voice
///   11 brief on screen (text id, 0 none), 12 its ticks up, 13 its total
///   ticks, 14 briefs queued (with the one showing)
///   15-26 four display slots of (flags: 1 timer 2 counter, timer ticks,
///   counter value)
///   27 arrow (0 none, 1 entity, 2 point), 28 arrow x, 29 arrow y (fx)
///   30 hud flags, 31 tick
/// Text ids with the top bit set are fixed texts (`sim.sp_state.hud.text_named`).
var sp_buf: [32]i32 = undefined;
export fn spInfo() [*]const i32 {
    sp_buf = @splat(0);
    if (!running or offline != .sp or online()) return &sp_buf;
    const g = &game_sp;
    const cs = g.state.sp.career[0];
    const ws = g.state.sp.wanted[0];
    const hs = g.state.sp.hud[0];
    sp_buf[0] = SimSp.career.lives(g, 0);
    sp_buf[1] = SimSp.career.multiplier(g, 0);
    sp_buf[2] = SimSp.career.score(g, 0);
    sp_buf[3] = SimSp.career.jailCards(g, 0);
    sp_buf[4] = SimSp.wanted.stars(g, 0);
    sp_buf[5] = ws.points;
    sp_buf[6] = cs.flags;
    sp_buf[7] = @intFromBool(SimSp.career.isOut(g, 0));
    if (hs.banner_ticks > 0) {
        sp_buf[8] = @bitCast(hs.banner);
        sp_buf[9] = hs.banner_ticks;
        sp_buf[10] = hs.banner_voice;
    }
    if (hs.brief_showing != 0 and hs.brief_len > 0) {
        sp_buf[11] = @bitCast(hs.briefs[0].text);
        sp_buf[12] = hs.brief_ticks;
        sp_buf[13] = hs.brief_total;
    }
    sp_buf[14] = hs.brief_len;
    for (hs.display, 0..) |d, i| {
        sp_buf[15 + i * 3] = d.flags;
        sp_buf[16 + i * 3] = d.timer;
        sp_buf[17 + i * 3] = d.counter;
    }
    if (!hs.arrow.isNone()) {
        if (g.state.world.isAlive(hs.arrow)) if (g.transformOf(hs.arrow)) |t| {
            sp_buf[27] = 1;
            sp_buf[28] = t.x;
            sp_buf[29] = t.y;
        };
    } else if (hs.arrow_x != 0 or hs.arrow_y != 0) {
        sp_buf[27] = 2;
        sp_buf[28] = hs.arrow_x;
        sp_buf[29] = hs.arrow_y;
    }
    sp_buf[30] = hs.flags;
    sp_buf[31] = @bitCast(g.tick());
    return &sp_buf;
}

/// Offline debug and test aid: drives the single-player HUD and career
/// through their APIs (sim/sp/hud.zig, career.zig, wanted.zig), as the
/// script would. Changes the state, so offline play only. Returns false
/// when no single-player game runs or `op` is unknown.
///   1 banner (a text id, b ticks)   2 brief (a text id)   3 timer (a ticks)
///   4 counter (a which, b value)    5 arrow at block (a, b)   6 lives += a
///   7 score += a (flat)   8 wanted points += a   9 multiplier = a
export fn spDebug(op: u32, a: i32, b: i32) bool {
    if (!running or offline != .sp or online()) return false;
    const g = &game_sp;
    switch (op) {
        1 => SimSp.hud.postBanner(g, 0, @bitCast(a), @intCast(std.math.clamp(b, 0, 0xFFFF))),
        2 => SimSp.hud.queueBrief(g, 0, @bitCast(a)),
        3 => SimSp.hud.setTimer(g, 0, @bitCast(a)),
        4 => SimSp.hud.setCounter(g, 0, @intCast(a & 1), b),
        5 => SimSp.hud.setArrow(g, 0, .none, (a << 16) + (1 << 15), (b << 16) + (1 << 15)),
        6 => SimSp.career.addLives(g, 0, @intCast(std.math.clamp(a, -127, 127))),
        7 => SimSp.career.addScore(g, 0, a, .flat),
        8 => SimSp.wanted.addPoints(g, 0, a),
        9 => SimSp.career.setMultiplier(g, 0, @intCast(std.math.clamp(a, 0, 255))),
        else => return false,
    }
    savePrev();
    return true;
}

// ------------------------------------------------------------------ game

/// Starts a session on the loaded map: the sim spawns its ambient cars and
/// peds, and player slot 0 joins (on a random pavement cell, or at block
/// `hint_x`, `hint_y` when `hint` is set).
export fn gameStart(seed: u32, hint: bool, hint_x: u32, hint_y: u32) i32 {
    const g = grid orelse return setError("start", error.NoMap);
    game.init(g, .{ .seed = seed, .mode = .authoritative });
    // With the map's main script added (`scriptAdd`), only its car shops
    // come into deathmatch: the script itself does not run here.
    if (script_count > 0) {
        loadScripts() catch |e| return setError("script", e);
        level_dm = .{ .script = level_sp.script };
        game.attachLevel(&level_dm);
    }
    offline = .dm;
    frames = @splat(Frame.neutral(0));
    pending_len = 0;
    const arg: u32 = if (hint) sim.spawnHint(@truncate(hint_x), @truncate(hint_y)) else 0;
    queue(.{ .op = .join, .slot = 0, .arg = arg });
    savePrev();
    running = true;
    return 0;
}

/// Starts a single-player game on the loaded map, with the level's static
/// data (zones, map objects, lights and, once loaded, its script) attached.
/// Player slot 0 joins as in `gameStart`.
export fn spStart(seed: u32, hint: bool, hint_x: u32, hint_y: u32) i32 {
    const g = grid orelse return setError("start", error.NoMap);
    loadScripts() catch |e| return setError("script", e);
    level_sp.text_lengths = text_lengths;
    game_sp.init(g, .{ .seed = seed, .mode = .authoritative });
    game_sp.attachLevel(&level_sp);
    offline = .sp;
    frames = @splat(Frame.neutral(0));
    pending_len = 0;
    const arg: u32 = if (hint) sim.spawnHint(@truncate(hint_x), @truncate(hint_y)) else 0;
    queue(.{ .op = .join, .slot = 0, .arg = arg });
    savePrev();
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

/// Debug aid: adds `amount` points to `slot`'s score in offline
/// deathmatch (single player uses `spDebug` 7). Offline play only.
export fn gameAddScore(slot: u32, amount: i32) bool {
    if (!running or offline != .dm or online() or slot >= Sim.config.max_players) return false;
    game.state.players[slot].score +|= amount;
    savePrev();
    return true;
}

/// Debug and tuning aid: drops a car 1.1 blocks in front of the slot's ped,
/// facing the same way. Returns false if the player is in a car or the car
/// table is full. Changes the state, so offline play only.
export fn gameSpawnCar(slot: u32) bool {
    if (!running) return false;
    return if (offline == .sp) spawnCarFor(SimSp, &game_sp, slot) else spawnCarFor(Sim, &game, slot);
}
fn spawnCarFor(comptime S: type, g: *S, slot: u32) bool {
    if (slot >= S.config.max_players) return false;
    if (!g.playerRow(slot).car.isNone()) return false;
    const ped = g.pedOf(slot) orelse return false;
    const t = g.transformOf(ped) orelse return false;
    const a = @as(f32, @floatFromInt(t.heading)) * (std.math.tau / 65536.0);
    const d: f32 = 1.1 * @as(f32, abi.fx_one);
    const x = t.x + @as(i32, @intFromFloat(@cos(a) * d));
    const y = t.y + @as(i32, @intFromFloat(@sin(a) * d));
    _ = g.spawnCarAt(x, y, t.heading, 0) orelse return false;
    savePrev();
    return true;
}

/// Debug aid, like `gameSpawnCar`: drops pickup `kind` (a `Weapon.kind`
/// or power-up, or a vehicle weapon) a block in front of the slot's ped, or
/// a block and a half in front of its car, to drive over. Offline play only.
export fn gameSpawnPickup(slot: u32, kind: u32) bool {
    if (!running) return false;
    return if (offline == .sp) spawnPickupFor(SimSp, &game_sp, slot, kind) else spawnPickupFor(Sim, &game, slot, kind);
}
fn spawnPickupFor(comptime S: type, g: *S, slot: u32, kind: u32) bool {
    if (slot >= S.config.max_players or kind >= sim.tuning.pickup_kinds) return false;
    const ped = g.pedOf(slot) orelse return false;
    const car = g.playerRow(slot).car;
    const t = (if (car.isNone()) null else g.transformOf(car)) orelse g.transformOf(ped) orelse return false;
    const a = @as(f32, @floatFromInt(t.heading)) * (std.math.tau / 65536.0);
    const d: f32 = (if (car.isNone()) 1.0 else 1.5) * @as(f32, abi.fx_one);
    const x = t.x + @as(i32, @intFromFloat(@cos(a) * d));
    const y = t.y + @as(i32, @intFromFloat(@sin(a) * d));
    _ = g.spawnPickupAt(x, y, @intCast(kind)) orelse return false;
    savePrev();
    return true;
}

/// `max_players` I2 frames, 8 bytes each, indexed by slot. JavaScript writes
/// the frames for the next step here.
export fn framesPtr() [*]u8 {
    return @ptrCast(&frames);
}

export fn gameStep() void {
    if (!running) return;
    savePrev();
    for (&frames) |*f| f.* = f.sanitize();
    if (offline == .sp) stepFor(SimSp, &game_sp) else stepFor(Sim, &game);
}
fn stepFor(comptime S: type, g: *S) void {
    // Commands for slots the configuration lacks are dropped.
    var cmds: [pending.len]abi.Command = undefined;
    var n: usize = 0;
    for (pending[0..pending_len]) |cmd| if (cmd.slot < S.config.max_players) {
        cmds[n] = cmd;
        n += 1;
    };
    g.step(frames[0..S.config.max_players], cmds[0..n]);
    pending_len = 0;
    // Offline, the sim's game events go to JavaScript (online they come
    // from the server as I3 events).
    for (g.events()) |e| {
        if (sim_events_len == sim_events.len) break;
        sim_events[sim_events_len] = .{ .kind = @intFromEnum(e.kind), .a = e.a, .b = e.b, .c = e.c, .x = e.x, .y = e.y, .z = e.z };
        sim_events_len += 1;
    }
}

/// Game events from offline steps since the last `simEventsTake`, in the
/// I3 event layout: kind, a, b, c as u8, then x, y, z as fx i32.
pub const SimEvent = extern struct { kind: u8, a: u8, b: u8, c: u8, x: i32, y: i32, z: i32 };
var sim_events: [64]SimEvent = undefined;
var sim_events_len: usize = 0;
var sim_events_out: [64]SimEvent = undefined;
export fn simEventsTake() usize {
    const n = sim_events_len;
    @memcpy(sim_events_out[0..n], sim_events[0..n]);
    sim_events_len = 0;
    return n;
}
export fn simEventsPtr() [*]const u8 {
    return @ptrCast(&sim_events_out);
}

export fn gameTick() u32 {
    if (client) |cl| return cl.sim.tick();
    if (client_p) |cl| return cl.sim.tick();
    if (!running) return 0;
    return if (offline == .sp) game_sp.tick() else game.tick();
}

/// State hash as two u32 halves (low, high) for display.
var hash_buf: [2]u32 = undefined;
export fn gameHash() [*]const u32 {
    const h = if (!running) 0 else if (offline == .sp) game_sp.hash() else game.hash();
    hash_buf = .{ @truncate(h), @truncate(h >> 32) };
    return &hash_buf;
}

/// [active, in_car, hp, kills, deaths, respawn_timer, speed (fx), z (fx),
///  weapon, rounds (-1 unlimited), score, armour, invulnerable,
///  double_damage, fast_reload, charge, burn, car weapon (`CarWeapon`, 0
///  none), its rounds (-1 built in, never runs out), car bomb fuse ticks]
var player_buf: [20]i32 = undefined;
export fn playerInfo(slot: u32) [*]const i32 {
    player_buf = @splat(0);
    if (slot >= max_players) return &player_buf;
    if (client) |cl| return playerInfoFor(Sim, cl.sim, slot);
    if (client_p) |cl| return playerInfoFor(SimP, cl.sim, slot);
    if (!running) return &player_buf;
    return if (offline == .sp) playerInfoFor(SimSp, &game_sp, slot) else playerInfoFor(Sim, &game, slot);
}
fn playerInfoFor(comptime S: type, g: *S, slot: u32) [*]const i32 {
    if (slot >= S.config.max_players) return &player_buf;
    const row = g.playerRow(slot).*;
    player_buf[0] = @intFromBool(row.flags & abi.PlayerRow.flag_active != 0);
    player_buf[1] = @intFromBool(!row.car.isNone());
    player_buf[3] = row.kills;
    player_buf[10] = row.score;
    player_buf[4] = row.deaths;
    player_buf[5] = @bitCast(row.respawn_timer);
    if (readComp(sim.c.Vehicle, g.stateBytes(), row.car)) |v| {
        const TC = sim.tuning_career;
        const fitted = v.arm != 0 and v.arm < TC.car_weapon_kinds and (v.arm_ammo > 0 or v.bomb_fuse > 0);
        if (fitted) {
            player_buf[17] = v.arm;
            player_buf[18] = @divTrunc(@as(i32, v.arm_ammo) + 9, 10);
        } else {
            const b = TC.builtinCarWeapon(v.model);
            if (b != .none) {
                player_buf[17] = @intFromEnum(b);
                player_buf[18] = -1;
            }
        }
        player_buf[19] = v.bomb_fuse;
    }
    const t = list.target(curLayout(), g.stateBytes(), slot);
    if (t.found != 0) {
        player_buf[6] = @intFromFloat(@sqrt(t.vx * t.vx + t.vy * t.vy) * @as(f32, abi.fx_one));
        player_buf[7] = @intFromFloat(t.z * @as(f32, abi.fx_one));
    }
    if (!row.ped.isNone()) {
        player_buf[2] = healthOf(g, row.ped);
        if (readComp(sim.c.Weapon, g.stateBytes(), row.ped)) |wp| {
            var w = wp;
            const k = @min(w.kind, sim.tuning.weapon_count - 1);
            player_buf[8] = k;
            const r = w.rounds()[k];
            // Ammo is kept in tenths; show whole rounds, rounding up.
            player_buf[9] = if (r == sim.tuning.infinite_ammo) -1 else @divTrunc(@as(i32, r) + 9, 10);
        }
        if (readComp(sim.c.Pedestrian, g.stateBytes(), row.ped)) |p| {
            player_buf[11] = p.armour;
            player_buf[12] = p.invulnerable;
            player_buf[13] = p.double_damage;
            player_buf[14] = p.fast_reload;
            player_buf[15] = p.charge;
            player_buf[16] = p.burn;
        }
    }
    return &player_buf;
}

fn healthOf(g: anytype, id: abi.EntityId) i32 {
    for (curViews()) |v| {
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
export fn buildList(alpha: f32, now_ms: f64) usize {
    if (client) |cl| return buildOnline(cl, &layout, now_ms);
    if (client_p) |cl| return buildOnline(cl, &layout_p, now_ms);
    if (!running) return 0;
    const n = list.build(curLayout(), prevState(), curState(), alpha, bases(), &instances);
    soundSources(curState());
    return decorate(curState(), n, now_ms, 0);
}

fn buildOnline(cl: anytype, lay: *const list.Layout, now_ms: f64) usize {
    if (!cl.started) return 0;
    const st = cl.renderState(net_now);
    const n = list.build(lay, null, st, 1, bases(), &instances);
    soundSources(st);
    return decorate(st, n, now_ms, cl.own_slot);
}

// ------------------------------------------------------------------ effects

/// Code-object sprite numbers (relative to the style's code_obj group),
/// picked by eye from the player's own styles; the same in all three
/// districts. Pickups spin through 8 frames from their first.
const spr = struct {
    const bullet: u16 = 15;
    const rocket: u16 = 403;
    const explosion_first: u16 = 327;
    const explosion_frames: u16 = 15;
    const explosion_ms: f64 = 900;
    const fire_first: u16 = 380;
    const fire_frames: u16 = 10;
    /// A fire on the ground (a molotov's).
    const ground_fire_first: u16 = 453;
    const ground_fire_frames: u16 = 12;
    /// An electric arc.
    const arc_first: u16 = 480;
    const arc_frames: u16 = 16;
    /// Spinning pickups, in `Weapon.kind` order: pistol (unused), machine
    /// gun, shotgun, rockets, dual pistols, silenced machine gun,
    /// flamethrower, electro gun, grenades, molotovs; then health, armour,
    /// invulnerability, double damage, fast reload; then the vehicle
    /// weapons (collectables 15-18): car bomb, oil, mines, machine guns.
    const pickup_first = [sim.tuning.pickup_kinds]u16{ 18, 26, 66, 34, 98, 90, 82, 42, 58, 50, 167, 175, 199, 207, 215, 110, 118, 126, 134 };
    /// Vehicle weapon shots (`Projectile.weapon`, tuning `car_shot_base` +
    /// kind - 1): the tank's rocket, the fire truck's water, the
    /// flamethrower's flame. The guns' bullets are plain bullets.
    const car_shot_tank: u8 = T.car_shot_base + 2;
    const car_shot_water: u8 = T.car_shot_base + 3;
    const car_shot_flame: u8 = T.car_shot_base + 4;
    /// A water cannon's spray, picked by eye: a pale cyan streak.
    const water_first: u16 = 418;
    const water_frames: u16 = 8;
    const pickup_frames: u16 = 8;

    /// The code-object sprite of collectable n (0-44), the order the public
    /// script docs number them (COLLECT_00 pistol .. COLLECT_40 instant
    /// gang), matched to the style by eye: hand weapons 0-10 spin through
    /// 8 frames from 18; the empty slots 11-14 are the yellow letters L-O
    /// (one frame); car weapons 15-18 spin from 110; 19-27 are the blue
    /// letters E-M; power-ups 28-40 spin from 151 (multiplier, life,
    /// health, armour, jail card, bribe, invulnerability, double damage,
    /// fast reload, electrofingers, respect, invisibility, instant gang).
    /// Past 40 the docs list nothing: drawn as the last letter.
    fn collect(n: u16, t: u16) u16 {
        if (n <= 10) return 18 + n * 8 + t % 8;
        if (n <= 14) return 106 + (n - 11);
        if (n <= 18) return 110 + (n - 15) * 8 + t % 8;
        if (n <= 27) return 142 + (n - 19);
        if (n <= 40) return 151 + (n - 28) * 8 + t % 8;
        return 150;
    }
    /// Traffic light lamps: 18x4 lit bars in red, green and amber, the
    /// last three code objects in all three districts' styles.
    const lamp_red: u16 = 549;
    const lamp_green: u16 = 550;
    const lamp_amber: u16 = 551;
    /// Thrown grenade and molotov in flight: the pickup's first frame.
    const grenade: u16 = 58;
    const molotov: u16 = 50;

    /// Ped frames within the ped group, picked by eye from the style: 8-frame
    /// walk and run cycles, the same holding a gun, a 12-frame idle, an
    /// 8-frame jump, aiming while standing, lying knocked down, and the
    /// electrocuted skeleton.
    const ped_walk: u16 = 0;
    const ped_run: u16 = 8;
    const ped_walk_gun: u16 = 37;
    const ped_run_gun: u16 = 45;
    const ped_idle: u16 = 53;
    const ped_idle_frames: u16 = 12;
    const ped_jump: u16 = 65;
    const ped_aim: u16 = 139;
    const ped_aim_frames: u16 = 4;
    const ped_fall: u16 = 81;
    const ped_down: u16 = 89;
    const ped_shocked: u16 = 152;

    /// Ped remaps (within the style's ped remap group) that read as
    /// everyday clothes, picked by eye from the player's own styles; the
    /// bright ones are left for gangs and scripts. Used for peds the sim
    /// gives no remap, spread by entity index.
    const civilian_remaps = [_]u8{ 0, 1, 2, 3, 4, 5, 9, 10, 11, 12, 13, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 35, 36, 37, 38, 39, 40, 41, 42, 43, 47, 48, 49, 51 };
    fn civilianRemap(index: u32) u32 {
        return civilian_remaps[(index *% 7 +% 3) % civilian_remaps.len];
    }
    const ped_shocked_frames: u16 = 4;
    const ped_cycle: u16 = 8;
};

/// The frame of the ped group to draw for ped `p` holding `wp`; `t` counts
/// 70 ms steps, offset per ped so crowds do not step in time.
fn pedFrame(p: sim.c.Pedestrian, wp: ?sim.c.Weapon, t: u16) u16 {
    const P = sim.c.Pedestrian;
    if (p.shock >= sim.tuning.shock_threshold / 2) return spr.ped_shocked + t % spr.ped_shocked_frames;
    // The animations C, D1 and D2 report (pedestrian.zig `anim_*`); frames
    // reuse the ones picked above (ours until the animation note lands).
    switch (p.anim) {
        P.anim_electrocuted => return spr.ped_shocked + t % spr.ped_shocked_frames,
        // Falling from a height: the fall frames by ticks fallen.
        P.anim_fall => return spr.ped_fall + @min(p.fall / 2, spr.ped_cycle - 1),
        // Drowning: thrashing through the fall frames.
        P.anim_drown => return spr.ped_fall + (t / 2) % spr.ped_cycle,
        P.anim_get_up => return spr.ped_fall + spr.ped_cycle - 1 - @min(t % 16, spr.ped_cycle - 1),
        P.anim_lie => return spr.ped_down,
        P.anim_punch => return spr.ped_aim + t % spr.ped_aim_frames,
        P.anim_enter_car, P.anim_exit_car => return spr.ped_walk + t % spr.ped_cycle,
        P.anim_burning => return spr.ped_run + t % spr.ped_cycle,
        else => {},
    }
    if (p.state != P.state_up or p.anim == P.anim_down) {
        // Thrown: falling back; at rest: lying.
        return if (p.down == 0) spr.ped_fall + @min(t % 16, spr.ped_cycle - 1) else spr.ped_down;
    }
    var armed = false;
    var firing = false;
    if (wp) |w0| {
        var w = w0;
        const r = w.rounds()[@min(w.kind, sim.tuning.weapon_count - 1)];
        armed = r > 0;
        firing = armed and w.cooldown > 0;
    }
    return switch (p.anim) {
        P.anim_walk => (if (armed) spr.ped_walk_gun else spr.ped_walk) + t % spr.ped_cycle,
        P.anim_run => (if (armed) spr.ped_run_gun else spr.ped_run) + t % spr.ped_cycle,
        P.anim_jump => spr.ped_jump + @min(t % 16, spr.ped_cycle - 1),
        else => if (firing) spr.ped_aim + t % spr.ped_aim_frames else if (armed) spr.ped_aim else spr.ped_idle + (t / 3) % spr.ped_idle_frames,
    };
}

/// The sprite of map object `o` within the style's map-object group: its
/// model's first sprite (OBJI) plus a frame. Phones flash while ringing,
/// other many-sprite models cycle (ours until the objects note says how
/// each animates). Doors are wall faces (`doorFaces`), not sprites.
fn objectFrame(s: *const formats.sty.Style, o: sim.c.Object, t: u16) u16 {
    const K = sim.ids.ObjectKind;
    const info = s.objectSprites(o.model) orelse return 0;
    if (info.count <= 1) return info.first;
    if (@as(K, @enumFromInt(o.kind)) == .phone) {
        return info.first + if (o.state & 1 != 0) (t / 4) % info.count else 0;
    }
    return info.first + (t / 2) % info.count;
}

/// A traffic light's lamps: the lit bar for what its lights show now (red,
/// green or amber code-object sprite), lying across the lane at the top of
/// the light's gantry (the map blocks over the stop line), drawn lit. The
/// sim places one lamp object per side of the light, at its first approach
/// lane; the other approach lanes on that side get the same lamp here, so
/// each lane's head on the gantry lights up. Extra lamps go at
/// `instances[n.*..]`.
fn lampLook(in: *list.Instance, o: sim.c.Object, code: u32, n: *usize) void {
    if (!isSp()) {
        in.kind = hidden_kind;
        return;
    }
    // `value` 0 is the north-south lamp, 1 the east-west one (sys/lights.zig).
    const shows = SimSp.lights.phase(game_sp.state.sp.lights.cycle, o.value == 0);
    in.sprite = @intCast(code + switch (shows) {
        .green => spr.lamp_green,
        .amber => spr.lamp_amber,
        else => spr.lamp_red,
    });
    in.palette = list.Instance.own_palette;
    in.flags |= list.Instance.flag_glow;
    in.kind = list.Instance.kind_effect;
    const bx: i32 = @intFromFloat(@floor(in.x));
    const by: i32 = @intFromFloat(@floor(in.y));
    // The lamp stands on the approach block next to the light's zone; `d`
    // is the way traffic heads into the zone.
    const steps = [4][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    const d = for (steps) |st| {
        if (level_sp.zoneAt(.traffic_light, bx + st[0], by + st[1]) != null) break st;
    } else {
        lampAt(in, bx, by, .{ 0, 0 });
        return;
    };
    const base = in.*;
    lampAt(in, bx, by, d);
    const arrow: u4 = if (d[0] > 0) sim.map.Arrow.pos_x else if (d[0] < 0) sim.map.Arrow.neg_x else if (d[1] > 0) sim.map.Arrow.pos_y else sim.map.Arrow.neg_y;
    for ([2]i32{ 1, -1 }) |sign| {
        var k: i32 = 1;
        while (k < 8 and n.* < instances.len) : (k += 1) {
            const x = bx + sign * k * d[1];
            const y = by + sign * k * d[0];
            if (level_sp.zoneAt(.traffic_light, x + d[0], y + d[1]) == null or !approach(x, y, arrow)) break;
            var extra = base;
            extra.x += @floatFromInt(x - bx);
            extra.y += @floatFromInt(y - by);
            lampAt(&extra, x, y, d);
            instances[n.*] = extra;
            n.* += 1;
        }
    }
}

/// Puts lamp `in` (on block bx, by) on the far edge of its block from the
/// light's zone, where the gantry's arm runs, just above the column's top.
fn lampAt(in: *list.Instance, bx: i32, by: i32, d: [2]i32) void {
    in.x -= @as(f32, @floatFromInt(d[0])) * 0.45;
    in.y -= @as(f32, @floatFromInt(d[1])) * 0.45;
    const m = &(map orelse return);
    var z: i32 = formats.gmp.size_z - 1;
    while (z >= 0) : (z -= 1) {
        if (!m.getOrAir(bx, by, z).isAir()) break;
    }
    if (z + 1 > @as(i32, @intFromFloat(@floor(in.z)))) in.z = @as(f32, @floatFromInt(z + 1)) + 0.02;
}

/// Is the highest road block at (x, y) an approach lane, its arrows
/// including `arrow` (as sys/lights.zig picks the first one)?
fn approach(x: i32, y: i32, arrow: u4) bool {
    const g = grid orelse return false;
    if (x < 0 or y < 0 or x >= sim.map.size_x or y >= sim.map.size_y) return false;
    var z: i32 = sim.map.size_z - 1;
    while (z >= 0) : (z -= 1) {
        const c = sim.map.cellAt(g, x, y, z);
        if (sim.map.shapeOf(c) == sim.map.Shape.air) continue;
        return sim.map.groundOf(c) == sim.map.Ground.road and sim.map.arrowsOf(c) & arrow != 0;
    }
    return false;
}

/// Door leaves as wall faces, rebuilt each frame from the doors' current
/// frames: a door's animation frames are tile numbers, closed to open
/// (type 230), drawn on the door's block face. A double door's second leaf
/// is on the next block along the wall, mirrored. Which way along the wall
/// is read from the player's own maps: of the two blocks beside a double
/// door's block, it is the one that is open (south face: west; north
/// face: east; east face: south; west face: north).
var door_verts: [door_vert_cap]mesh.Vertex = undefined;
const door_vert_cap = @typeInfo(@TypeOf(game_sp.state.sp.objects.doors)).array.len * 2 * 6;
export fn doorFaces() usize {
    if (!isSp() or style == null) return 0;
    const s = &game_sp.state.sp.objects;
    var out: std.ArrayList(mesh.Vertex) = .initBuffer(&door_verts);
    for (&s.doors) |*d| {
        if (d.obj.isNone() or game_sp.state.world.get(d.obj, sim.c.Object) == null) continue;
        if (d.frame == 0 or d.frame >= 1023) continue;
        const side: mesh.Side = @enumFromInt(@min(d.face, 3));
        const flip = d.flags & DoorRec.flag_flip != 0;
        mesh.doorFace(&out, d.bx, d.by, d.bz, side, @intCast(d.frame), flip) catch break;
        if (d.flags & DoorRec.flag_double != 0) {
            const step: [2]i32 = switch (side) {
                .south => .{ -1, 0 },
                .north => .{ 1, 0 },
                .east => .{ 0, 1 },
                .west => .{ 0, -1 },
            };
            const x2 = @as(i32, d.bx) + step[0];
            const y2 = @as(i32, d.by) + step[1];
            if (x2 < 0 or y2 < 0 or x2 > 255 or y2 > 255) continue;
            mesh.doorFace(&out, @intCast(x2), @intCast(y2), d.bz, side, @intCast(d.frame), !flip) catch break;
        }
    }
    return out.items.len;
}
/// Tyre marks as triangles (x, y, z, opacity per vertex); the vertex count.
export fn skidMarks(now_ms: f64) usize {
    return skids.build(now_ms);
}
export fn skidMarksPtr() [*]const f32 {
    return skids.ptr();
}

export fn doorFacesPtr() [*]const u8 {
    return @ptrCast(&door_verts);
}
const DoorRec = @TypeOf(game_sp.state.sp.objects.doors[0]);

/// `Instance.kind` marking an instance `decorate` drops.
const hidden_kind = 0xFF;

const Effect = struct { x: f32, y: f32, z: f32, t0: f64 };
var effects: [32]Effect = undefined;
var effects_next: usize = 0;
var effects_len: usize = 0;

/// Adds an explosion at fx position (x, y, z), from an I3 or offline event.
export fn effectExplosion(x: i32, y: i32, z: i32, now_ms: f64) void {
    const f: f32 = 1.0 / @as(f32, abi.fx_one);
    effects[effects_next] = .{ .x = @as(f32, @floatFromInt(x)) * f, .y = @as(f32, @floatFromInt(y)) * f, .z = @as(f32, @floatFromInt(z)) * f, .t0 = now_ms };
    effects_next = (effects_next + 1) % effects.len;
    effects_len = @min(effects_len + 1, effects.len);
}

fn columnOf(kind: abi.Kind, comp: abi.ComponentId) ?abi.ColumnDesc {
    for (curViews()) |v| {
        if (v.kind == @intFromEnum(kind) and v.component == @intFromEnum(comp)) return v;
    }
    return null;
}

/// A component of entity `id` read from a state buffer (sim or render).
fn readComp(comptime C: type, state: []const u8, id: abi.EntityId) ?C {
    if (id.isNone() or id.kind() > @intFromEnum(abi.Kind.map_object)) return null;
    const v = columnOf(@enumFromInt(id.kind()), C.id) orelse return null;
    return readAt(C, state, v, id.index());
}
fn readAt(comptime C: type, state: []const u8, v: abi.ColumnDesc, i: u32) ?C {
    if (i >= v.count) return null;
    const off = v.offset + i * v.stride;
    if (off + @sizeOf(C) > state.len) return null;
    return std.mem.bytesToValue(C, state[off..][0..@sizeOf(C)]);
}

/// Sprites the plain list cannot know: rounds by weapon, spinning pickups,
/// fire on burning cars, dark wrecks, explosions. Also watches for shots,
/// hits and weapon changes, for sound.
fn decorate(state: []const u8, n_in: usize, now_ms: f64, own_slot: u32) usize {
    const s = &(style orelse return n_in);
    const code = s.sprite_base.base(.code_obj);
    var n = n_in;
    const frame16: u16 = @truncate(@as(u64, @intFromFloat(@max(0, now_ms))) / 70);
    const proj_col = columnOf(.projectile, .projectile);
    const pick_col = columnOf(.pickup, .appearance);
    const veh_col = columnOf(.car, .vehicle);
    const ped_col = columnOf(.ped, .pedestrian);
    const wpn_col = columnOf(.ped, .weapon);
    const obj_col = columnOf(.map_object, .object);
    const car_vel_col = columnOf(.car, .velocity);
    skids.beginFrame();
    for (instances[0..n_in]) |*in| {
        switch (in.kind) {
            @intFromEnum(abi.Kind.projectile) => {
                const p = readAt(sim.c.Projectile, state, proj_col orelse continue, in.index) orelse continue;
                if (p.weapon == sim.c.Projectile.explosion_bit | T.explosion_fire) {
                    // A fire on the ground burns where it is.
                    in.sprite = @intCast(code + spr.ground_fire_first + (frame16 +% in.index) % spr.ground_fire_frames);
                    in.angle = 0;
                    in.kind = list.Instance.kind_effect;
                } else if (p.weapon & sim.c.Projectile.explosion_bit != 0) {
                    // Drawn from its event (`effectExplosion`); dropped below.
                    in.kind = hidden_kind;
                    continue;
                } else in.sprite = @intCast(code + switch (p.weapon) {
                    T.weapon_rocket, spr.car_shot_tank => spr.rocket,
                    T.weapon_flamethrower, spr.car_shot_flame => spr.fire_first + (frame16 +% in.index) % spr.fire_frames,
                    spr.car_shot_water => spr.water_first + (frame16 +% in.index) % spr.water_frames,
                    T.weapon_electro => spr.arc_first + (frame16 +% in.index) % spr.arc_frames,
                    T.weapon_grenade => spr.grenade,
                    T.weapon_molotov => spr.molotov,
                    else => spr.bullet,
                });
                in.flags |= list.Instance.flag_glow;
                in.palette = list.Instance.own_palette;
            },
            @intFromEnum(abi.Kind.pickup) => {
                const a = readAt(abi.Appearance, state, pick_col orelse continue, in.index) orelse continue;
                const what = @min(a.sprite, sim.tuning.pickup_kinds - 1);
                in.sprite = @intCast(code + spr.pickup_first[what] + frame16 / 2 % spr.pickup_frames);
                in.angle = 0;
                in.flags |= list.Instance.flag_glow;
            },
            @intFromEnum(abi.Kind.ped) => {
                const p = readAt(sim.c.Pedestrian, state, ped_col orelse continue, in.index) orelse continue;
                const wp = if (wpn_col) |wc| readAt(sim.c.Weapon, state, wc, in.index) else null;
                in.sprite +%= pedFrame(p, wp, frame16 +% in.index *% 3);
                // A ped sprite's own palette leaves the arms in a marker
                // green: peds are only meant to be drawn through a ped
                // remap. Peds the sim gives no remap get an everyday one.
                if (in.palette == list.Instance.own_palette)
                    in.palette = @intCast(s.palette_base.base(.ped_remap) + spr.civilianRemap(in.index));
                if (p.burn > 0 and n < instances.len) {
                    instances[n] = .{ .x = in.x, .y = in.y, .z = in.z, .angle = 0, .sprite = @intCast(code + spr.fire_first + (frame16 +% in.index) % spr.fire_frames), .palette = list.Instance.own_palette, .kind = list.Instance.kind_effect, .flags = list.Instance.flag_glow };
                    n += 1;
                }
            },
            @intFromEnum(abi.Kind.map_object) => {
                // Oil and mines everywhere; the city's own objects in single
                // player and police rooms.
                const o = readAt(sim.c.Object, state, obj_col orelse continue, in.index) orelse continue;
                switch (@as(sim.ids.ObjectKind, @enumFromInt(o.kind))) {
                    // Traffic AI markers are not drawn. Doors are drawn as
                    // wall faces (`doorFaces`), not sprites.
                    .crossing_marker, .traffic_light, .door, .crane => {
                        in.kind = hidden_kind;
                        continue;
                    },
                    .lamp => {
                        lampLook(in, o, code, &n);
                        continue;
                    },
                    else => {},
                }
                // Weapon and power-up pickups (models 200-244 and 64-108,
                // script-objects.md 4) are code objects, spinning.
                if (o.model >= 200 and o.model <= 244 or o.model >= 64 and o.model <= 108) {
                    const what: u16 = if (o.model >= 200) o.model - 200 else o.model - 64;
                    in.sprite = @intCast(code + spr.collect(what, frame16 / 2 +% in.index));
                    in.palette = list.Instance.own_palette;
                    in.flags |= list.Instance.flag_glow;
                    in.angle = 0;
                    continue;
                }
                // Other models are style map objects (OBJI). Script object
                // types the style has no entry for are not drawn rather
                // than drawn as another object's sprite.
                if (s.objectSprites(o.model) == null) {
                    in.kind = hidden_kind;
                    continue;
                }
                in.sprite = @intCast(s.sprite_base.base(.map_obj) + objectFrame(s, o, frame16 +% in.index));
            },
            @intFromEnum(abi.Kind.car) => {
                const v = readAt(sim.c.Vehicle, state, veh_col orelse continue, in.index) orelse continue;
                if (car_vel_col) |vc| if (readAt(abi.Velocity, state, vc, in.index)) |vel| {
                    const m = sim.tuning.carModel(v.model);
                    const per: f32 = 1.0 / @as(f32, abi.fx_one);
                    const out_of_play = sim.c.Vehicle.flag_wrecked | sim.c.Vehicle.flag_in_water | sim.c.Vehicle.flag_crushed;
                    skids.track(.{
                        .slot = in.index,
                        .gen = 0,
                        .x = in.x,
                        .y = in.y,
                        .z = in.z,
                        // The drawn angle is turned half round (list.zig).
                        .angle = in.angle - std.math.pi,
                        .vx = @as(f32, @floatFromInt(vel.vx)) * per,
                        .vy = @as(f32, @floatFromInt(vel.vy)) * per,
                        .half_len = @as(f32, @floatFromInt(m.half_len)) * per,
                        .half_wid = @as(f32, @floatFromInt(m.half_wid)) * per,
                        .brake = v.brake,
                        .handbrake = v.flags & sim.c.Vehicle.flag_handbrake != 0,
                        .grounded = v.flags & out_of_play == 0 and @abs(vel.vz) < abi.fx_one / 64,
                        .ai = v.flags & sim.c.Vehicle.flag_ai != 0,
                    }, now_ms);
                };
                if (v.flags & sim.c.Vehicle.flag_wrecked != 0) {
                    in.flags |= list.Instance.flag_dark;
                    in.palette = list.Instance.own_palette;
                }
                if (v.flags & sim.c.Vehicle.flag_burning != 0 and n < instances.len) {
                    instances[n] = .{ .x = in.x, .y = in.y, .z = in.z, .angle = 0, .sprite = @intCast(code + spr.fire_first + (frame16 +% in.index) % spr.fire_frames), .palette = list.Instance.own_palette, .kind = list.Instance.kind_effect, .flags = list.Instance.flag_glow };
                    n += 1;
                }
            },
            else => {},
        }
    }
    // Drop hidden instances, keeping the order of the rest.
    var kept: usize = 0;
    for (0..n) |i| {
        if (instances[i].kind == hidden_kind) continue;
        instances[kept] = instances[i];
        kept += 1;
    }
    n = kept;
    for (effects[0..effects_len]) |e| {
        const age = now_ms - e.t0;
        if (age < 0 or age >= spr.explosion_ms or n >= instances.len) continue;
        const fr: u16 = @intFromFloat(age / spr.explosion_ms * @as(f64, spr.explosion_frames));
        instances[n] = .{ .x = e.x, .y = e.y, .z = e.z, .angle = 0, .sprite = @intCast(code + spr.explosion_first + fr), .palette = list.Instance.own_palette, .kind = list.Instance.kind_effect, .flags = list.Instance.flag_glow };
        n += 1;
    }
    watch(state, own_slot);
    return n;
}

// ------------------------------------------------------------------ sound cues

/// What the watcher saw since the last `cuesTake`: kind, a (weapon), and a
/// position in blocks.
pub const Cue = extern struct { kind: u32, a: u32, x: f32, y: f32, z: f32, _pad: u32 = 0 };
pub const cue_shot: u32 = 1;
pub const cue_hurt_ped: u32 = 2;
pub const cue_hurt_car: u32 = 3;
pub const cue_switch: u32 = 4;
// What AI peds and drivers do that has a voice. Seen here, on the client,
// from state changes; the sim has no events for them.
pub const cue_ped_panic: u32 = 5;
pub const cue_ped_bumped: u32 = 6;
pub const cue_carjacked: u32 = 7;
// 8 was the cop shout; the sim now sends police voices itself (event 19).
pub const cue_mugger: u32 = 9;
pub const cue_gang_shout: u32 = 10;
pub const cue_elvis: u32 = 11;
pub const cue_driver_angry: u32 = 12;
/// A car hurt by another car (a collision), a = the health it lost.
pub const cue_car_hit: u32 = 13;
var cues: [64]Cue = undefined;
var cues_len: usize = 0;
var cues_out: [64]Cue = undefined;
export fn cuesTake() usize {
    const n = cues_len;
    @memcpy(cues_out[0..n], cues[0..n]);
    cues_len = 0;
    return n;
}
export fn cuesPtr() [*]const u8 {
    return @ptrCast(&cues_out);
}
fn cue(kind: u32, a: u32, t: abi.Transform) void {
    if (cues_len == cues.len) return;
    const f: f32 = 1.0 / @as(f32, abi.fx_one);
    cues[cues_len] = .{ .kind = kind, .a = a, .x = @as(f32, @floatFromInt(t.x)) * f, .y = @as(f32, @floatFromInt(t.y)) * f, .z = @as(f32, @floatFromInt(t.z)) * f };
    cues_len += 1;
}

const max_proj = @max(Sim.config.projectile_capacity, SimSp.config.projectile_capacity);
const max_body = @max(Sim.config.car_capacity, Sim.config.ped_capacity, SimSp.config.car_capacity, SimSp.config.ped_capacity);
var seen_proj_gen: [max_proj]u16 = @splat(0xFFFF);
var seen_hp: [2][max_body]i32 = @splat(@splat(0));
var seen_gen: [2][max_body]u16 = @splat(@splat(0xFFFF));
var own_cooldown: u16 = 0;
var own_weapon: u8 = 0;
var own_ped: abi.EntityId = .none;
var seen_ped_gen: [max_body]u16 = @splat(0xFFFF);
var seen_ped_state: [max_body]u8 = @splat(0);
var seen_ped_internal: [max_body]u8 = @splat(0);
var seen_ped_on_player: [max_body]bool = @splat(false);

// ------------------------------------------------------------------ sound sources

/// What keeps sounding, refreshed each render frame: a car (kind 1, `extra`
/// 1 when someone drives it) or a player on foot (kind 2, `extra` the walk
/// animation in bits 0-7 and the ground under them in bits 8-9: 0 none,
/// 1 road, 2 pavement, 3 field; bit 10 set when standing in water). Blocks
/// and blocks per tick.
pub const SoundSource = extern struct { kind: u32, id: u32, x: f32, y: f32, z: f32, speed: f32, extra: u32, _pad: u32 = 0 };
pub const sound_car: u32 = 1;
pub const sound_walker: u32 = 2;
var sound_src: [160]SoundSource = undefined;
var sound_len: usize = 0;
export fn soundSourcesLen() usize {
    return sound_len;
}
export fn soundSourcesPtr() [*]const u8 {
    return @ptrCast(&sound_src);
}

fn soundSources(state: []const u8) void {
    sound_len = 0;
    const f: f32 = 1.0 / @as(f32, abi.fx_one);
    // Cars: every live one that is driven or moving.
    const tc = columnOf(.car, .transform);
    const vc = columnOf(.car, .velocity);
    const hc = columnOf(.car, .vehicle);
    const slots = for (curViews()) |v| {
        if (v.kind == @intFromEnum(abi.Kind.car) and v.component == abi.ColumnDesc.Special.slot) break v;
    } else null;
    if (tc != null and slots != null) for (0..slots.?.count) |i| {
        if (sound_len == sound_src.len - 8) break;
        if (state[slots.?.offset + i] != 1) continue;
        const t = readAt(abi.Transform, state, tc.?, @intCast(i)) orelse continue;
        const v = if (vc) |c| readAt(abi.Velocity, state, c, @intCast(i)) orelse std.mem.zeroes(abi.Velocity) else std.mem.zeroes(abi.Velocity);
        const driven = if (hc) |c| if (readAt(sim.c.Vehicle, state, c, @intCast(i))) |veh| !veh.driver.isNone() else false else false;
        const vx = @as(f32, @floatFromInt(v.vx)) * f;
        const vy = @as(f32, @floatFromInt(v.vy)) * f;
        const speed = @sqrt(vx * vx + vy * vy);
        if (!driven and speed < 0.004) continue;
        sound_src[sound_len] = .{ .kind = sound_car, .id = @intCast(i), .x = @as(f32, @floatFromInt(t.x)) * f, .y = @as(f32, @floatFromInt(t.y)) * f, .z = @as(f32, @floatFromInt(t.z)) * f, .speed = speed, .extra = @intFromBool(driven) };
        sound_len += 1;
    };
    // Players on foot, with the ground under their feet.
    const rows = for (curViews()) |v| {
        if (v.component == abi.ColumnDesc.Special.player_rows) break v;
    } else null;
    if (rows) |rv| for (0..@min(rv.count, max_players)) |slot| {
        const row = readAt(abi.PlayerRow, state, rv, @intCast(slot)) orelse continue;
        if (row.flags & abi.PlayerRow.flag_active == 0 or row.ped.isNone() or !row.car.isNone()) continue;
        const t = readComp(abi.Transform, state, row.ped) orelse continue;
        const p = readComp(sim.c.Pedestrian, state, row.ped) orelse continue;
        var ground: u32 = 0;
        if (grid) |g| {
            const cell = sim.map.floorCell(g, t.x, t.y, t.z, sim.tuning.ped_step);
            ground = sim.map.groundOf(cell);
            const here = sim.map.cellAt(g, sim.fx.toInt(t.x), sim.fx.toInt(t.y), sim.fx.toInt(t.z));
            if (sim.map.shapeOf(here) == sim.map.Shape.water) ground |= 4;
        }
        sound_src[sound_len] = .{ .kind = sound_walker, .id = @intCast(slot), .x = @as(f32, @floatFromInt(t.x)) * f, .y = @as(f32, @floatFromInt(t.y)) * f, .z = @as(f32, @floatFromInt(t.z)) * f, .speed = 0, .extra = p.anim | (ground << 8) };
        sound_len += 1;
    };
}

fn isPlayerPed(players: []const abi.EntityId, id: abi.EntityId) bool {
    for (players) |p| if (sim.ecs.eql(p, id)) return true;
    return false;
}

/// Voices from AI peds: a ped knocked over without being hurt, pulled out of
/// a car, starting to flee, or turning on a player (by occupation:
/// muggers, gang members, Elvis). Objectives exist only in single-player
/// state; without them only the first two are heard.
fn watchPeds(state: []const u8, players: []const abi.EntityId) void {
    const pc = columnOf(.ped, .pedestrian) orelse return;
    const tc = columnOf(.ped, .transform) orelse return;
    const hc = columnOf(.ped, .health);
    const oc = columnOf(.ped, .objective);
    const gens = for (curViews()) |v| {
        if (v.kind == @intFromEnum(abi.Kind.ped) and v.component == abi.ColumnDesc.Special.generation) break v;
    } else return;
    const slots = for (curViews()) |v| {
        if (v.kind == @intFromEnum(abi.Kind.ped) and v.component == abi.ColumnDesc.Special.slot) break v;
    } else return;
    // Internal objective kinds that mean fleeing (flee_ped, flee_till_safe,
    // flee_ped_always, flee_on_car_stop in sim/ai/objectives.zig).
    const flee_kinds = [_]u8{ 7, 8, 17, 18 };
    const Occ = sim.ids.Occupation;
    for (0..@min(pc.count, max_body)) |i| {
        if (state[slots.offset + i] != 1) continue;
        const g = readAt(u16, state, gens, @intCast(i)) orelse continue;
        const p = readAt(sim.c.Pedestrian, state, pc, @intCast(i)) orelse continue;
        const fresh = g != seen_ped_gen[i];
        seen_ped_gen[i] = g;
        const id = abi.EntityId.make(.ped, @intCast(i), g);
        if (isPlayerPed(players, id)) continue;
        const t = readAt(abi.Transform, state, tc, @intCast(i)) orelse continue;
        var internal: u8 = 0;
        var on_player = false;
        var occ: Occ = .civilian;
        if (oc) |c| if (readAt(sim.c.Objective, state, c, @intCast(i))) |o| {
            internal = o.internal;
            occ = @enumFromInt(o.occupation);
            const tgt = if (!o.internal_target.isNone()) o.internal_target else o.main_target;
            on_player = !tgt.isNone() and isPlayerPed(players, tgt);
        };
        defer {
            seen_ped_state[i] = p.state;
            seen_ped_internal[i] = internal;
            seen_ped_on_player[i] = on_player;
        }
        if (fresh) continue;
        if (p.state != seen_ped_state[i]) {
            if (p.state == sim.c.Pedestrian.state_pulled_out) cue(cue_carjacked, 0, t);
            const hurt = if (hc) |c| if (readAt(abi.Health, state, c, @intCast(i))) |h| h.hp < seen_hp[1][i] - 4 else false else false;
            if (p.state == sim.c.Pedestrian.state_over and !hurt) cue(cue_ped_bumped, 0, t);
        }
        if (internal != seen_ped_internal[i]) {
            const flee = std.mem.indexOfScalar(u8, &flee_kinds, internal) != null;
            if (flee and (occ == .civilian or occ == .customer or occ == .passenger or occ == .driver)) cue(cue_ped_panic, 0, t);
        }
        if (on_player and !seen_ped_on_player[i]) switch (occ) {
            .mugger => cue(cue_mugger, 0, t),
            .gang_member => cue(cue_gang_shout, 0, t),
            .elvis => cue(cue_elvis, 0, t),
            else => {},
        };
    }
}

fn watch(state: []const u8, own_slot: u32) void {
    var players: [max_players]abi.EntityId = undefined;
    var n_players: usize = 0;
    if (for (curViews()) |v| {
        if (v.component == abi.ColumnDesc.Special.player_rows) break v;
    } else null) |rv| for (0..@min(rv.count, max_players)) |slot| {
        const row = readAt(abi.PlayerRow, state, rv, @intCast(slot)) orelse continue;
        if (row.ped.isNone()) continue;
        players[n_players] = row.ped;
        n_players += 1;
    };
    watchPeds(state, players[0..n_players]);
    var own: abi.EntityId = .none;
    if (own_slot < max_players) {
        const pr_off = for (curViews()) |v| {
            if (v.component == abi.ColumnDesc.Special.player_rows) break v;
        } else null;
        if (pr_off) |v| if (readAt(abi.PlayerRow, state, v, own_slot)) |row| {
            own = row.ped;
        };
    }
    // Own shots and weapon changes, from the own ped's weapon.
    if (readComp(sim.c.Weapon, state, own)) |w| {
        const same = sim.ecs.eql(own, own_ped);
        if (same and w.cooldown > own_cooldown) {
            if (readComp(abi.Transform, state, own)) |t| cue(cue_shot, w.kind, t);
        }
        if (same and w.kind != own_weapon) {
            if (readComp(abi.Transform, state, own)) |t| cue(cue_switch, w.kind, t);
        }
        own_cooldown = w.cooldown;
        own_weapon = w.kind;
    }
    own_ped = own;
    // Everyone else's shots: projectiles that appeared, one cue per shooter.
    if (columnOf(.projectile, .projectile)) |pc| if (columnOf(.projectile, .transform)) |tc| {
        const gens = for (curViews()) |v| {
            if (v.kind == @intFromEnum(abi.Kind.projectile) and v.component == abi.ColumnDesc.Special.generation) break v;
        } else null;
        const slots = for (curViews()) |v| {
            if (v.kind == @intFromEnum(abi.Kind.projectile) and v.component == abi.ColumnDesc.Special.slot) break v;
        } else null;
        var last_owner: abi.EntityId = .none;
        if (gens != null and slots != null) for (0..@min(gens.?.count, max_proj)) |i| {
            const alive = state[slots.?.offset + i] == 1;
            if (!alive) {
                seen_proj_gen[i] = 0xFFFF;
                continue;
            }
            const g = readAt(u16, state, gens.?, @intCast(i)) orelse continue;
            if (g == seen_proj_gen[i]) continue;
            seen_proj_gen[i] = g;
            const p = readAt(sim.c.Projectile, state, pc, @intCast(i)) orelse continue;
            if (p.weapon & sim.c.Projectile.explosion_bit != 0) continue;
            if (sim.ecs.eql(p.owner, own) or sim.ecs.eql(p.owner, last_owner)) continue;
            last_owner = p.owner;
            if (readAt(abi.Transform, state, tc, @intCast(i))) |t| cue(cue_shot, p.weapon, t);
        };
    };
    // Hits: health that dropped on a car or a ped.
    inline for (.{ abi.Kind.car, abi.Kind.ped }, 0..) |kind, ki| {
        const hc = columnOf(kind, .health);
        const tc = columnOf(kind, .transform);
        const gens = for (curViews()) |v| {
            if (v.kind == @intFromEnum(kind) and v.component == abi.ColumnDesc.Special.generation) break v;
        } else null;
        const slots = for (curViews()) |v| {
            if (v.kind == @intFromEnum(kind) and v.component == abi.ColumnDesc.Special.slot) break v;
        } else null;
        if (hc != null and tc != null and gens != null and slots != null) {
            for (0..@min(hc.?.count, max_body)) |i| {
                if (state[slots.?.offset + i] != 1) continue;
                const g = readAt(u16, state, gens.?, @intCast(i)) orelse continue;
                const health = readAt(abi.Health, state, hc.?, @intCast(i)) orelse continue;
                const hp = health.hp;
                if (g == seen_gen[ki][i] and hp < seen_hp[ki][i] - 4) {
                    if (readAt(abi.Transform, state, tc.?, @intCast(i))) |t| {
                        // A car hurt by a car crashed into it; anything else
                        // (bullets, fire, blasts) is a hit.
                        const crash = ki == 0 and !health.last_hit_by.isNone() and health.last_hit_by.kind() == @intFromEnum(abi.Kind.car);
                        if (crash) cue(cue_car_hit, @intCast(@min(seen_hp[ki][i] - hp, 0xFFFF)), t) else cue(if (ki == 0) cue_hurt_car else cue_hurt_ped, 0, t);
                        // A car someone else drives, hit: its driver shouts.
                        if (ki == 0) if (columnOf(.car, .vehicle)) |vc| if (readAt(sim.c.Vehicle, state, vc, @intCast(i))) |veh| {
                            if (!veh.driver.isNone() and !isPlayerPed(players[0..n_players], veh.driver)) cue(cue_driver_angry, 0, t);
                        };
                    }
                }
                seen_gen[ki][i] = g;
                seen_hp[ki][i] = hp;
            }
        }
    }
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
    if (client_p) |cl| {
        target_buf = if (cl.started) list.target(&layout_p, cl.render, slot) else std.mem.zeroes(list.Target);
        return @ptrCast(&target_buf);
    }
    if (!running) {
        target_buf = std.mem.zeroes(list.Target);
        return @ptrCast(&target_buf);
    }
    const a = list.target(curLayout(), prevState(), slot);
    const b = list.target(curLayout(), curState(), slot);
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
const NetClientP = net.client.Client(SimP);
var client_p: ?*NetClientP = null;
/// The room has police on: `layoutHashPtr` and `netStart` use `SimP`.
var net_police = false;
fn online() bool {
    return client != null or client_p != null;
}

/// Before `layoutHashPtr` and `netStart`: whether the room has police on
/// (the host's room setting, from the join link).
export fn netPolice(on: bool) void {
    net_police = on;
}
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
    if (net_police) {
        client_p = newClient(NetClientP, g, slot, buffer_ticks) catch |e| return setError("net", e);
    } else {
        client = newClient(NetClient, g, slot, buffer_ticks) catch |e| return setError("net", e);
    }
    return 0;
}

fn newClient(comptime C: type, g: *abi.Grid, slot: u32, buffer_ticks: u32) !*C {
    const cl = try gpa.create(C);
    cl.* = C.init(gpa, g, @intCast(slot), .{ .buffer_ticks = @floatFromInt(buffer_ticks) }) catch |e| {
        gpa.destroy(cl);
        return e;
    };
    return cl;
}

export fn netStop() void {
    if (client) |cl| {
        cl.deinit();
        gpa.destroy(cl);
    }
    client = null;
    if (client_p) |cl| {
        cl.deinit();
        gpa.destroy(cl);
    }
    client_p = null;
}

/// `Sim.layout_hash` as (low, high) u32 halves, for I3 `hello`.
var layout_buf: [2]u32 = undefined;
export fn layoutHashPtr() [*]const u32 {
    const h = if (net_police) SimP.layout_hash else Sim.layout_hash;
    layout_buf = .{ @truncate(h), @truncate(h >> 32) };
    return &layout_buf;
}

/// A snapshot (datagram) or baseline (stream) body, starting at its type byte.
export fn netSnapshot(p: [*]const u8, n: usize, now_ms: f64) i32 {
    net_now = now_ms;
    if (client) |cl| return onSnapshot(cl, p[0..n], now_ms);
    if (client_p) |cl| return onSnapshot(cl, p[0..n], now_ms);
    return setError("net", error.NotStarted);
}
fn onSnapshot(cl: anytype, body: []const u8, now_ms: f64) i32 {
    cl.onSnapshot(body, now_ms) catch |e| return setError("snapshot", e);
    return 0;
}

/// Per animation frame: runs the predicted ticks that are due with the
/// frame in `framesPtr()[0]`. Returns the number of ticks run; send one
/// `netInput` datagram per tick run.
export fn netUpdate(now_ms: f64) u32 {
    net_now = now_ms;
    if (client) |cl| return cl.update(now_ms, frames[0].sanitize());
    if (client_p) |cl| return cl.update(now_ms, frames[0].sanitize());
    return 0;
}

/// Encodes the input datagram for the newest tick. Returns its length; the
/// bytes are at `netInputPtr()`.
export fn netInput(now_ms: f64) usize {
    if (client) |cl| return writeInput(cl, now_ms);
    if (client_p) |cl| return writeInput(cl, now_ms);
    return 0;
}
fn writeInput(cl: anytype, now_ms: f64) usize {
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
    if (client) |cl| statsOf(cl);
    if (client_p) |cl| statsOf(cl);
    return &net_stats;
}
fn statsOf(cl: anytype) void {
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
    const ints = [_][]const u8{ "turbo", "long", "sprite", "ambient", "steer_gain", "max_yaw", "handbrake_yaw_8ths", "pedal_rate", "steer_rate", "restitution_8ths" };
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
    T.setCarModels(loaded_models[0..loaded_count]);
    sim.tuning_career.setStandardRoles(loaded_count);
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
    try std.testing.expect(buildList(0.5, 0) > 0);
}

test "sound sources: the walking player, with their ground" {
    loadTestMap();
    try std.testing.expectEqual(@as(i32, 0), gameStart(1, false, 0, 0));
    for (0..10) |t| {
        frames[0] = .{ .steer = 0, .throttle = 127, .buttons = 0, .aim = 0, .seq = @truncate(t) };
        gameStep();
    }
    _ = buildList(1, 0);
    var walker: ?SoundSource = null;
    for (sound_src[0..sound_len]) |src| if (src.kind == sound_walker and src.id == 0) {
        walker = src;
    };
    try std.testing.expect(walker != null);
    const anim = walker.?.extra & 0xff;
    try std.testing.expect(anim == sim.c.Pedestrian.anim_walk or anim == sim.c.Pedestrian.anim_run);
    try std.testing.expect((walker.?.extra >> 8) & 3 != 0);
}

test "ped voices: a pedestrian pulled from a car is heard" {
    loadTestMap();
    try std.testing.expectEqual(@as(i32, 0), gameStart(1, false, 0, 0));
    for (0..5) |_| gameStep();
    const st = try std.testing.allocator.dupe(u8, curState());
    defer std.testing.allocator.free(st);
    const pc = columnOf(.ped, .pedestrian).?;
    const slots = for (curViews()) |v| {
        if (v.kind == @intFromEnum(abi.Kind.ped) and v.component == abi.ColumnDesc.Special.slot) break v;
    } else unreachable;
    const players = [_]abi.EntityId{};
    // An AI ped: any live slot, since no player is listed.
    const i: u32 = for (0..pc.count) |k| {
        if (st[slots.offset + k] == 1) break @intCast(k);
    } else return error.SkipZigTest;
    watchPeds(st, &players);
    cues_len = 0;
    const off = pc.offset + i * pc.stride + @offsetOf(sim.c.Pedestrian, "state");
    st[off] = sim.c.Pedestrian.state_pulled_out;
    watchPeds(st, &players);
    var heard = false;
    for (cues[0..cues_len]) |c| heard = heard or c.kind == cue_carjacked;
    try std.testing.expect(heard);
    cues_len = 0;
    // Nothing changed: nothing more is heard.
    watchPeds(st, &players);
    try std.testing.expectEqual(@as(usize, 0), cues_len);
}

test "a car hurt by another car is a crash, not a bullet hit" {
    loadTestMap();
    try std.testing.expectEqual(@as(i32, 0), gameStart(1, false, 0, 0));
    for (0..5) |_| gameStep();
    const st = try std.testing.allocator.dupe(u8, curState());
    defer std.testing.allocator.free(st);
    const hc = columnOf(.car, .health).?;
    const slots = for (curViews()) |v| {
        if (v.kind == @intFromEnum(abi.Kind.car) and v.component == abi.ColumnDesc.Special.slot) break v;
    } else unreachable;
    const i: u32 = for (0..hc.count) |k| {
        if (st[slots.offset + k] == 1) break @intCast(k);
    } else return error.SkipZigTest;
    watch(st, max_players);
    cues_len = 0;
    const off = hc.offset + i * hc.stride;
    var h = std.mem.bytesToValue(abi.Health, st[off..][0..@sizeOf(abi.Health)]);
    h.hp -= 900;
    h.last_hit_by = abi.EntityId.make(.car, (i + 1) % hc.count, 0);
    @memcpy(st[off..][0..@sizeOf(abi.Health)], std.mem.asBytes(&h));
    watch(st, max_players);
    var crash: ?Cue = null;
    for (cues[0..cues_len]) |c| {
        try std.testing.expect(c.kind != cue_hurt_car);
        if (c.kind == cue_car_hit) crash = c;
    }
    try std.testing.expectEqual(@as(u32, 900), crash.?.a);
    cues_len = 0;
}

test "tuning round trip" {
    const names = tune_names;
    try std.testing.expect(std.mem.indexOf(u8, names, "car.max_speed:fx") != null);
    try std.testing.expect(std.mem.indexOf(u8, names, "car.turbo:int") != null);
    const i: u32 = for (tune_entries, 0..) |e, k| {
        if (std.mem.eql(u8, e.name, "car.max_speed")) break @intCast(k);
    } else unreachable;
    const before = tuneGet(i);
    tuneSet(i, before * 2);
    try std.testing.expectEqual(before * 2, T.carModel(0).max_speed);
    tuneReset();
    try std.testing.expectEqual(before, tuneGet(i));
}

test "single player starts on the test map, steps and reports its HUD" {
    loadTestMap();
    try std.testing.expectEqual(@as(i32, 0), spStart(7, false, 0, 0));
    for (0..10) |_| gameStep();
    try std.testing.expectEqual(@as(i32, 1), playerInfo(0)[0]);
    const info = spInfo();
    try std.testing.expectEqual(@as(i32, 10), info[31]);
    try std.testing.expect(buildList(0.5, 0) > 0);
    try std.testing.expect(spDebug(1, 500, 90));
    gameStep();
    try std.testing.expectEqual(@as(i32, 500), spInfo()[8]);
    try std.testing.expect(!spDebug(99, 0, 0));
    // Back to deathmatch: the other configuration draws again.
    try std.testing.expectEqual(@as(i32, 0), gameStart(1, false, 0, 0));
    gameStep();
    try std.testing.expect(!spDebug(1, 500, 90));
    try std.testing.expect(buildList(0.5, 0) > 0);
}

test "text table lookups by number and key" {
    const bytes = try formats.gxt.build(std.testing.allocator, 'E', &.{ .{ "500", "Hi" }, .{ "mis_fail", "No" } });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(i32, 2), loadText(bytes.ptr, bytes.len));
    try std.testing.expectEqual(@as(i32, 2), textById(500));
    try std.testing.expectEqual(@as(u8, 'H'), textPtr()[0]);
    try std.testing.expectEqual(@as(i32, -1), textById(501));
    try std.testing.expectEqual(@as(i32, 2), textByKey("mis_fail", 8));
    try std.testing.expectEqual(@as(u8, 'N'), textPtr()[0]);
    try std.testing.expectEqual(@as(usize, 501), text_lengths.len);
    try std.testing.expectEqual(@as(u16, 2), text_lengths[500]);
}

test "script files are kept by name" {
    scriptsClear();
    try std.testing.expectEqual(@as(i32, 1), scriptAdd("wil.scr", 7, "abc", 3));
    try std.testing.expectEqualStrings("abc", scriptFile("WIL.SCR").?);
    try std.testing.expect(scriptFile("ste.scr") == null);
    scriptsClear();
}

test {
    _ = skids;
}
