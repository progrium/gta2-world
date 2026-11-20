//! Native replay runner.
//!
//!   replay record <dir> [ticks]   play the scripted 16-player bot session on
//!                                 the test map; write inputs.bin, hashes.bin
//!   replay verify <dir>           replay inputs.bin and compare hash() every
//!                                 tick, with a save/run-ahead/load rewind
//!                                 every 100 ticks
//!   replay bench16 [ticks]        step time with 16 bots and the dm16 ambient
//!                                 population, plus rewind cost
//!   replay bench200 [ticks]       the same with 200 bots (config dm200)
//!   replay hash200                final hash of a 10,000-tick 200-bot run
//!   replay handling               measure the placeholder car and the ped
//!                                 (top speed, 0-to-speed, braking, turning)

const std = @import("std");
const common = @import("common.zig");
const sim = common.sim;
const abi = sim.abi;
const Frame = sim.input.Frame;

var grid: abi.Grid = undefined;
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
        print("usage: replay record <dir> [ticks] | verify <dir> | bench16|bench200 [ticks] | hash200\n", .{});
        return;
    }
    sim.testmap.build(&grid);
    print("map: synthetic test map, grid hash {x:0>16}\n", .{sim.map.gridHash(&grid)});
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "record")) {
        const ticks = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 10000;
        try record(io, init.gpa, args[2], ticks);
    } else if (std.mem.eql(u8, cmd, "verify")) {
        try verify(io, init.gpa, args[2]);
    } else if (std.mem.eql(u8, cmd, "bench16")) {
        const ticks = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 10000;
        try bench(common.Sim16, &sim16, io, init.gpa, 16, ticks);
    } else if (std.mem.eql(u8, cmd, "bench200")) {
        const ticks = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 10000;
        try bench(common.Sim200, &sim200, io, init.gpa, 200, ticks);
    } else if (std.mem.eql(u8, cmd, "hash200")) {
        print("200-player 10000-tick final hash {x:0>16}\n", .{botRun(common.Sim200, &sim200, 200, 10000)});
    } else if (std.mem.eql(u8, cmd, "handling")) {
        handling();
    } else print("unknown command {s}\n", .{cmd});
}

/// Straight-line and cornering numbers for the tuning notes, on the open
/// fields west of the city (x < 32), where nothing is in the way.
fn handling() void {
    const cfg: abi.Config = .{ .name = "hand", .max_players = 1, .car_capacity = 4, .ped_capacity = 4, .projectile_capacity = 4, .pickup_capacity = 4, .map_object_capacity = 4 };
    const S = sim.Sim(cfg);
    const s = std.heap.page_allocator.create(S) catch return;
    defer std.heap.page_allocator.destroy(s);
    const fx = sim.fx;
    const c = sim.c;
    const B = sim.input.Button;
    const bps = struct {
        fn f(v: fx.Fx) f64 {
            return @as(f64, @floatFromInt(v)) / 65536.0 * 30.0;
        }
    }.f;
    const blocks = struct {
        fn f(v: fx.Fx) f64 {
            return @as(f64, @floatFromInt(v)) / 65536.0;
        }
    }.f;
    var fr: [1]Frame = .{Frame.neutral(0)};

    // Ped: walk and run speed.
    s.init(&grid, .{ .seed = 1, .mode = .authoritative });
    s.step(&fr, &.{.{ .op = .join, .slot = 0, .arg = sim.spawnHint(10, 128) }});
    const ped = s.pedOf(0).?;
    fr[0].throttle = 127;
    var x0 = s.transformOf(ped).?.x;
    for (0..30) |_| s.step(&fr, &.{});
    const walk = s.transformOf(ped).?.x - x0;
    fr[0].buttons = B.run;
    x0 = s.transformOf(ped).?.x;
    for (0..30) |_| s.step(&fr, &.{});
    const run = s.transformOf(ped).?.x - x0;
    print("ped: walk {d:.2} blocks/s, run {d:.2} blocks/s\n", .{ blocks(walk), blocks(run) });

    // Car: from rest at full throttle.
    s.init(&grid, .{ .seed = 1, .mode = .authoritative });
    s.step(&fr, &.{.{ .op = .join, .slot = 0, .arg = sim.spawnHint(4, 100) }});
    const car = s.spawnCarAt(fx.fromInt(5) + fx.half, fx.fromInt(100) + fx.half, 0, 0).?;
    fr[0] = Frame.neutral(0);
    fr[0].buttons = B.enter_exit;
    s.step(&fr, &.{});
    fr[0] = Frame.neutral(0);
    fr[0].throttle = 127;
    const w = &s.state.world;
    const v = w.get(car, c.Velocity).?;
    const t = w.get(car, c.Transform).?;
    const m = sim.tuning.carModel(0);
    var t90: u32 = 0;
    x0 = t.x;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        s.step(&fr, &.{});
        if (t90 == 0 and v.vx * 10 >= m.max_speed * 9) t90 = i + 1;
    }
    const top = v.vx;
    print("car: top speed {d:.2} blocks/s; 0 to 90% in {d:.2} s; {d:.1} blocks covered in 10 s\n", .{ bps(top), @as(f64, @floatFromInt(t90)) / 30.0, blocks(t.x - x0) });
    // Braking from top speed.
    fr[0].throttle = -127;
    x0 = t.x;
    i = 0;
    while (v.vx > 0 and i < 300) : (i += 1) s.step(&fr, &.{});
    print("car: brake from top speed: {d:.2} s, {d:.2} blocks\n", .{ @as(f64, @floatFromInt(i)) / 30.0, blocks(t.x - x0) });
    // Coasting from top speed.
    fr[0].throttle = 127;
    for (0..200) |_| s.step(&fr, &.{});
    fr[0].throttle = 0;
    x0 = t.x;
    i = 0;
    while (v.vx > 0 and i < 900) : (i += 1) s.step(&fr, &.{});
    print("car: coast from top speed to rest: {d:.2} s, {d:.2} blocks\n", .{ @as(f64, @floatFromInt(i)) / 30.0, blocks(t.x - x0) });
    // Turning: full lock at top speed and at half speed, steady state.
    for ([_]i8{ 127, 64 }) |thr| {
        t.* = .{ .x = fx.fromInt(12), .y = fx.fromInt(128), .z = t.z, .heading = 0 };
        v.* = std.mem.zeroes(c.Velocity);
        fr[0] = .{ .steer = 0, .throttle = thr, .buttons = 0, .aim = 0, .seq = 0 };
        for (0..150) |_| s.step(&fr, &.{});
        fr[0].steer = 127;
        for (0..30) |_| s.step(&fr, &.{});
        // Measure a full revolution.
        var turned: i64 = 0;
        var n: u32 = 0;
        var prev = t.heading;
        var min_x = t.x;
        var max_x = t.x;
        while (turned < 65536 and n < 600) : (n += 1) {
            s.step(&fr, &.{});
            turned += @as(i16, @bitCast(t.heading -% prev));
            prev = t.heading;
            min_x = @min(min_x, t.x);
            max_x = @max(max_x, t.x);
        }
        const fwd = fx.mul(v.vx, fx.cos(t.heading)) + fx.mul(v.vy, fx.sin(t.heading));
        const lat = fx.mul(v.vx, -fx.sin(t.heading)) + fx.mul(v.vy, fx.cos(t.heading));
        print("car: full lock at throttle {d}: 360 degrees in {d:.2} s, circle {d:.1} blocks across, speed {d:.2} blocks/s, slip {d:.2} blocks/s\n", .{ thr, @as(f64, @floatFromInt(n)) / 30.0, blocks(max_x - min_x), bps(fwd), bps(lat) });
    }
    // Handbrake turn from top speed.
    t.* = .{ .x = fx.fromInt(12), .y = fx.fromInt(128), .z = t.z, .heading = 0 };
    v.* = std.mem.zeroes(c.Velocity);
    fr[0] = .{ .steer = 0, .throttle = 127, .buttons = 0, .aim = 0, .seq = 0 };
    for (0..150) |_| s.step(&fr, &.{});
    fr[0] = .{ .steer = 127, .throttle = 0, .buttons = B.handbrake_jump, .aim = 0, .seq = 0 };
    const h0 = t.heading;
    for (0..20) |_| s.step(&fr, &.{});
    const dir = fx.atan2(v.vy, v.vx);
    print("car: handbrake + full lock for 0.67 s from top speed: turned {d:.0} degrees, still moving at {d:.2} blocks/s toward {d:.0} degrees\n", .{ @as(f64, @floatFromInt(t.heading -% h0)) * 360.0 / 65536.0, bps(fx.length(v.vx, v.vy)), @as(f64, @floatFromInt(dir)) * 360.0 / 65536.0 });
}

/// Bot-driven run from init; returns the final hash.
pub fn botRun(comptime S: type, s: *S, comptime players: u32, ticks: u32) u64 {
    s.init(&grid, .{ .seed = common.sim_seed, .mode = .authoritative });
    var bots: [players]common.bots.Bot = undefined;
    for (&bots, 0..) |*b, i| b.* = common.bots.Bot.init(common.bot_seed, @intCast(i));
    var frames: [players]Frame = undefined;
    var cbuf: [players]abi.Command = undefined;
    for (0..ticks) |t| {
        common.bots.tick(S, s, &bots, &frames);
        s.step(&frames, common.sessionCommands(@intCast(t), players, &cbuf));
    }
    return s.hash();
}

fn record(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, ticks: u32) !void {
    const players = 16;
    const S = common.Sim16;
    const s = &sim16;
    s.init(&grid, .{ .seed = common.sim_seed, .mode = .authoritative });
    var bots: [players]common.bots.Bot = undefined;
    for (&bots, 0..) |*b, i| b.* = common.bots.Bot.init(common.bot_seed, @intCast(i));
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var hdr: [common.header_size]u8 = undefined;
    (common.Header{ .seed = common.sim_seed, .players = players, .ticks = ticks, .grid_hash = sim.map.gridHash(&grid) }).write(&hdr);
    try body.appendSlice(gpa, &hdr);
    const hashes = try gpa.alloc(u64, ticks + 1);
    defer gpa.free(hashes);
    hashes[0] = s.hash();
    var frames: [players]Frame = undefined;
    var cbuf: [players]abi.Command = undefined;
    for (0..ticks) |t| {
        common.bots.tick(S, s, &bots, &frames);
        const cmds = common.sessionCommands(@intCast(t), players, &cbuf);
        try common.writeTick(&body, gpa, cmds, &frames);
        s.step(&frames, cmds);
        hashes[t + 1] = s.hash();
    }
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};
    var path_buf: [512]u8 = undefined;
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/inputs.bin", .{dir}), .data = body.items });
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/hashes.bin", .{dir}), .data = std.mem.sliceAsBytes(hashes) });
    const w = &s.state.world;
    print("recorded {d} ticks x {d} players; initial {x:0>16} final {x:0>16}\n", .{ ticks, players, hashes[0], hashes[ticks] });
    print("final world: cars {d} peds {d} shots {d}\n", .{ w.count(S.Car), w.count(S.Ped), w.count(S.Shot) });
    print("stats: {any}\n", .{s.scratch.stats});
}

fn verify(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) !void {
    const S = common.Sim16;
    const s = &sim16;
    const cwd = std.Io.Dir.cwd();
    var path_buf: [512]u8 = undefined;
    const in_bytes = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&path_buf, "{s}/inputs.bin", .{dir}), gpa, .unlimited);
    defer gpa.free(in_bytes);
    const h_bytes = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&path_buf, "{s}/hashes.bin", .{dir}), gpa, .unlimited);
    defer gpa.free(h_bytes);
    const hdr = try common.Header.read(in_bytes);
    const hashes: []align(1) const u64 = std.mem.bytesAsSlice(u64, h_bytes);
    if (hdr.grid_hash != sim.map.gridHash(&grid)) {
        print("MISMATCH: replay was recorded on a different map\n", .{});
        return error.Mismatch;
    }
    if (hdr.players > S.config.max_players or hashes.len != hdr.ticks + 1) return error.BadReplay;

    s.init(&grid, .{ .seed = hdr.seed, .mode = .authoritative });
    if (s.hash() != hashes[0]) {
        print("MISMATCH at init: got {x:0>16} want {x:0>16}\n", .{ s.hash(), hashes[0] });
        return error.Mismatch;
    }
    var frames: [S.config.max_players]Frame = @splat(Frame.neutral(0));
    var cbuf: [64]abi.Command = undefined;
    var fa: [S.config.max_players]Frame = @splat(Frame.neutral(0));
    var ca: [64]abi.Command = undefined;
    const body = in_bytes;
    var pos: usize = common.header_size;
    var rewinds: u32 = 0;
    var t: u32 = 0;
    while (t < hdr.ticks) : (t += 1) {
        if (t % 100 == 50 and t + 10 < hdr.ticks) {
            // Rewind check: run ahead 10 ticks, restore, then continue.
            _ = s.save(&save_buf);
            var p2 = pos;
            for (0..10) |_| {
                const r = try common.readTick(body, p2, hdr.players, &ca, &fa);
                s.step(&fa, r.cmds);
                p2 = r.next;
            }
            try s.load(save_buf[0..S.state_size]);
            rewinds += 1;
        }
        const r = try common.readTick(body, pos, hdr.players, &cbuf, &frames);
        pos = r.next;
        s.step(&frames, r.cmds);
        if (s.hash() != hashes[t + 1]) {
            print("MISMATCH at tick {d}: got {x:0>16} want {x:0>16}\n", .{ t + 1, s.hash(), hashes[t + 1] });
            return error.Mismatch;
        }
    }
    print("verify OK: {d} ticks, {d} rewinds, final {x:0>16}\n", .{ hdr.ticks, rewinds, hashes[hdr.ticks] });
}

fn bench(comptime S: type, s: *S, io: std.Io, gpa: std.mem.Allocator, comptime players: u32, ticks: u32) !void {
    s.init(&grid, .{ .seed = common.sim_seed, .mode = .authoritative });
    var bots: [players]common.bots.Bot = undefined;
    for (&bots, 0..) |*b, i| b.* = common.bots.Bot.init(common.bot_seed, @intCast(i));
    var frames: [players]Frame = undefined;
    var cbuf: [players]abi.Command = undefined;
    for (0..300) |t| {
        common.bots.tick(S, s, &bots, &frames);
        s.step(&frames, common.sessionCommands(@intCast(t), players, &cbuf));
    }
    const times = try gpa.alloc(i64, ticks);
    defer gpa.free(times);
    var total: i64 = 0;
    for (times) |*tm| {
        common.bots.tick(S, s, &bots, &frames);
        const t0 = now(io);
        s.step(&frames, &.{});
        tm.* = now(io) - t0;
        total += tm.*;
    }
    std.mem.sort(i64, times, {}, std.sort.asc(i64));
    const w = &s.state.world;
    print("config {s}: state {d} bytes; live cars {d} peds {d} shots {d}\n", .{ S.config.name, S.state_size, w.count(S.Car), w.count(S.Ped), w.count(S.Shot) });
    print("stats: {any}\n", .{s.scratch.stats});
    print("step over {d} ticks: mean {d:.4} ms  p50 {d:.4}  p99 {d:.4}  max {d:.4}\n", .{
        ticks, ms(@divTrunc(total, ticks)), ms(times[ticks / 2]), ms(times[ticks * 99 / 100]), ms(times[ticks - 1]),
    });
    const n_rewinds = 500;
    var t_replay: i64 = 0;
    for (0..n_rewinds) |_| {
        _ = s.save(&save_buf);
        var fr: [10][players]Frame = undefined;
        for (&fr) |*f| common.bots.tick(S, s, &bots, f);
        const t0 = now(io);
        for (&fr) |*f| s.step(f, &.{});
        t_replay += now(io) - t0;
        try s.load(save_buf[0..S.state_size]);
        for (&fr) |*f| s.step(f, &.{});
    }
    print("10-tick replay {d:.4} ms (mean of {d})\n", .{ ms(@divTrunc(t_replay, n_rewinds)), n_rewinds });
}

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
