//! `level --sp`: run a level's own script in the single-player config.
//!
//! Loads <name>.gmp, the main script <name>.scr and the mission
//! sub-scripts in <name>/*.scr from the player's data, attaches them as the
//! sim's `Level`, joins the player, and lets the autopilot play: it goes to
//! the mission arrow when the HUD shows one, else to the last phone that
//! rang, else to the nearest phone it has not stood at yet (a level's
//! missions start from phones), else to road waypoints, and is teleported
//! after `--limit` ticks.
//!
//! Reports, per level: missions started, passed and failed with the ticks
//! each took, phone rings, wasted and busted, threads that sat on one
//! command for over 3,000 ticks (with the command's number and type),
//! unhandled command count, invariant breaks and step time. No game data
//! goes in the report: counts, command numbers and types, block coordinates.

const std = @import("std");
const sim = @import("sim");
const formats = @import("formats");
const qa = @import("qa");
const main = @import("main.zig");
const Autopilot = @import("autopilot.zig").Autopilot;
const fx = sim.fx;
const c = sim.c;
const abi = sim.abi;
const Frame = sim.input.Frame;

const S = sim.Sim(sim.config_sp);
var s: S = undefined;
var checker: qa.Checker(S) = .{};

const stuck_ticks = 3000;

const Stuck = struct { thread: u16, cmd: u16, kind: u16, ticks: u32 };

pub fn runLevel(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, report: *std.ArrayList(u8), grid: *const abi.Grid, m: *const formats.gmp.Map, name: []const u8, o: main.Options) !bool {
    const stem_name = name[0 .. name.len - 4];
    var ld = try formats.level.build(gpa, m);
    defer ld.deinit(gpa);
    var level = ld.level;

    // Scripts.
    const cwd = std.Io.Dir.cwd();
    var pb: [1024]u8 = undefined;
    const main_bytes = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&pb, "{s}/{s}.scr", .{ o.data, stem_name }), gpa, .unlimited);
    defer gpa.free(main_bytes);
    var parsed_main = try formats.scr.parseMain(gpa, main_bytes);
    defer parsed_main.deinit();
    level.script = parsed_main.script;

    var names: std.ArrayList([]const u8) = .empty;
    var blobs: std.ArrayList([]u8) = .empty;
    defer {
        for (blobs.items) |b| gpa.free(b);
        blobs.deinit(gpa);
    }
    if (cwd.openDir(io, try std.fmt.bufPrint(&pb, "{s}/{s}", .{ o.data, stem_name }), .{ .iterate = true })) |d0| {
        var d = d0;
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if (std.ascii.endsWithIgnoreCase(e.name, ".scr")) try names.append(arena, try arena.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        for (names.items) |n| try blobs.append(gpa, try d.readFileAlloc(io, n, gpa, .unlimited));
    } else |_| {}
    var parsed: std.ArrayList(formats.scr.Parsed) = .empty;
    defer {
        for (parsed.items) |*p| p.deinit();
        parsed.deinit(gpa);
    }
    for (names.items, blobs.items) |n, b| try parsed.append(gpa, try formats.scr.parseMission(gpa, b, formats.scr.stem(n)));
    const missions = try arena.alloc(sim.level.Script, parsed.items.len);
    for (parsed.items, missions) |p, *out| out.* = p.script;
    level.missions = missions;

    // Waypoints for when nothing else points anywhere.
    const roads = try main.roadCells(grid, gpa);
    defer gpa.free(roads);

    s.init(grid, .{ .seed = o.seed, .mode = .authoritative });
    s.attachLevel(&level);
    checker = .{};
    var rng: main.Rng = .{ .x = o.seed | 1 };
    var ap: Autopilot = .{};
    var frames: [1]Frame = .{Frame.neutral(0)};
    var ps: qa.PlayStats = .{};
    var tr: qa.PlayStats.Tracker(S) = .{};

    var started: u32 = 0;
    var passed: u32 = 0;
    var failed: u32 = 0;
    var rings: u32 = 0;
    var wasted: u32 = 0;
    var busted: u32 = 0;
    var game_over = false;
    var level_complete = false;
    var mission_t0: u64 = 0;
    var mission_log: std.ArrayList(u8) = .empty;
    var phone: ?[2]fx.Fx = null;
    var teleports: u32 = 0;
    var phones_visited: u32 = 0;
    var arrow_ticks: u64 = 0;
    var stuck: std.ArrayList(Stuck) = .empty;
    const times = try gpa.alloc(i64, o.ticks);
    defer gpa.free(times);
    var max_threads: u32 = 0;
    // Phones stood at, by entity id.
    var visited: std.ArrayList(u32) = .empty;
    var phone_visit: ?abi.EntityId = null;

    for (0..o.ticks) |ti| {
        // Target: the arrow, else the last phone that rang, else waypoints.
        const h = &s.state.sp.hud[0];
        var arrow: ?[2]fx.Fx = null;
        if (!h.arrow.isNone()) {
            if (s.state.world.get(h.arrow, c.Transform)) |t| arrow = .{ t.x, t.y };
        } else if (h.arrow_x != 0 or h.arrow_y != 0) arrow = .{ h.arrow_x, h.arrow_y };
        if (arrow) |a| {
            arrow_ticks += 1;
            ap.setTarget(a[0], a[1]);
        } else if (phone) |p| {
            ap.setTarget(p[0], p[1]);
        } else if (phone_visit == null) if (Autopilot.bodyTransform(S, &s, 0)) |bt| {
            phone_visit = nearestPhone(bt.x, bt.y, visited.items);
            if (phone_visit) |pv| if (s.state.world.get(pv, c.Transform)) |pt| ap.setTarget(pt.x, pt.y);
        };
        if (arrow == null and phone == null and phone_visit == null and !ap.has_target) {
            if (Autopilot.bodyTransform(S, &s, 0)) |t| {
                const w = main.pickWaypoint(&rng, roads, t.x, t.y);
                ap.setTarget(w[0], w[1]);
            }
        }
        frames[0] = ap.frame(S, &s, 0);
        // A phone visit ends once the player has stood on it a moment.
        if (phone_visit) |pv| {
            const w = &s.state.world;
            var done = !w.isAlive(pv) or arrow != null or phone != null;
            if (!done) if (Autopilot.bodyTransform(S, &s, 0)) |bt| if (w.get(pv, c.Transform)) |pt| {
                const d = fx.length(pt.x - bt.x, pt.y - bt.y);
                if (d < Autopilot.arrive_dist) {
                    // Walk the last blocks straight onto it.
                    if (d > fx.half) {
                        frames[0].buttons = sim.input.Button.direct;
                        frames[0].aim = fx.atan2(pt.y - bt.y, pt.x - bt.x);
                        frames[0].throttle = 127;
                    } else done = true;
                }
            };
            if (done) {
                try visited.append(arena, pv.raw);
                phone_visit = null;
                ap.has_target = false;
                phones_visited += 1;
            }
        }

        const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
        s.step(&frames, if (ti == 0) &.{.{ .op = .join, .slot = 0, .arg = 0 }} else &.{});
        times[ti] = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - t0);
        checker.check(&s);
        tr.after(&ps, &s);

        for (s.events()) |e| switch (e.kind) {
            .mission_start => {
                started += 1;
                mission_t0 = ti;
                phone = null;
                try main.appendf(&mission_log, arena, "  - tick {d}: mission started\n", .{ti});
            },
            .mission_pass => {
                passed += 1;
                try main.appendf(&mission_log, arena, "  - tick {d}: mission passed after {d} ticks\n", .{ ti, ti - mission_t0 });
            },
            .mission_fail => {
                failed += 1;
                try main.appendf(&mission_log, arena, "  - tick {d}: mission failed after {d} ticks\n", .{ ti, ti - mission_t0 });
            },
            .phone_ring => if (e.a != 0) {
                rings += 1;
                phone = .{ e.x, e.y };
            },
            .wasted => wasted += 1,
            .busted => busted += 1,
            .game_over => game_over = true,
            .level_complete => level_complete = true,
            else => {},
        };

        // The autopilot's trip.
        if (ap.has_target and s.pedOf(0) != null) {
            if (ap.distance(S, &s, 0)) |d| {
                if (d < Autopilot.arrive_dist) {
                    if (arrow == null and phone == null and phone_visit == null) ap.has_target = false;
                    // At a phone that has stopped ringing: forget it.
                    if (arrow == null and phone != null and ap.age > 300) phone = null;
                } else if (ap.age >= o.limit and phone_visit != null and arrow == null and phone == null) {
                    // Stand on the phone: the touch is what starts a mission.
                    teleports += 1;
                    ap.teleport(S, &s, 0);
                    ap.age = 0;
                } else if (ap.age >= o.limit) {
                    teleports += 1;
                    ap.teleport(S, &s, 0);
                    ap.age = 0;
                }
            }
        }

        // Threads on one command too long.
        const st = &s.state.sp.script;
        max_threads = @max(max_threads, st.threads);
        for (st.thread[0..st.threads]) |*t| {
            if (t.same == stuck_ticks) {
                const f = S.script.lookup(&s, t.cur);
                try stuck.append(arena, .{ .thread = t.id, .cmd = t.cur, .kind = if (f) |ff| ff.kind else 0, .ticks = @intCast(ti) });
            }
        }
        if (game_over) break;
    }
    tr.finish(&ps, &s);
    const n: usize = @max(@as(usize, 1), @min(o.ticks, @as(usize, @intCast(ps.ticks))));
    std.mem.sort(i64, times[0..n], {}, std.sort.asc(i64));
    var total: i64 = 0;
    for (times[0..n]) |t| total += t;

    try main.appendf(report, arena, "## {s}\n\n", .{name});
    try main.appendf(report, arena, "- scripts: main plus {d} mission sub-scripts; up to {d} threads live\n", .{ parsed.items.len, max_threads });
    try main.appendf(report, arena, "- ran {d} ticks{s}{s}\n", .{ ps.ticks, if (game_over) ", ended in game over" else "", if (level_complete) ", level complete" else "" });
    try main.appendf(report, arena, "- missions: {d} started, {d} passed, {d} failed; phones rang {d} times\n", .{ started, passed, failed, rings });
    try main.appendf(report, arena, "- player: wasted {d}, busted {d}; arrow shown {d} ticks; teleports {d}; phones stood at {d}\n", .{ wasted, busted, arrow_ticks, teleports, phones_visited });
    try main.appendf(report, arena, "- unhandled commands met: {d}\n", .{s.state.sp.script.unhandled});
    try main.appendf(report, arena, "- threads on one command for {d}+ ticks: {d}\n", .{ stuck_ticks, stuck.items.len });
    for (stuck.items[0..@min(stuck.items.len, 20)]) |x|
        try main.appendf(report, arena, "  - thread {d} at command {d} (type {d}), noticed at tick {d}\n", .{ x.thread, x.cmd, x.kind, x.ticks });
    try main.appendf(report, arena, "- step: mean {d:.4} ms, p99 {d:.4} ms, max {d:.4} ms\n", .{ main.ms(@divTrunc(total, @as(i64, @intCast(n)))), main.ms(times[n * 99 / 100]), main.ms(times[n - 1]) });
    try main.appendf(report, arena, "- invariant breaks: {d}\n", .{checker.total()});
    if (mission_log.items.len > 0) try main.appendf(report, arena, "- mission log:\n{s}", .{mission_log.items});
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("\n```\n", .{});
    try checker.report(&w);
    try ps.write(&w);
    try w.print("```\n\n", .{});
    try report.appendSlice(arena, w.buffered());
    return checker.total() == 0;
}

/// The nearest live phone not in `skip`.
fn nearestPhone(x: fx.Fx, y: fx.Fx, skip: []const u32) ?abi.EntityId {
    const Best = struct { id: ?abi.EntityId = null, d: fx.Fx = std.math.maxInt(fx.Fx) };
    var best: Best = .{};
    const Ctx = struct { best: *Best, x: fx.Fx, y: fx.Fx, skip: []const u32 };
    s.state.world.each(.{ c.Object, c.Transform }, Ctx{ .best = &best, .x = x, .y = y, .skip = skip }, struct {
        fn f(ctx: Ctx, id: abi.EntityId, o: *c.Object, t: *c.Transform) void {
            if (o.kind != @intFromEnum(sim.ids.ObjectKind.phone)) return;
            if (std.mem.indexOfScalar(u32, ctx.skip, id.raw) != null) return;
            const d = fx.length(t.x - ctx.x, t.y - ctx.y);
            if (d < ctx.best.d) ctx.best.* = .{ .id = id, .d = d };
        }
    }.f);
    return best.id;
}
