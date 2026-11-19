//! WASM entry points for the S1 viewer. JavaScript copies a file into
//! memory from `alloc`, calls `loadMap` / `loadStyle`, then reads the mesh
//! and textures straight out of linear memory.

const std = @import("std");
const formats = @import("formats");
const mesh = @import("mesh.zig");
const atlas = @import("atlas.zig");

const gpa = std.heap.wasm_allocator;

var map: ?formats.gmp.Map = null;
var style: ?formats.sty.Style = null;
var vertices: []mesh.Vertex = &.{};
var stats: mesh.Stats = .{};
var index_atlas: []u8 = &.{};
var palette_rows: []u8 = &.{};
var err_buf: [256]u8 = undefined;
var err_len: usize = 0;

fn setError(comptime what: []const u8, e: anyerror) i32 {
    const s = std.fmt.bufPrint(&err_buf, what ++ ": {s}", .{@errorName(e)}) catch "error";
    err_len = s.len;
    return -1;
}

export fn alloc(n: usize) ?[*]u8 {
    const s = gpa.alloc(u8, n) catch return null;
    return s.ptr;
}

export fn free(p: [*]u8, n: usize) void {
    gpa.free(p[0..n]);
}

export fn errorPtr() [*]const u8 {
    return &err_buf;
}
export fn errorLen() usize {
    return err_len;
}

export fn loadMap(p: [*]const u8, n: usize) i32 {
    if (map) |*m| m.deinit();
    map = null;
    gpa.free(vertices);
    vertices = &.{};
    map = formats.gmp.parse(gpa, p[0..n]) catch |e| return setError("map", e);
    stats = .{};
    vertices = mesh.build(gpa, &map.?, &stats) catch |e| return setError("mesh", e);
    return 0;
}

export fn loadStyle(p: [*]const u8, n: usize) i32 {
    if (style) |*s| s.deinit();
    style = null;
    style = formats.sty.parse(gpa, p[0..n]) catch |e| return setError("style", e);
    if (index_atlas.len == 0) {
        index_atlas = gpa.alloc(u8, atlas.atlas_size * atlas.atlas_size) catch |e| return setError("atlas", e);
        palette_rows = gpa.alloc(u8, 256 * atlas.max_tiles * 4) catch |e| return setError("atlas", e);
    }
    atlas.buildIndexAtlas(&style.?, index_atlas);
    atlas.buildPaletteRows(&style.?, palette_rows);
    return 0;
}

export fn vertexPtr() [*]const u8 {
    return @ptrCast(vertices.ptr);
}
export fn vertexCount() usize {
    return vertices.len;
}
export fn atlasPtr() [*]const u8 {
    return index_atlas.ptr;
}
export fn palettePtr() [*]const u8 {
    return palette_rows.ptr;
}
export fn styleTileCount() u32 {
    return if (style) |*s| s.tileCount() else 0;
}

/// Stats as u32s: lids, sides, transparent, triangles, dummy, block defs,
/// zones, lights, anims, compression (0 umap 1 cmap 2 dmap), version,
/// unknown chunks, clamped columns.
var stat_buf: [13]u32 = undefined;
export fn statsPtr() [*]const u32 {
    const m = &(map orelse return &stat_buf);
    stat_buf = .{
        stats.lids,
        stats.sides,
        stats.transparent,
        stats.triangles,
        stats.dummy,
        @intCast(m.blocks.len),
        @intCast(m.zones.len),
        @intCast(m.lights.len),
        @intCast(m.anims.len),
        @intFromEnum(m.compression),
        m.version,
        m.diag.unknown_chunks,
        m.diag.clamped_columns,
    };
    return &stat_buf;
}

/// Histogram of the 64 slope codes over all solid cells.
export fn slopeHistogramPtr() [*]const u32 {
    const m = &(map orelse return &stat_buf);
    return &m.diag.slope_histogram;
}
