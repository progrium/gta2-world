//! s1: native companion to the viewer.
//!
//!   s1 inspect <file.gmp|file.sty>...   parse and print a report
//!   s1 fixtures <out-dir>               write the synthetic demo files
//!
//! `inspect` is the quick way to check the parsers against real files:
//! it fails loudly on anything the parser rejects.

const std = @import("std");
const formats = @import("formats");
const mesh = @import("mesh.zig");
const showcase = @import("showcase.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    if (args.len >= 3 and std.mem.eql(u8, args[1], "fixtures")) {
        try writeFixtures(init.gpa, io, args[2]);
        try out.print("wrote {s}/showcase.gmp and {s}/showcase.sty\n", .{ args[2], args[2] });
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "inspect")) {
        var failed = false;
        for (args[2..]) |path| {
            inspect(init.gpa, io, out, path) catch |e| {
                try out.print("{s}: FAILED: {s}\n\n", .{ path, @errorName(e) });
                failed = true;
            };
        }
        try out.flush();
        if (failed) std.process.exit(1);
        return;
    }
    try out.writeAll("usage: s1 inspect <file.gmp|file.sty>...\n       s1 fixtures <out-dir>\n");
}

fn writeFixtures(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    var map = try showcase.buildMap(gpa);
    defer map.deinit();
    const map_bytes = try map.write(.dmap);
    defer gpa.free(map_bytes);
    try dir.writeFile(io, .{ .sub_path = "showcase.gmp", .data = map_bytes });

    var style = try showcase.buildStyle(gpa);
    defer style.deinit();
    const sty_bytes = try style.write();
    defer gpa.free(sty_bytes);
    try dir.writeFile(io, .{ .sub_path = "showcase.sty", .data = sty_bytes });
}

fn inspect(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, path: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    try out.print("{s} ({d} bytes)\n", .{ path, bytes.len });
    if (bytes.len < 4) return error.Truncated;

    try out.writeAll("  chunks:");
    var it = formats.chunk.iterate(bytes);
    while (try it.next()) |c| try out.print(" {s}({d})", .{ &c.tag, c.data.len });
    try out.writeAll("\n");

    if (std.mem.eql(u8, bytes[0..4], formats.gmp.magic)) {
        var m = try formats.gmp.parse(gpa, bytes);
        defer m.deinit();
        try out.print("  map version {d}, {s}, {d} block definitions\n", .{ m.version, @tagName(m.compression), m.blocks.len });
        try out.print("  zones {d}, map objects {d}, lights {d}, tile anims {d}, unknown chunks {d}, clamped columns {d}\n", .{
            m.zones.len, m.objects.len, m.lights.len, m.anims.len, m.diag.unknown_chunks, m.diag.clamped_columns,
        });
        var solid: u32 = 0;
        var per_z: [8]u32 = @splat(0);
        for (0..8) |z| for (0..256) |y| for (0..256) |x| {
            if (!m.get(x, y, z).isAir()) {
                solid += 1;
                per_z[z] += 1;
            }
        };
        try out.print("  solid cells {d}, per z {any}\n", .{ solid, per_z });
        try out.writeAll("  slope codes used (code:count):");
        for (m.diag.slope_histogram, 0..) |n, code| if (n > 0) try out.print(" {d}:{d}", .{ code, n });
        try out.writeAll("\n");
        var st: mesh.Stats = .{};
        const verts = try mesh.build(gpa, &m, &st);
        defer gpa.free(verts);
        try out.print("  mesh: {d} triangles ({d} KB), {d} lids, {d} sides, {d} transparent, {d} dummy-1023 faces\n", .{
            st.triangles, verts.len * @sizeOf(mesh.Vertex) / 1024, st.lids, st.sides, st.transparent, st.dummy,
        });
        var max_tile: u32 = 0;
        for (m.blocks) |b| {
            for ([_]formats.gmp.Face{ b.left, b.right, b.top, b.bottom, b.lid }) |f| {
                if (f.tile != 1023) max_tile = @max(max_tile, f.tile);
            }
        }
        try out.print("  highest tile referenced (excluding 1023): {d}\n", .{max_tile});
        if (m.zones.len > 0) {
            try out.writeAll("  first zones:");
            for (m.zones[0..@min(8, m.zones.len)]) |z| try out.print(" {s}", .{z.name});
            try out.writeAll("\n");
        }
    } else if (std.mem.eql(u8, bytes[0..4], formats.sty.magic)) {
        var s = try formats.sty.parse(gpa, bytes);
        defer s.deinit();
        try out.print("  style version {d}, {d} tiles, {d} physical palettes, {d} sprites, unknown chunks {d}\n", .{
            s.version, s.tileCount(), s.physicalPaletteCount(), s.sprites.len, s.unknown_chunks,
        });
        try out.print("  palette counts (tile, sprite, car, ped, code obj, map obj, user, font): {any}\n", .{s.palette_base.counts});
        try out.print("  sprite counts (car, ped, code obj, map obj, user, font): {any}\n", .{s.sprite_base.counts});
        var bad: u32 = 0;
        for (0..s.tileCount()) |t| if (s.tilePhysicalPalette(@intCast(t)) >= s.physicalPaletteCount()) {
            bad += 1;
        };
        try out.print("  tiles whose palette is out of range: {d}\n", .{bad});
    } else {
        return error.UnknownFileType;
    }
    try out.writeAll("\n");
}

test {
    _ = mesh;
}
