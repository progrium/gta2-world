//! render-tool: native companion to the renderer.
//!
//!   render-tool fixtures <dir>                 write the synthetic showcase
//!   render-tool inspect <map.gmp>...           mesh and collision report
//!   render-tool record <map.gmp> <out.grec> [ticks] [cars] [peds]
//!                                              record the traffic stub
//!
//! Recordings made from original maps hold positions on those maps; keep
//! them out of the repo like the maps themselves (.gitignore covers .grec).

const std = @import("std");
const formats = @import("formats");
const render = @import("render");
const showcase = @import("showcase.zig");
const abi = @import("interfaces").abi;

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(arena);

    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    if (args.len >= 3 and std.mem.eql(u8, args[1], "fixtures")) {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, args[2]);
        var dir = try cwd.openDir(io, args[2], .{});
        defer dir.close(io);
        var map = try showcase.buildMap(gpa);
        defer map.deinit();
        const mb = try map.write(.dmap);
        defer gpa.free(mb);
        try dir.writeFile(io, .{ .sub_path = "showcase.gmp", .data = mb });
        var style = try showcase.buildStyle(gpa);
        defer style.deinit();
        const sb = try style.write();
        defer gpa.free(sb);
        try dir.writeFile(io, .{ .sub_path = "showcase.sty", .data = sb });
        try out.print("wrote {s}/showcase.gmp and showcase.sty\n", .{args[2]});
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "inspect")) {
        for (args[2..]) |path| try inspect(gpa, io, out, path);
        return;
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "record")) {
        const ticks = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 1800;
        const cars = if (args.len > 5) try std.fmt.parseInt(u32, args[5], 10) else 40;
        const peds = if (args.len > 6) try std.fmt.parseInt(u32, args[6], 10) else 100;
        const bytes = try Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(64 << 20));
        defer gpa.free(bytes);
        var map = try formats.gmp.parse(gpa, bytes);
        defer map.deinit();
        const grid = try gpa.create(abi.Grid);
        defer gpa.destroy(grid);
        formats.grid.build(&map, grid);
        const rec = try render.stub.recordTraffic(gpa, grid, 1, cars, peds, ticks);
        defer gpa.free(rec);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = rec });
        try out.print("wrote {s}: {d} ticks, {d} bytes per state\n", .{ args[3], ticks, render.stub.state_size });
        return;
    }
    try out.writeAll("usage: render-tool fixtures <dir> | inspect <map.gmp>... | record <map.gmp> <out.grec> [ticks] [cars] [peds]\n");
}

fn inspect(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, path: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    var map = try formats.gmp.parse(gpa, bytes);
    defer map.deinit();

    var t0 = Io.Clock.awake.now(io);
    var full = try render.mesh.buildChunked(gpa, &map, .{ .hidden_face_removal = false, .bake_lights = false });
    defer full.deinit(gpa);
    const ms_full = t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    t0 = Io.Clock.awake.now(io);
    var m = try render.mesh.buildChunked(gpa, &map, .{});
    defer m.deinit(gpa);
    const ms = t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds();

    var max_chunk: u32 = 0;
    var empty: u32 = 0;
    for (m.chunks) |c| {
        max_chunk = @max(max_chunk, c.count / 3);
        if (c.count == 0) empty += 1;
    }
    try out.print("{s}\n  triangles {d} -> {d} with hidden-face removal ({d} faces hidden), {d} ms (plain {d} ms)\n", .{ path, full.stats.triangles, m.stats.triangles, m.stats.hidden, ms, ms_full });
    try out.print("  chunks: {d}, empty {d}, largest {d} triangles; lights {d}; vertex buffer {d} KB\n", .{ m.chunks.len, empty, max_chunk, map.lights.len, m.vertices.len * @sizeOf(render.mesh.Vertex) / 1024 });

    const grid = try gpa.create(abi.Grid);
    defer gpa.destroy(grid);
    formats.grid.build(&map, grid);
    var shapes: [8]u32 = @splat(0);
    var arrows: u32 = 0;
    const flat: *const [abi.map_x * abi.map_y * abi.map_z]abi.Cell = @ptrCast(&grid.blocks);
    for (flat) |c| {
        shapes[@intFromEnum(formats.grid.cellShape(c))] += 1;
        if (c & 0x7800 != 0) arrows += 1;
    }
    try out.print("  grid: air {d}, solid {d}, slope {d}, partial {d}, slab {d}; cells with arrows {d}\n", .{ shapes[0], shapes[1], shapes[2], shapes[3], shapes[5], arrows });
    try out.flush();
}
