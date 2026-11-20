//! Native harness: bench, record and verify.
//!
//!   s2 bench16 [ticks]        step time, 16 players + 100 ambient peds
//!   s2 bench200 [ticks]       step time, 200 players' worth of entities
//!   s2 record <dir> [ticks]   write inputs.bin + hashes.bin (16 players)
//!   s2 hash200                final hash of a bot-driven 200-player run
//!   s2 verify <dir>           replay inputs.bin, compare every tick's hash,
//!                             with a save/step/load rewind every 100 ticks

const std = @import("std");
const common = @import("common.zig");
const sim = common.sim;
const Frame = sim.input.Frame;

var grid: sim.map.Grid = undefined;
var sim16: common.Sim16 = undefined;
var sim200: common.Sim200 = undefined;
var save_buf: [common.Sim200.state_size]u8 align(8) = undefined;

const print = std.debug.print;

fn now(io: std.Io) i64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        print("usage: s2 bench16|bench200 [ticks] | record <dir> [ticks] | verify <dir>\n", .{});
        return;
    }
    common.mapgen.generate(&grid, common.map_seed);
    print("map hash {x:0>16}\n", .{common.mapHash(&grid)});
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "bench16")) {
        const ticks = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 10000;
        try bench(common.Sim16, &sim16, io, init.gpa, 16, ticks);
    } else if (std.mem.eql(u8, cmd, "bench200")) {
        const ticks = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 10000;
        try bench(common.Sim200, &sim200, io, init.gpa, 200, ticks);
    } else if (std.mem.eql(u8, cmd, "record")) {
        const ticks = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 10000;
        try record(io, init.gpa, args[2], ticks);
    } else if (std.mem.eql(u8, cmd, "hash200")) {
        // Bot-driven 200-player run; compare the final hash with run-node.mjs.
        sim200.init(&grid, common.sim_seed, 200);
        var bots: [200]common.bots.Bot = undefined;
        for (&bots, 0..) |*b, i| b.* = common.bots.Bot.init(common.bot_seed, @intCast(i));
        var frames: [200]Frame = undefined;
        for (0..10000) |_| {
            common.bots.tick(&bots, &frames);
            sim200.step(&frames);
        }
        print("200-player 10000-tick final hash {x:0>16}\n", .{sim200.hash()});
    } else if (std.mem.eql(u8, cmd, "verify")) {
        try verify(io, init.gpa, args[2]);
    } else print("unknown command {s}\n", .{cmd});
}

fn bench(comptime S: type, s: *S, io: std.Io, gpa: std.mem.Allocator, comptime players: u32, ticks: u32) !void {
    s.init(&grid, common.sim_seed, players);
    var bots: [players]common.bots.Bot = undefined;
    for (&bots, 0..) |*b, i| b.* = common.bots.Bot.init(common.bot_seed, @intCast(i));
    var frames: [players]Frame = undefined;

    // Warm up so the world reaches a steady mix of shots, deaths and respawns.
    for (0..300) |_| {
        common.bots.tick(&bots, &frames);
        s.step(&frames);
    }
    const times = try gpa.alloc(i64, ticks);
    defer gpa.free(times);
    var total: i64 = 0;
    for (times) |*t| {
        common.bots.tick(&bots, &frames);
        const t0 = now(io);
        s.step(&frames);
        t.* = now(io) - t0;
        total += t.*;
    }
    std.mem.sort(i64, times, {}, std.sort.asc(i64));
    const w = &s.state.world;
    print("config {d} players: state {d} bytes; live cars {d} peds {d} shots {d}\n", .{
        players, S.state_size, w.count(S.Car), w.count(S.Ped), w.count(S.Shot),
    });
    print("stats: {any}\n", .{s.scratch.stats});
    print("step over {d} ticks: mean {d:.4} ms  p50 {d:.4}  p99 {d:.4}  max {d:.4}\n", .{
        ticks,
        ms(@divTrunc(total, ticks)),
        ms(times[ticks / 2]),
        ms(times[ticks * 99 / 100]),
        ms(times[ticks - 1]),
    });

    // Rewind cost: load a saved state and replay 10 ticks, as a client would.
    const n_rewinds = 1000;
    var t_save: i64 = 0;
    var t_load: i64 = 0;
    var t_hash: i64 = 0;
    var t_replay: i64 = 0;
    var h: u64 = 0;
    for (0..n_rewinds) |_| {
        var t0 = now(io);
        _ = s.save(&save_buf);
        t_save += now(io) - t0;
        var fr: [10][players]Frame = undefined;
        for (&fr) |*f| common.bots.tick(&bots, f);
        t0 = now(io);
        for (&fr) |*f| s.step(f);
        t_replay += now(io) - t0;
        t0 = now(io);
        s.load(&save_buf);
        t_load += now(io) - t0;
        t0 = now(io);
        h ^= s.hash();
        t_hash += now(io) - t0;
        for (&fr) |*f| s.step(f); // move on
    }
    print("save {d:.4} ms  load {d:.4} ms  hash {d:.4} ms  10-tick replay {d:.4} ms   (mean of {d}; {x})\n", .{
        ms(@divTrunc(t_save, n_rewinds)), ms(@divTrunc(t_load, n_rewinds)), ms(@divTrunc(t_hash, n_rewinds)),
        ms(@divTrunc(t_replay, n_rewinds)), n_rewinds, h & 0xF,
    });
}

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn record(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, ticks: u32) !void {
    const players = 16;
    sim16.init(&grid, common.sim_seed, players);
    var bots: [players]common.bots.Bot = undefined;
    for (&bots, 0..) |*b, i| b.* = common.bots.Bot.init(common.bot_seed, @intCast(i));
    const inputs = try gpa.alloc(Frame, ticks * players);
    defer gpa.free(inputs);
    const hashes = try gpa.alloc(u64, ticks + 1);
    defer gpa.free(hashes);
    hashes[0] = sim16.hash();
    for (0..ticks) |t| {
        const f = inputs[t * players ..][0..players];
        common.bots.tick(&bots, f);
        sim16.step(f);
        hashes[t + 1] = sim16.hash();
    }
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};
    var path_buf: [512]u8 = undefined;
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/inputs.bin", .{dir}), .data = std.mem.sliceAsBytes(inputs) });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/hashes.bin", .{dir}), .data = std.mem.sliceAsBytes(hashes) });
    const w = &sim16.state.world;
    print("recorded {d} ticks x {d} players; initial {x:0>16} final {x:0>16}\n", .{ ticks, players, hashes[0], hashes[ticks] });
    print("final world: cars {d} peds {d} shots {d}; kills", .{ w.count(common.Sim16.Car), w.count(common.Sim16.Ped), w.count(common.Sim16.Shot) });
    var total_kills: u32 = 0;
    var total_deaths: u32 = 0;
    for (sim16.state.players[0..players]) |p| {
        total_kills += p.kills;
        total_deaths += p.deaths;
    }
    print(" {d} player deaths {d}\n", .{ total_kills, total_deaths });
    print("stats: {any}\n", .{sim16.scratch.stats});
}

fn verify(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) !void {
    const players = 16;
    const cwd = std.Io.Dir.cwd();
    var path_buf: [512]u8 = undefined;
    const in_bytes = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&path_buf, "{s}/inputs.bin", .{dir}), gpa, .unlimited);
    defer gpa.free(in_bytes);
    const h_bytes = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&path_buf, "{s}/hashes.bin", .{dir}), gpa, .unlimited);
    defer gpa.free(h_bytes);
    const inputs: []const Frame = @alignCast(std.mem.bytesAsSlice(Frame, in_bytes));
    const hashes: []align(1) const u64 = std.mem.bytesAsSlice(u64, h_bytes);
    const ticks = inputs.len / players;

    sim16.init(&grid, common.sim_seed, players);
    if (sim16.hash() != hashes[0]) {
        print("MISMATCH at init\n", .{});
        return error.Mismatch;
    }
    var rewinds: u32 = 0;
    var t: usize = 0;
    while (t < ticks) : (t += 1) {
        if (t % 100 == 50 and t + 10 < ticks) {
            // Rewind check: run ahead 10 ticks, restore, then continue normally.
            _ = sim16.save(&save_buf);
            for (0..10) |k| sim16.step(inputs[(t + k) * players ..][0..players]);
            sim16.load(&save_buf);
            rewinds += 1;
        }
        sim16.step(inputs[t * players ..][0..players]);
        if (sim16.hash() != hashes[t + 1]) {
            print("MISMATCH at tick {d}: got {x:0>16} want {x:0>16}\n", .{ t + 1, sim16.hash(), hashes[t + 1] });
            return error.Mismatch;
        }
    }
    print("verify OK: {d} ticks, {d} rewinds, final {x:0>16}\n", .{ ticks, rewinds, hashes[ticks] });
}
