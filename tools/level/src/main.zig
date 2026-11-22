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
const traffic = @import("traffic.zig");
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

pub const Options = struct {
    data: []const u8 = "",
    maps: std.ArrayList([]const u8) = .empty,
    ticks: u32 = 20_000,
    bots: u32 = 7,
    seed: u32 = 0x1E7E1,
    limit: u32 = 1800,
    out: ?[]const u8 = null,
    /// Single-player mode: run each level's script in the `sp` config.
    sp: bool = false,
    traffic: bool = false,
    dump: ?[2]i32 = null,
    /// `--cars <file.sty>`: car models from that style and the data's
    /// `nyc.gci` (if there), with the standard model roles, instead of
    /// the one default model.
    cars: ?[]const u8 = null,
};

var sp: traffic.S = undefined;

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
        } else if (std.mem.eql(u8, a, "--cars")) {
            o.cars = val;
            i += 1;
        } else if (std.mem.eql(u8, a, "--sp")) {
            o.sp = true;
        } else if (std.mem.eql(u8, a, "--dump")) {
            var it = std.mem.splitScalar(u8, val, ',');
            o.dump = .{ try std.fmt.parseInt(i32, it.next().?, 10), try std.fmt.parseInt(i32, it.next().?, 10) };
            i += 1;
        } else if (std.mem.eql(u8, a, "--trace")) {
            traffic.setTrace(try std.fmt.parseInt(u32, val, 10));
            i += 1;
        } else if (std.mem.eql(u8, a, "--traffic")) {
            o.traffic = true;
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
    if (o.cars) |sty_name| try loadCars(io, init.gpa, o.data, sty_name);
    if (all) {
        var dir = try cwd.openDir(io, o.data, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (!std.ascii.endsWithIgnoreCase(e.name, ".gmp")) continue;
            // In --sp mode, only maps with a main script of the same name.
            if (o.sp) {
                var nb: [512]u8 = undefined;
                const scr = try std.fmt.bufPrint(&nb, "{s}.scr", .{e.name[0 .. e.name.len - 4]});
                dir.access(io, scr, .{}) catch continue;
            }
            try o.maps.append(arena, try arena.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, o.maps.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    }
    if (o.maps.items.len == 0) return usage();

    var report: std.ArrayList(u8) = .empty;
    if (o.traffic)
        try appendf(&report, arena, "# Traffic soak results\n\nWritten by `tools/level --traffic` (workstream F). {d} ticks per map in the single-player configuration (48 ambient cars), the player on foot, moved to the pavement beside a random road block every 2000 ticks, seed {x}.\n\n", .{ o.ticks, o.seed })
    else if (o.sp)
        try appendf(&report, arena, "# Level runner results: single player\n\nWritten by `tools/level --sp` (workstream Q). Each level runs its own script in the `sp` configuration for {d} ticks, seed {x}. The autopilot follows the mission arrow, else the last phone that rang, else road waypoints; it is teleported to its target after {d} ticks.\n\n", .{ o.ticks, o.seed, o.limit })
    else
        try appendf(&report, arena, "# Level runner results\n\nWritten by `tools/level` (workstream Q). {d} ticks per map, autopilot in slot 0, {d} bots, seed {x}, teleport after {d} ticks. Targets: random road waypoints.\n\n", .{ o.ticks, o.bots, o.seed, o.limit });
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
        // Zero first: tables the builder does not fill (a later addition
        // such as surface flags) must read as empty.
        @memset(std.mem.asBytes(&grid), 0);
        formats.grid.build(&m, &grid);
        const ok = if (o.traffic)
            try runTraffic(init.gpa, arena, &report, name, o)
        else if (o.sp)
            try @import("sp.zig").runLevel(io, init.gpa, arena, &report, &grid, &m, name, o)
        else
            try runMap(io, init.gpa, arena, &report, name, o);
        failed = failed or !ok;
    }
    print("{s}", .{report.items});
    if (o.out) |p| try cwd.writeFile(io, .{ .sub_path = p, .data = report.items });
    if (failed) std.process.exit(1);
}

fn runTraffic(gpa: std.mem.Allocator, arena: std.mem.Allocator, report: *std.ArrayList(u8), name: []const u8, o: Options) !bool {
    const roads = try roadCells(&grid, gpa);
    defer gpa.free(roads);
    if (o.dump) |d| {
        traffic.dump(&grid, d[0], d[1], 10);
        return true;
    }
    const counts = traffic.run(&sp, &grid, o.seed, o.ticks, roads);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("## {s}\n\n", .{name});
    try traffic.write(&w, counts);
    try report.appendSlice(arena, w.buffered());
    return true;
}

fn copyFields(comptime To: type, from: anytype) To {
    var out: To = undefined;
    inline for (@typeInfo(To).@"struct".field_names) |n| @field(out, n) = @field(from, n);
    return out;
}

/// `--cars`: the models a host builds from the player's style and .gci.
fn loadCars(io: std.Io, gpa: std.mem.Allocator, data: []const u8, sty_name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var pb: [1024]u8 = undefined;
    const sty_bytes = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&pb, "{s}/{s}", .{ data, sty_name }), gpa, .unlimited);
    defer gpa.free(sty_bytes);
    var style = try formats.sty.parse(gpa, sty_bytes);
    defer style.deinit();
    const gci_bytes = cwd.readFileAlloc(io, try std.fmt.bufPrint(&pb, "{s}/nyc.gci", .{data}), gpa, .unlimited) catch null;
    defer if (gci_bytes) |b| gpa.free(b);
    const recs = if (gci_bytes) |b| try formats.gci.parse(gpa, b) else &[_]formats.gci.Record{};
    defer if (gci_bytes != null) gpa.free(recs);
    const specs = try formats.cars.build(gpa, &style, recs, copyFields(formats.cars.Spec, sim.tuning.default_spec));
    defer gpa.free(specs);
    var models: [sim.tuning.max_car_models]sim.tuning.CarModel = undefined;
    const count = @min(specs.len, models.len);
    for (specs[0..count], models[0..count]) |sp_, *m| m.* = sim.tuning.deriveModel(copyFields(sim.tuning.CarSpec, sp_));
    sim.tuning.setCarModels(models[0..count]);
    sim.tuning_career.setStandardRoles(count);
    print("car models: {d}\n", .{count});
}

fn usage() void {
    print("usage: level --data <dir> (--map <name.gmp> ... | --all) [--traffic [--trace N] [--dump X,Y]] [--sp] [--cars file.sty] [--ticks N] [--bots N] [--seed S] [--limit N] [--out file.md]\n", .{});
}

pub fn appendf(l: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime f: []const u8, a: anytype) !void {
    const t = try std.fmt.allocPrint(gpa, f, a);
    try l.appendSlice(gpa, t);
}

pub const Rng = struct {
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
pub fn roadCells(grid_: *const abi.Grid, gpa: std.mem.Allocator) ![]u32 {
    const roads = try floorCells(grid_, gpa, true);
    if (roads.len > 0) return roads;
    gpa.free(roads);
    return floorCells(grid_, gpa, false);
}

fn floorCells(g: *const abi.Grid, gpa: std.mem.Allocator, road_only: bool) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    for (0..sim.map.size_y) |y| for (0..sim.map.size_x) |x| {
        const px = fx.fromInt(@intCast(x)) + fx.half;
        const py = fx.fromInt(@intCast(y)) + fx.half;
        const top = fx.fromInt(sim.map.size_z - 1);
        const z = sim.map.floorAt(g, px, py, top, sim.tuning.ped_step);
        if (z < 0) continue;
        const cell = sim.map.floorCell(g, px, py, z, fx.ratio(1, 16));
        const gt = formats.grid.cellGround(cell);
        if ((gt == .road or (!road_only and gt != .none)) and !sim.map.waterAt(g, px, py, z))
            try out.append(gpa, @intCast(y * sim.map.size_x + x));
    };
    return out.toOwnedSlice(gpa);
}

pub fn pickWaypoint(rng: *Rng, roads: []const u32, x: fx.Fx, y: fx.Fx) [2]fx.Fx {
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
    const roads = try roadCells(&grid, gpa);
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
        if (!ap.has_target) {
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

pub fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
