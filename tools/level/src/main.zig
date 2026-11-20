//! Headless level runner (docs/plan-notes.md, workstream Q).
//!
//!   level --data <dir> --map <name.gmp> [--ticks N] [--bots N] [--seed S] [--out file.md]
//!   level --data <dir> --all [...]      every .gmp in <dir>
//!
//! Loads a real map from the player's own data (never committed, never in
//! CI), runs the sim with an autopilot player in slot 0 and bots in the
//! other slots to stir the city, and checks the invariants every tick. The
//! autopilot follows the mission arrow once the sim has one (A1's HUD
//! state); until then it is sent to random road waypoints 20 to 80 blocks
//! away, with a teleport after `--limit` ticks so one stuck trip does not
//! end the run. The report has no game data in it: counts, ticks and block
//! coordinates only.
//!
//! Per map it reports: waypoints reached on foot and by car, the ticks they
//! took, teleports, autopilot deaths, invariant breaks (with where), play
//! statistics and the step time.

const std = @import("std");
const sim = @import("sim");
const formats = @import("formats");
const qa = @import("qa");
const bots_mod = @import("bots");
const Autopilot = @import("autopilot.zig").Autopilot;
const fx = sim.fx;
const c = sim.c;
const abi = sim.abi;
const Frame = sim.input.Frame;

const S = sim.Sim16;
const max_players = S.config.max_players;
const print = std.debug.print;

var grid: abi.Grid = undefined;
var s: S = undefined;
var checker: qa.Checker(S) = .{};

const Options = struct {
    data: []const u8 = "",
    maps: std.ArrayList([]const u8) = .empty,
    ticks: u32 = 20_000,
    bots: u32 = 7,
    seed: u32 = 0x1E7E1,
    limit: u32 = 1800,
    out: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var o: Options = .{};
    var all = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const val = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--data")) {
            o.data = val;
            i += 1;
        } else if (std.mem.eql(u8, a, "--map")) {
            try o.maps.append(arena, val);
            i += 1;
        } else if (std.mem.eql(u8, a, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, a, "--ticks")) {
            o.ticks = try std.fmt.parseInt(u32, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--bots")) {
            o.bots = @min(try std.fmt.parseInt(u32, val, 10), max_players - 1);
            i += 1;
        } else if (std.mem.eql(u8, a, "--seed")) {
            o.seed = try std.fmt.parseInt(u32, val, 0);
            i += 1;
        } else if (std.mem.eql(u8, a, "--limit")) {
            o.limit = try std.fmt.parseInt(u32, val, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--out")) {
            o.out = val;
            i += 1;
        } else {
            print("unknown argument {s}\n", .{a});
            return usage();
        }
    }
    if (o.data.len == 0) return usage();
    const cwd = std.Io.Dir.cwd();
    if (all) {
        var dir = try cwd.openDir(io, o.data, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (std.ascii.endsWithIgnoreCase(e.name, ".gmp")) try o.maps.append(arena, try arena.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, o.maps.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    }
    if (o.maps.items.len == 0) return usage();

    var report: std.ArrayList(u8) = .empty;
    try appendf(&report, arena, "# Level runner results\n\nWritten by `tools/level` (workstream Q). {d} ticks per map, autopilot in slot 0, {d} bots, seed {x}, teleport after {d} ticks. Targets: {s}.\n\n", .{ o.ticks, o.bots, o.seed, o.limit, if (comptime hasArrow()) "the mission arrow" else "random road waypoints (no mission arrow in the sim yet)" });
    var failed = false;
    for (o.maps.items) |name| {
        var path_buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ o.data, name });
        const bytes = cwd.readFileAlloc(io, path, init.gpa, .unlimited) catch |e| {
            try appendf(&report, arena, "## {s}\n\nCould not read: {s}\n\n", .{ name, @errorName(e) });
            failed = true;
            continue;
        };
        defer init.gpa.free(bytes);
        var m = formats.gmp.parse(init.gpa, bytes) catch |e| {
            try appendf(&report, arena, "## {s}\n\nCould not parse: {s}\n\n", .{ name, @errorName(e) });
            failed = true;
            continue;
        };
        defer m.deinit();
        formats.grid.build(&m, &grid);
        const ok = try runMap(io, init.gpa, arena, &report, name, o);
        failed = failed or !ok;
    }
    print("{s}", .{report.items});
    if (o.out) |p| try cwd.writeFile(io, .{ .sub_path = p, .data = report.items });
    if (failed) std.process.exit(1);
}

fn usage() void {
    print("usage: level --data <dir> (--map <name.gmp> ... | --all) [--ticks N] [--bots N] [--seed S] [--limit N] [--out file.md]\n", .{});
}

fn appendf(l: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime f: []const u8, a: anytype) !void {
    const t = try std.fmt.allocPrint(gpa, f, a);
    try l.appendSlice(gpa, t);
}

/// The sim exposes a mission arrow (A1's HUD state). Name to be fixed when
/// W0 lands the stubs; until then the runner uses waypoints.
fn hasArrow() bool {
    return @hasDecl(S, "missionArrow");
}

const Rng = struct {
    x: u32,
    fn next(r: *Rng) u32 {
        r.x ^= r.x << 13;
        r.x ^= r.x >> 17;
        r.x ^= r.x << 5;
        return r.x;
    }
    fn below(r: *Rng, n: u32) u32 {
        return @truncate((@as(u64, r.next()) * n) >> 32);
    }
};

/// Road cells whose floor is the top of their column (not under a bridge);
/// on a map with no road (some multiplayer arenas), any dry floor.
fn roadCells(gpa: std.mem.Allocator) ![]u32 {
    const roads = try floorCells(gpa, true);
    if (roads.len > 0) return roads;
    gpa.free(roads);
    return floorCells(gpa, false);
}

fn floorCells(gpa: std.mem.Allocator, road_only: bool) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    for (0..sim.map.size_y) |y| for (0..sim.map.size_x) |x| {
        const px = fx.fromInt(@intCast(x)) + fx.half;
        const py = fx.fromInt(@intCast(y)) + fx.half;
        const top = fx.fromInt(sim.map.size_z - 1);
        const z = sim.map.floorAt(&grid, px, py, top, sim.tuning.ped_step);
        if (z < 0) continue;
        const cell = sim.map.floorCell(&grid, px, py, z, fx.ratio(1, 16));
        const g = formats.grid.cellGround(cell);
        if ((g == .road or (!road_only and g != .none)) and !sim.map.waterAt(&grid, px, py, z))
            try out.append(gpa, @intCast(y * sim.map.size_x + x));
    };
    return out.toOwnedSlice(gpa);
}

fn pickWaypoint(rng: *Rng, roads: []const u32, x: fx.Fx, y: fx.Fx) [2]fx.Fx {
    var best: [2]fx.Fx = .{ x, y };
    for (0..64) |_| {
        const r = roads[rng.below(@intCast(roads.len))];
        const wx = fx.fromInt(@intCast(r % sim.map.size_x)) + fx.half;
        const wy = fx.fromInt(@intCast(r / sim.map.size_x)) + fx.half;
        const d = fx.length(wx - x, wy - y);
        best = .{ wx, wy };
        if (d >= fx.fromInt(20) and d <= fx.fromInt(80)) break;
    }
    return best;
}

fn runMap(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, report: *std.ArrayList(u8), name: []const u8, o: Options) !bool {
    const roads = try roadCells(gpa);
    defer gpa.free(roads);
    if (roads.len == 0) {
        try appendf(report, arena, "## {s}\n\nNo floor cells to send the autopilot to.\n\n", .{name});
        return false;
    }
    s.init(&grid, .{ .seed = o.seed, .mode = .authoritative });
    checker = .{};
    var rng: Rng = .{ .x = o.seed | 1 };
    const players = 1 + o.bots;
    var bots: [max_players]bots_mod.Bot = undefined;
    for (&bots, 0..) |*b, i| b.* = bots_mod.Bot.init(o.seed, @intCast(i));
    var ap: Autopilot = .{};
    var frames: [max_players]Frame = @splat(Frame.neutral(0));
    var cmds: [max_players]abi.Command = undefined;
    for (0..players) |i| cmds[i] = .{ .op = .join, .slot = @intCast(i), .arg = 0 };
    var ps: qa.PlayStats = .{};
    var tr: qa.PlayStats.Tracker(S) = .{};

    var reached_foot: u32 = 0;
    var reached_car: u32 = 0;
    var teleports: u32 = 0;
    var trip_ticks: u64 = 0;
    var ap_deaths: u32 = 0;
    var no_ped_ticks: u32 = 0;
    var times = try gpa.alloc(i64, o.ticks);
    defer gpa.free(times);
    var was_alive = false;

    for (0..o.ticks) |ti| {
        // Target.
        if (comptime hasArrow()) {
            if (s.missionArrow()) |t| ap.setTarget(t[0], t[1]);
        } else if (!ap.has_target) {
            if (Autopilot.bodyTransform(S, &s, 0)) |t| {
                const w = pickWaypoint(&rng, roads, t.x, t.y);
                ap.setTarget(w[0], w[1]);
            }
        }
        for (1..players) |i| frames[i] = bots[i].frame(S, &s, @intCast(i));
        frames[0] = ap.frame(S, &s, 0);
        const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
        s.step(frames[0..players], if (ti == 0) cmds[0..players] else &.{});
        times[ti] = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - t0);
        checker.check(&s);
        tr.after(&ps, &s);

        const alive = s.pedOf(0) != null;
        if (was_alive and !alive) ap_deaths += 1;
        was_alive = alive;
        if (!alive) no_ped_ticks += 1;
        if (ap.has_target and alive) {
            if (ap.distance(S, &s, 0)) |d| {
                if (d < Autopilot.arrive_dist * 2) {
                    const in_car = !s.state.world.get(s.pedOf(0).?, c.Riding).?.vehicle.isNone();
                    if (in_car) reached_car += 1 else reached_foot += 1;
                    trip_ticks += ap.age;
                    ap.has_target = false;
                } else if (ap.age >= o.limit) {
                    teleports += 1;
                    ap.teleport(S, &s, 0);
                    trip_ticks += ap.age;
                    ap.has_target = false;
                }
            }
        }
    }
    tr.finish(&ps, &s);
    std.mem.sort(i64, times, {}, std.sort.asc(i64));
    var total: i64 = 0;
    for (times) |t| total += t;
    const trips = reached_foot + reached_car + teleports;

    try appendf(report, arena, "## {s}\n\n", .{name});
    try appendf(report, arena, "- road cells: {d}\n", .{roads.len});
    try appendf(report, arena, "- autopilot trips: {d} ({d} reached on foot, {d} by car, {d} teleported after {d} ticks); mean {d} ticks a trip\n", .{ trips, reached_foot, reached_car, teleports, o.limit, if (trips > 0) trip_ticks / trips else 0 });
    try appendf(report, arena, "- autopilot deaths: {d}; ticks with no ped: {d}\n", .{ ap_deaths, no_ped_ticks });
    try appendf(report, arena, "- step: mean {d:.4} ms, p99 {d:.4} ms, max {d:.4} ms\n", .{ ms(@divTrunc(total, o.ticks)), ms(times[o.ticks * 99 / 100]), ms(times[o.ticks - 1]) });
    try appendf(report, arena, "- invariant breaks: {d}\n\n", .{checker.total()});
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("```\n", .{});
    try checker.report(&w);
    try ps.write(&w);
    try w.print("```\n\n", .{});
    try report.appendSlice(arena, w.buffered());
    return checker.total() == 0;
}

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
