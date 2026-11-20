//! WASM entry points for the renderer demo page (and a reference for how
//! client/wasm hands data to the TypeScript renderer). JavaScript copies a
//! file into memory from `alloc`, calls `loadStyle` / `loadMap`, then reads
//! buffers straight out of linear memory. All exported pointers stay valid
//! until the next load call.

const std = @import("std");
const formats = @import("formats");
const render = @import("render");
const abi = @import("interfaces").abi;

const gpa = std.heap.wasm_allocator;
const mesh = render.mesh;
const list = render.list;
const stub = render.stub;

var style: ?formats.sty.Style = null;
var prepared: ?render.style.Prepared = null;
var map: ?formats.gmp.Map = null;
var map_mesh: ?mesh.Mesh = null;
var grid: ?*abi.Grid = null;
var anim_table: []u16 = &.{};

var traffic: ?*stub.Traffic = null;
var prev_state: []u8 = &.{};
var recording: ?stub.Recording = null;
var recording_bytes: []align(4) u8 = &.{};
var layout: list.Layout = .{};
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

// ------------------------------------------------------------------ entities

/// Starts the traffic stub on the loaded map.
export fn stubStart(seed: u32, cars: u32, peds: u32) i32 {
    recording = null;
    if (traffic == null) traffic = gpa.create(stub.Traffic) catch |e| return setError("stub", e);
    traffic.?.init(grid orelse return setError("stub", error.NoMap), seed, cars, peds);
    if (prev_state.len != stub.state_size) {
        gpa.free(prev_state);
        prev_state = gpa.alloc(u8, stub.state_size) catch |e| return setError("stub", e);
    }
    @memcpy(prev_state, traffic.?.stateBytes());
    layout = list.Layout.init(stub.views());
    return 0;
}

export fn stubStep() void {
    const t = traffic orelse return;
    @memcpy(prev_state, t.stateBytes());
    t.step();
}

/// Takes ownership of a recording copied in with `alloc`.
export fn loadRecording(p: [*]u8, n: usize) i32 {
    if (recording_bytes.len > 0) gpa.free(recording_bytes);
    recording_bytes = @alignCast(p[0..n]);
    recording = stub.Recording.parse(recording_bytes) catch |e| return setError("recording", e);
    layout = list.Layout.init(recording.?.views);
    return 0;
}
export fn recordingTicks() u32 {
    return if (recording) |r| r.tick_count else 0;
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

fn states(tick: u32) struct { prev: []const u8, cur: []const u8 } {
    if (recording) |*r| return .{ .prev = r.state(if (tick == 0) 0 else tick - 1), .cur = r.state(tick) };
    const t = traffic.?;
    return .{ .prev = prev_state, .cur = t.stateBytes() };
}

/// Builds the render list between tick-1 and tick (recording) or the last
/// two stub steps, at `alpha`. Returns the instance count.
export fn buildList(tick: u32, alpha: f32) usize {
    if (recording == null and traffic == null) return 0;
    const s = states(tick);
    return list.build(&layout, s.prev, s.cur, alpha, bases(), &instances);
}
export fn instancePtr() [*]const u8 {
    return @ptrCast(&instances);
}

/// Camera target for player `slot`, interpolated like the list.
export fn cameraTarget(tick: u32, alpha: f32, slot: u32) [*]const u8 {
    if (recording == null and traffic == null) {
        target_buf = std.mem.zeroes(list.Target);
        return @ptrCast(&target_buf);
    }
    const s = states(tick);
    const a = list.target(&layout, s.prev, slot);
    const b = list.target(&layout, s.cur, slot);
    target_buf = b;
    if (a.found != 0 and b.found != 0) {
        target_buf.x = a.x + (b.x - a.x) * alpha;
        target_buf.y = a.y + (b.y - a.y) * alpha;
        target_buf.z = a.z + (b.z - a.z) * alpha;
    }
    return @ptrCast(&target_buf);
}
