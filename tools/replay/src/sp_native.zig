//! `replay sp-record <dir>` and `replay sp-verify <dir>`: the single-player
//! golden. Recording drives the player with the level runner's autopilot
//! (to the phone, then to the mission car, then around the city) and keeps
//! only its input frames; verifying replays them and compares hash() every
//! tick, with a save/run-ahead/load rewind every 100 ticks, the invariant
//! checker on, and the play summary (invariant breaks included) compared
//! with summary.txt.

const std = @import("std");
const common = @import("common.zig");
const qa = @import("qa.zig");
const sp = @import("sp.zig");
const Autopilot = @import("autopilot").Autopilot;
const sim = common.sim;
const abi = sim.abi;
const fx = sim.fx;
const Frame = sim.input.Frame;
const S = sp.S;

var s: S = undefined;
var golden: sp.Golden = .{};
var checker: qa.Checker(S) = .{};
var save_buf: [S.state_size]u8 align(8) = undefined;
const print = std.debug.print;

fn blk(b: i32) fx.Fx {
    return fx.fromInt(b) + fx.half;
}

/// What the run did, in play terms; summary.txt holds the recorded one.
const Summary = struct {
    started: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    rings: u32 = 0,
    wasted: u32 = 0,
    busted: u32 = 0,
    heartbeat: i32 = 0,
    missions_passed: i32 = 0,
    stage: i32 = 0,
    unhandled: u32 = 0,
    max_threads: u32 = 0,
    first_start: u32 = 0,
    /// Recorded, not required to be 0: a break that a merge fixes changes
    /// the golden, and one it adds fails the check.
    invariant_breaks: u32 = 0,

    fn after(m: *Summary, t: u32) void {
        for (s.events()) |e| switch (e.kind) {
            .mission_start => {
                m.started += 1;
                if (m.first_start == 0) m.first_start = t;
            },
            .mission_pass => m.passed += 1,
            .mission_fail => m.failed += 1,
            .phone_ring => if (e.a != 0) {
                m.rings += 1;
            },
            .wasted => m.wasted += 1,
            .busted => m.busted += 1,
            else => {},
        };
        const st = &s.state.sp.script;
        m.max_threads = @max(m.max_threads, st.threads);
    }

    fn finish(m: *Summary) void {
        const st = &s.state.sp.script;
        m.heartbeat = st.slot[1];
        m.missions_passed = st.slot[2];
        m.stage = st.slot[3];
        m.unhandled = st.unhandled;
        m.invariant_breaks = @intCast(checker.total());
    }

    fn write(m: Summary, w: *std.Io.Writer) !void {
        inline for (@typeInfo(Summary).@"struct".field_names) |f| try w.print("{s} {d}\n", .{ f, @field(m, f) });
    }
};

fn start(gpa: std.mem.Allocator, grid: *const abi.Grid, sd: u64) !void {
    var line: usize = 0;
    golden.start(gpa, &s, grid, sd, &line) catch |e| {
        print("sp_golden.sasm line {d}: {s}\n", .{ line, @errorName(e) });
        return e;
    };
}

pub fn record(io: std.Io, gpa: std.mem.Allocator, grid: *const abi.Grid, dir: []const u8) !void {
    try start(gpa, grid, sp.seed);
    defer golden.deinit();
    checker = .{};
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var hdr: [common.header_size]u8 = undefined;
    (common.Header{ .seed = sp.seed, .players = 1, .ticks = sp.ticks, .grid_hash = sim.map.gridHash(grid) }).write(&hdr);
    try body.appendSlice(gpa, &hdr);
    const hashes = try gpa.alloc(u64, sp.ticks + 1);
    defer gpa.free(hashes);
    hashes[0] = s.hash();

    // The route: the phone, the mission car, then a loop round the city.
    const route = [_][2]i32{ .{ 34, 34 }, .{ 34, 98 }, .{ 98, 98 }, .{ 98, 34 } };
    var leg: usize = 0;
    var ap: Autopilot = .{};
    var m: Summary = .{};
    var cbuf: [4]abi.Command = undefined;
    var frames: [1]Frame = .{Frame.neutral(0)};
    for (0..sp.ticks) |ti| {
        const t: u32 = @intCast(ti);
        if (m.started == 0) {
            ap.setTarget(blk(26), blk(20));
        } else if (m.missions_passed == 0 and s.state.sp.script.slot[2] == 0) {
            ap.setTarget(blk(30), blk(26));
        } else {
            ap.setTarget(blk(route[leg][0]), blk(route[leg][1]));
            if (ap.distance(S, &s, 0)) |d| if (d < Autopilot.arrive_dist * 2) {
                leg = (leg + 1) % route.len;
            };
        }
        frames[0] = if (t == 0) Frame.neutral(0) else ap.frame(S, &s, 0);
        // The autopilot stops 3 blocks short; walk the rest of the way.
        if (m.started == 0 and t > 0) if (s.pedOf(0)) |p| {
            const pt = s.state.world.get(p, sim.c.Transform).?;
            const dx = ap.target_x - pt.x;
            const dy = ap.target_y - pt.y;
            if (fx.length(dx, dy) < Autopilot.arrive_dist) {
                frames[0].buttons = sim.input.Button.direct;
                frames[0].aim = fx.atan2(dy, dx);
                frames[0].throttle = 127;
            }
        };
        const cmds = sp.commands(t, &cbuf);
        try common.writeTick(&body, gpa, cmds, &frames);
        s.step(&frames, cmds);
        hashes[t + 1] = s.hash();
        checker.check(&s);
        m.after(t);
    }
    m.finish();
    try common.writeDir(io, dir, "inputs.bin", body.items);
    try common.writeDir(io, dir, "hashes.bin", std.mem.sliceAsBytes(hashes));
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try m.write(&w);
    try common.writeDir(io, dir, "summary.txt", w.buffered());
    print("sp golden recorded: {d} ticks, initial {x:0>16} final {x:0>16}\n{s}", .{ sp.ticks, hashes[0], hashes[sp.ticks], w.buffered() });
    var rb: [8192]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&rb);
    try checker.report(&rw);
    print("{s}", .{rw.buffered()});
}

pub fn verify(io: std.Io, gpa: std.mem.Allocator, grid: *const abi.Grid, dir: []const u8) !bool {
    const in_bytes = try common.readDir(io, gpa, dir, "inputs.bin");
    defer gpa.free(in_bytes);
    const h_bytes = try common.readDir(io, gpa, dir, "hashes.bin");
    defer gpa.free(h_bytes);
    const want_summary = try common.readDir(io, gpa, dir, "summary.txt");
    defer gpa.free(want_summary);
    const hdr = try common.Header.read(in_bytes);
    const hashes: []align(1) const u64 = std.mem.bytesAsSlice(u64, h_bytes);
    if (hdr.grid_hash != sim.map.gridHash(grid) or hdr.players != 1 or hashes.len != hdr.ticks + 1) return error.BadReplay;
    try start(gpa, grid, hdr.seed);
    defer golden.deinit();
    checker = .{};
    if (s.hash() != hashes[0]) {
        print("SP MISMATCH at init: got {x:0>16} want {x:0>16}\n", .{ s.hash(), hashes[0] });
        return false;
    }
    var frames: [1]Frame = .{Frame.neutral(0)};
    var fa: [1]Frame = .{Frame.neutral(0)};
    var cbuf: [64]abi.Command = undefined;
    var ca: [64]abi.Command = undefined;
    var pos: usize = common.header_size;
    var rewinds: u32 = 0;
    var m: Summary = .{};
    var t: u32 = 0;
    while (t < hdr.ticks) : (t += 1) {
        if (t % 100 == 50 and t + 10 < hdr.ticks) {
            _ = s.save(&save_buf);
            var p2 = pos;
            for (0..10) |_| {
                const r = try common.readTick(in_bytes, p2, 1, &ca, &fa);
                s.step(&fa, r.cmds);
                p2 = r.next;
            }
            try s.load(&save_buf);
            rewinds += 1;
        }
        const r = try common.readTick(in_bytes, pos, 1, &cbuf, &frames);
        pos = r.next;
        s.step(&frames, r.cmds);
        if (s.hash() != hashes[t + 1]) {
            print("SP MISMATCH at tick {d}: got {x:0>16} want {x:0>16}\n", .{ t + 1, s.hash(), hashes[t + 1] });
            return false;
        }
        checker.check(&s);
        m.after(t);
    }
    m.finish();
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try m.write(&w);
    var ok = true;
    if (!std.mem.eql(u8, w.buffered(), want_summary)) {
        print("SP summary differs from summary.txt:\n{s}", .{w.buffered()});
        ok = false;
    }
    if (checker.total() != 0) {
        print("(invariant breaks are compared through summary.txt)\n", .{});
        var rb: [8192]u8 = undefined;
        var rw: std.Io.Writer = .fixed(&rb);
        try checker.report(&rw);
        print("{s}", .{rw.buffered()});
    }
    print("sp verify {s}: {d} ticks, {d} rewinds, final {x:0>16}, invariant breaks {d}\n", .{ if (ok) "OK" else "FAILED", hdr.ticks, rewinds, hashes[hdr.ticks], checker.total() });
    return ok;
}
