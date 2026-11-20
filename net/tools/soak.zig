//! Headless network soak: one authoritative server, one predicting client
//! over the fake link, AI traffic and peds, and bot players that chase or
//! wander. Prints correction sizes, drawn gap at contact, frame-to-frame
//! jerk, replay depth and bandwidth per case. Deterministic per seed.
//!
//!   zig build -Doptimize=ReleaseFast && zig-out/bin/soak [seconds] [--only TEXT]
//!   zig build -Dsim=real -Doptimize=ReleaseFast && zig-out/bin/soak [seconds] [--map file.gmp]
//!
//! `-Dsim=real` runs sim/ (dm16) on the synthetic test map or a real map;
//! the default is the stand-in arena sim.

const std = @import("std");
const itf = @import("interfaces");
const net = @import("net");
const abi = itf.abi;
const wire = itf.wire;
const input = itf.input;
const world = @import("soak_world");

pub const cfg = world.cfg;
const S = world.S;
var map_path: ?[]const u8 = null;
const Sc = net.schema.Schema(S);
const Cl = net.client.Client(S);
const Enc = net.encoder.ClientEncoder(S);
const Hist = net.encoder.History(S);
const tick_ms = net.client.tick_ms;

const print = std.debug.print;
var debug = false;

pub const Case = struct {
    name: []const u8,
    rtt: f64 = 150,
    jitter: f64 = 10,
    loss: f64 = 0.02,
    burst: f64 = 0,
    bots: u32 = 3,
    bot_mode: enum { chase, wander, flick } = .chase,
    budget: u32 = 400,
    predict_radius: f32 = 6,
    smooth_own: f32 = 100,
    smooth_other: f32 = 250,
    interp_ms: f32 = 100,
    fade_speed: f32 = 4,
    fast_near: bool = false,
    /// Background the tab at 30 s for this many ms (0 = never).
    hitch_ms: f64 = 0,
};

const Driver = struct {
    rng: std.Random.DefaultPrng,
    steer: i8 = 0,
    hb: bool = false,
    until: f64 = 0,
    fn next(d: *Driver, now: f64) input.Frame {
        const r = d.rng.random();
        if (now >= d.until) {
            const p = r.float(f64);
            d.steer = if (p < 0.15) 0 else if (r.boolean()) -127 else 127;
            d.hb = r.float(f64) < 0.3;
            d.until = now + 300 + r.float(f64) * 1200;
        }
        return .{ .steer = d.steer, .throttle = 127, .buttons = if (d.hb) input.Button.handbrake_jump else 0, .aim = 0, .seq = 0 };
    }
};

fn botFrame(s: *S, slot: u32, mode: anytype, tick: u32) input.Frame {
    const st = s.stateBytes();
    const row = Sc.playerRow(st, slot);
    if (row.car.isNone()) return input.Frame.neutral(0);
    const me = Sc.transform(st, 0, row.car.index()).?;
    var tx: abi.Fx = 0;
    var ty: abi.Fx = 0;
    switch (mode) {
        .chase => {
            const tgt = Sc.playerRow(st, 0).car;
            const t = Sc.transform(st, 0, tgt.index()).?;
            tx = t.x;
            ty = t.y;
        },
        else => {
            const r = abi.rand(99, tick / 45, row.car, 7);
            tx = @intCast(world.wander_lo * abi.fx_one + @as(i64, r % world.wander_x) * abi.fx_one);
            ty = @intCast(world.wander_lo * abi.fx_one + @as(i64, (r >> 10) % world.wander_y) * abi.fx_one);
        },
    }
    const want = world.atan2(ty - me.y, tx - me.x);
    const diff: i16 = @bitCast(want -% me.heading);
    var steer = std.math.clamp(@divTrunc(@as(i32, diff), 40), -127, 127);
    if (mode == .flick) {
        // Human-like: snap the stick to full lock or centre.
        steer = if (steer > 30) 127 else if (steer < -30) -127 else 0;
    }
    const v = Sc.velocity(st, 0, row.car.index()).?;
    const speed = @max(@abs(v.vx), @abs(v.vy));
    const hb = mode == .chase and @abs(diff) > 12000 and speed > 9000;
    const thr: i8 = if (@abs(diff) > 22000) 50 else 127;
    return .{ .steer = @intCast(steer), .throttle = thr, .buttons = if (hb) input.Button.handbrake_jump else 0, .aim = 0, .seq = 0 };
}

const Result = struct {
    own_n: u64,
    own_p95: f32,
    own_max: f32,
    pred_n: u64,
    pred_p95: f32,
    pred_max: f32,
    gap_p50: f32,
    gap_max: f32,
    contacts: u64,
    jerk_own_p99: f32,
    jerk_own_over: u64,
    jerk_rem_p99: f32,
    jerk_rem_over: u64,
    max_off: f32,
    replay_avg: f32,
    replay_max: u32,
    kbps: f64,
    max_bytes: u32,
    upd_hz_near: f64,
    stale_avg: f64,
    repeated: u64,
    snaps: u64,
    hitches: u64,
    resyncs: u64,
    replay_us: f64,
    rec_bytes: f64,
};

fn run(gpa: std.mem.Allocator, c: Case, seconds: f64, seed: u64) !Result {
    const grid = try gpa.create(abi.Grid);
    defer gpa.destroy(grid);
    try world.buildGrid(gpa, g_io, grid, map_path);
    const srv = try gpa.create(S);
    defer gpa.destroy(srv);
    srv.init(grid, .{ .seed = seed, .mode = .authoritative });

    var hist = try Hist.init(gpa);
    defer hist.deinit(gpa);
    var enc = try Enc.init(gpa, .{ .budget = c.budget });
    defer enc.deinit(gpa);
    enc.own_slots[0] = 0;
    var ib: net.inputbuf.InputBuffer = .{};
    var cl = try Cl.init(gpa, grid, 0, .{
        .smooth_ms_own = c.smooth_own,
        .smooth_ms_other = c.smooth_other,
        .interp_ms = c.interp_ms,
        .max_fade_speed = c.fade_speed,
        .fast_fade_near = c.fast_near,
        .predict_enter = c.predict_radius,
        .predict_leave = c.predict_radius + 2,
    });
    defer cl.deinit();

    var up = net.link.Link.init(seed *% 31 + 1);
    var down = net.link.Link.init(seed *% 31 + 2);
    for ([_]*net.link.Link{ &up, &down }) |l| {
        l.one_way_ms = c.rtt / 2;
        l.jitter_ms = c.jitter;
        l.loss = c.loss;
        l.burst_end = c.burst;
    }

    // Session start: players join, world fills up for 3 s.
    var frames: [cfg.max_players]input.Frame = @splat(input.Frame.neutral(0));
    var joins: [cfg.max_players]abi.Command = undefined;
    for (0..c.bots + 1) |p| joins[p] = .{ .op = .join, .slot = @intCast(p), .arg = 0 };
    srv.step(&frames, joins[0 .. c.bots + 1]);
    world.seatPlayers(srv, &frames, c.bots + 1);
    if (debug) {
        var seated: u32 = 0;
        for (0..c.bots + 1) |p| {
            if (!Sc.playerRow(srv.stateBytes(), @intCast(p)).car.isNone()) seated += 1;
        }
        print("  seated {d}/{d}\n", .{ seated, c.bots + 1 });
    }
    for (0..150) |_| srv.step(&frames, &.{});

    var buf: [65536]u8 = undefined;
    var rbuf: [net.link.max_msg]u8 = undefined;
    var driver: Driver = .{ .rng = std.Random.DefaultPrng.init(seed + 7) };

    // Baseline on the reliable stream: delivered after one-way latency.
    const g0 = hist.push(srv);
    const base = try enc.encode(&hist, g0, .{ .seq = 0, .tick = srv.tick(), .echo_time = 0, .hold_ms = 0, .players = &.{} }, enc.center(hist.get(g0).?), &buf, true);
    const base_copy = try gpa.dupe(u8, base);
    defer gpa.free(base_copy);

    const t0: f64 = 0;
    var srv_n: u32 = 0;
    const srv_tick0 = srv.tick();
    var echo: u16 = 0;
    var echo_at: f64 = 0;
    var started = false;

    var jerk_own: std.ArrayList(f32) = .empty;
    defer jerk_own.deinit(gpa);
    var jerk_rem: std.ArrayList(f32) = .empty;
    defer jerk_rem.deinit(gpa);
    var gaps: std.ArrayList(f32) = .empty;
    defer gaps.deinit(gpa);
    var prev_own: ?[2]f32 = null;
    var prev_d_own: ?[2]f32 = null;
    var rem_track: ?struct { f: u32, p: [2]f32, d: ?[2]f32 } = null;
    var max_off: f32 = 0;
    var near_updates: u64 = 0;
    var near_samples: u64 = 0;
    var replay_ns: u64 = 0;

    const frame_ms = 1000.0 / 60.0;
    var now: f64 = t0;
    var hitch_done = c.hitch_ms == 0;
    while (now < seconds * 1000) : (now += frame_ms) {
        // Background tab: no frames, no client ticks, server carries on.
        if (!hitch_done and now >= 30000) {
            hitch_done = true;
            const end = now + c.hitch_ms;
            while (now < end) : (now += frame_ms) {
                try serverUpdate(srv, &hist, &enc, &ib, &up, &down, &buf, &rbuf, &frames, c, now, &srv_n, srv_tick0, &echo, &echo_at);
            }
        }
        // Server.
        try serverUpdate(srv, &hist, &enc, &ib, &up, &down, &buf, &rbuf, &frames, c, now, &srv_n, srv_tick0, &echo, &echo_at);

        // Client.
        if (!started and now >= c.rtt / 2) {
            try cl.onSnapshot(base_copy, now);
            started = true;
        }
        if (!started) continue;
        while (down.poll(now, &rbuf)) |m| {
            const ta = nowNs();
            try cl.onSnapshot(m, now);
            replay_ns += nowNs() - ta;
            // Update rate of entities near the own car.
        }
        const f = driver.next(now);
        const ticks = cl.update(now, f);
        for (0..ticks) |_| {}
        if (ticks > 0) {
            const d = try cl.writeInput(&buf, now);
            up.send(now, d);
        }

        if (debug and @mod(@as(u64, @intFromFloat(now / frame_ms)), 300) == 0) {
            const st = srv.stateBytes();
            for (0..@min(c.bots + 1, 4)) |p| {
                const row = Sc.playerRow(st, @intCast(p));
                if (row.car.isNone()) continue;
                const t = Sc.transform(st, 0, row.car.index()).?;
                print("  t={d:.0} p{d} car ({d:.1},{d:.1})\n", .{ now, p, @as(f32, @floatFromInt(t.x)) / 65536, @as(f32, @floatFromInt(t.y)) / 65536 });
            }
        }
        // Measurements after warm-up.
        if (now < 5000) continue;
        const own = cl.ownEntity() orelse continue;
        const op = cl.displayPose(own.k, own.i, now).?;
        const cur = [2]f32{ op.x, op.y };
        if (prev_own) |p| {
            const d = [2]f32{ cur[0] - p[0], cur[1] - p[1] };
            if (prev_d_own) |pd| try jerk_own.append(gpa, std.math.hypot(d[0] - pd[0], d[1] - pd[1]));
            prev_d_own = d;
        }
        prev_own = cur;
        const oe = &cl.ents[Sc.flat(own.k, own.i)];
        max_off = @max(max_off, std.math.hypot(oe.off.x, oe.off.y));

        // Nearest other car: drawn gap at contact, and its jerk.
        const st = cl.sim.stateBytes();
        const ot = Sc.transform(st, own.k, own.i).?;
        var best: ?u32 = null;
        var best_d: i64 = std.math.maxInt(i64);
        var i: u32 = 0;
        while (i < cfg.car_capacity) : (i += 1) {
            if (i == own.i or !Sc.alive(st, 0, i)) continue;
            const t = Sc.transform(st, 0, i).?;
            const dd = std.math.hypot(@as(f64, @floatFromInt(t.x - ot.x)), @as(f64, @floatFromInt(t.y - ot.y)));
            const di: i64 = @intFromFloat(dd);
            if (di < best_d) {
                best_d = di;
                best = i;
            }
            if (dd <= 2.05 * @as(f64, @floatFromInt(world.car_r))) {
                const p = cl.displayPose(0, i, now).?;
                const gap = std.math.hypot(p.x - op.x, p.y - op.y) - 2 * @as(f32, @floatFromInt(world.car_r)) / 65536.0;
                try gaps.append(gpa, @max(gap, 0));
            }
        }
        if (best) |b| {
            if (best_d < 8 * abi.fx_one) {
                near_samples += 1;
                const p = cl.displayPose(0, b, now).?;
                const pc = [2]f32{ p.x, p.y };
                if (rem_track) |*rt| {
                    if (rt.f == b) {
                        const d = [2]f32{ pc[0] - rt.p[0], pc[1] - rt.p[1] };
                        if (rt.d) |pd| {
                            const jj = std.math.hypot(d[0] - pd[0], d[1] - pd[1]);
                            try jerk_rem.append(gpa, jj);
                            if (debug and jj > 0.5) {
                                const e = &cl.ents[Sc.flat(0, b)];
                                print("  big jerk {d:.2} t={d:.0} car {d} pred={} off=({d:.2},{d:.2}) nh={d} last_hist={d} cltick={d} srvoff={d:.1} p=({d:.2},{d:.2})\n", .{ jj, now, b, e.pred, e.off.x, e.off.y, e.nh, if (e.nh > 0) e.hist[e.nh - 1].tick else 0, cl.sim.tick(), cl.srv_offset.? + now / tick_ms, p.x, p.y });
                            }
                        }
                        rt.d = d;
                        rt.p = pc;
                    } else rem_track = .{ .f = b, .p = pc, .d = null };
                } else rem_track = .{ .f = b, .p = pc, .d = null };
            } else rem_track = null;
        }
    }
    _ = &near_updates;

    std.sort.pdq(f32, jerk_own.items, {}, std.sort.asc(f32));
    std.sort.pdq(f32, jerk_rem.items, {}, std.sort.asc(f32));
    std.sort.pdq(f32, gaps.items, {}, std.sort.asc(f32));
    const q = struct {
        fn f(a: []const f32, x: f32) f32 {
            if (a.len == 0) return 0;
            return a[@min(a.len - 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(a.len)) * x)))];
        }
    }.f;
    var over_own: u64 = 0;
    for (jerk_own.items) |j| if (j > 0.075) {
        over_own += 1;
    };
    var over_rem: u64 = 0;
    for (jerk_rem.items) |j| if (j > 0.075) {
        over_rem += 1;
    };

    return .{
        .own_n = cl.corr[0].total,
        .own_p95 = cl.corr[0].quantile(0.95),
        .own_max = cl.corr[0].quantile(1),
        .pred_n = cl.corr[1].total,
        .pred_p95 = cl.corr[1].quantile(0.95),
        .pred_max = cl.corr[1].quantile(1),
        .gap_p50 = q(gaps.items, 0.5),
        .gap_max = q(gaps.items, 0.99),
        .contacts = gaps.items.len,
        .jerk_own_p99 = q(jerk_own.items, 0.99),
        .jerk_own_over = over_own,
        .jerk_rem_p99 = q(jerk_rem.items, 0.99),
        .jerk_rem_over = over_rem,
        .max_off = max_off,
        .replay_avg = @as(f32, @floatFromInt(cl.stats.replay_ticks)) / @as(f32, @floatFromInt(@max(cl.stats.replays, 1))),
        .replay_max = cl.stats.max_replay,
        .kbps = @as(f64, @floatFromInt(enc.stats.bytes)) * 8 / 1000 / (seconds),
        .max_bytes = enc.stats.max_bytes,
        .upd_hz_near = 0,
        .stale_avg = @as(f64, @floatFromInt(enc.stats.staleness_sum)) / @as(f64, @floatFromInt(@max(enc.stats.snapshots, 1))),
        .repeated = ib.stats.repeated,
        .snaps = cl.stats.snaps,
        .hitches = cl.stats.hitches,
        .resyncs = cl.stats.resyncs,
        .rec_bytes = @as(f64, @floatFromInt(enc.stats.bytes - 18 * enc.stats.snapshots)) / @as(f64, @floatFromInt(@max(enc.stats.records, 1))),
        .replay_us = @as(f64, @floatFromInt(replay_ns)) / 1000 / @as(f64, @floatFromInt(@max(cl.stats.replays, 1))),
    };
}

var g_io: std.Io = undefined;
fn nowNs() u64 {
    return @intCast(std.Io.Timestamp.now(g_io, .awake).nanoseconds);
}

fn serverUpdate(
    srv: *S,
    hist: *Hist,
    enc: *Enc,
    ib: *net.inputbuf.InputBuffer,
    up: *net.link.Link,
    down: *net.link.Link,
    buf: []u8,
    rbuf: *[net.link.max_msg]u8,
    frames: *[cfg.max_players]input.Frame,
    c: Case,
    now: f64,
    srv_n: *u32,
    srv_tick0: u32,
    echo: *u16,
    echo_at: *f64,
) !void {
    // Inputs that have arrived.
    while (up.poll(now, rbuf)) |m| {
        var r: wire.Reader = .{ .buf = m };
        var po: [wire.max_local_players]wire.InputPlayer = undefined;
        var fo: [wire.max_local_players][wire.max_redundancy]input.Frame = undefined;
        const d = wire.decodeInput(&r, &po, &fo) catch continue;
        const into = now - (@as(f64, @floatFromInt(srv_n.*)) * tick_ms);
        const phase: u32 = @intFromFloat(std.math.clamp(into / tick_ms * 1024, 0, 1023));
        for (d.players) |p| if (p.slot == 0) ib.receive(p, srv.tick(), phase, @intFromFloat(now));
        enc.ack(d.header.ack_seq, d.header.ack_bits);
        echo.* = d.header.send_time;
        echo_at.* = now;
    }
    while (now >= @as(f64, @floatFromInt(srv_n.* + 1)) * tick_ms) {
        srv_n.* += 1;
        const t = srv.tick();
        frames[0] = ib.consume(t);
        var b: u32 = 1;
        while (b <= c.bots) : (b += 1) frames[b] = botFrame(srv, b, c.bot_mode, t);
        srv.step(frames, &.{});
        const nt = srv.tick() - srv_tick0;
        // 20 Hz snapshots from a 30 Hz sim: after ticks 2, 3, 5, 6, ...
        if (@divFloor(nt * 2, 3) != @divFloor((nt - 1) * 2, 3)) {
            const g = hist.push(srv);
            const players = [_]wire.SnapshotPlayer{.{ .slot = 0, .input_ack = ib.inputAck(), .slack_q = ib.slackQ(@intFromFloat(now)) }};
            const hold: u16 = @intFromFloat(@max(0, now - echo_at.*));
            const bytes = try enc.encode(hist, g, .{ .seq = 0, .tick = srv.tick(), .echo_time = echo.*, .hold_ms = hold, .players = &players }, enc.center(hist.get(g).?), buf, false);
            down.send(now, bytes);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    g_io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var seconds: f64 = 120;
    var only: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--map") and i + 1 < args.len) {
            map_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--only") and i + 1 < args.len) {
            only = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--debug")) {
            debug = true;
        } else seconds = try std.fmt.parseFloat(f64, a);
    }
    const cases = [_]Case{
        .{ .name = "0 ms, 0% loss, 3 chasers", .rtt = 0, .jitter = 0, .loss = 0 },
        .{ .name = "150 ms +-10, 2%, 3 chasers", .rtt = 150 },
        .{ .name = "same, S3 smoothing (100 ms, no cap)", .rtt = 150, .smooth_other = 100, .fade_speed = 0 },
        .{ .name = "same, fast fade near own car", .rtt = 150, .fast_near = true },
        .{ .name = "same, predict own car only", .rtt = 150, .predict_radius = 0 },
        .{ .name = "same, predict radius 3", .rtt = 150, .predict_radius = 3 },
        .{ .name = "150 ms, 2%, 3 flickers", .rtt = 150, .bot_mode = .flick },
        .{ .name = "same, S3 smoothing", .rtt = 150, .bot_mode = .flick, .smooth_other = 100, .fade_speed = 0 },
        .{ .name = "150 ms, 2%, 7 wanderers", .rtt = 150, .bots = 7, .bot_mode = .wander },
        .{ .name = "same, S3 smoothing", .rtt = 150, .bots = 7, .bot_mode = .wander, .smooth_other = 100, .fade_speed = 0 },
        .{ .name = "150 ms, 2%, 15 chasers, 187 B", .rtt = 150, .bots = 15, .budget = 187 },
        .{ .name = "same, 300 B (48 kbit/s)", .rtt = 150, .bots = 15, .budget = 300 },
        .{ .name = "same, 400 B (64 kbit/s)", .rtt = 150, .bots = 15, .budget = 400 },
        .{ .name = "250 ms +-30, 5% bursty, 3 chasers", .rtt = 250, .jitter = 30, .loss = 0.05, .burst = 0.5 },
        .{ .name = "150 ms, 2%, 3 s background tab", .rtt = 150, .hitch_ms = 3000 },
    };
    print("{s}{s}{s}: {d} s per case, 60 fps frames; errors in blocks\n\n", .{ world.name, if (map_path != null) " on " else "", map_path orelse "", seconds });
    print("| case | own corr n | own p95 | own max | other pred corr n | p95 | max | gap at contact p50 | p99 | contacts | own jerk p99 | own jerk >0.075 | near-car jerk p99 | >0.075 | max own offset | replay avg/max | replay us | kbit/s | max B | B/record | stalest upd avg | srv repeats | snaps | hitch/resync |\n", .{});
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n", .{});
    for (cases) |c| {
        if (only) |o| if (std.mem.indexOf(u8, c.name, o) == null) continue;
        const r = try run(gpa, c, seconds, 1);
        print("| {s} | {d} | {d:.3} | {d:.3} | {d} | {d:.3} | {d:.3} | {d:.3} | {d:.3} | {d} | {d:.4} | {d} | {d:.4} | {d} | {d:.3} | {d:.1}/{d} | {d:.0} | {d:.1} | {d} | {d:.1} | {d:.2} | {d} | {d} | {d}/{d} |\n", .{
            c.name,       r.own_n,         r.own_p95,      r.own_max,     r.pred_n,      r.pred_p95,   r.pred_max,
            r.gap_p50,    r.gap_max,       r.contacts,     r.jerk_own_p99, r.jerk_own_over, r.jerk_rem_p99, r.jerk_rem_over,
            r.max_off,    r.replay_avg,    r.replay_max,   r.replay_us,   r.kbps,        r.max_bytes,  r.rec_bytes, r.stale_avg,
            r.repeated,   r.snaps,         r.hitches,      r.resyncs,
        });
    }
}
