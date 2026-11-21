//! Traffic soak on a real map (workstream F): `level --traffic`.
//!
//! Runs the single-player configuration (48 ambient cars, no level script)
//! with the player on foot, moved to the pavement beside a random road
//! block every `move_ticks` so traffic fills different parts of the city,
//! and counts what goes wrong with the traffic AI: cars that give up
//! (abandoned), cars stopped for 300 ticks while nothing holds them
//! (stuck), cars driving against the arrows of their lane for 30 ticks
//! (wrong way), cars off the road for 20 ticks, car impacts, damaged and
//! wrecked cars. Block coordinates of the first few cases of each are
//! listed. No game data in the report.

const std = @import("std");
const sim = @import("sim");
const fx = sim.fx;
const c = sim.c;
const abi = sim.abi;
const Frame = sim.input.Frame;
const EntityId = abi.EntityId;

pub const S = sim.Sim(sim.config_sp);

const move_ticks = 2000;
const stuck_ticks = 300;
const wrong_ticks = 30;
const max_cases = 6;
const off_ticks = 20;
// `--trace N`: print the last 80 ticks of the first N cars that leave the
// road or drive the wrong way (debugging).
var trace_n: u32 = 0;
pub fn setTrace(n: u32) void {
    trace_n = n;
}

pub const Case = struct { x: i32, y: i32, z: i32, heading: u16, ai_flags: u8, dir: u8, arrows: u4 };

pub const Counts = struct {
    cars_max: u32 = 0,
    abandoned: u32 = 0,
    stuck: u32 = 0,
    wrong_way: u32 = 0,
    impacts: u64 = 0,
    damaged: u32 = 0,
    wrecked: u32 = 0,
    stuck_cases: [max_cases]Case = undefined,
    n_stuck: u32 = 0,
    wrong_cases: [max_cases]Case = undefined,
    n_wrong: u32 = 0,
    abandoned_cases: [max_cases]Case = undefined,
    n_abandoned: u32 = 0,
    left_road: u32 = 0,
    left_cases: [max_cases]Case = undefined,
    n_left: u32 = 0,
};

const cap = sim.config_sp.car_capacity;

const Track = struct {
    still: [cap]u32 = @splat(0),
    wrong: [cap]u32 = @splat(0),
    gave_up: [cap]bool = @splat(false),
    gen: [cap]u16 = @splat(0),
    off: [cap]u32 = @splat(0),
    last: [cap]Case = undefined,
    ring: [cap][80]Rec = undefined,
    printed: u32 = 0,
};
const Rec = struct { tick: u32, x: i32, y: i32, z: i32, h: u16, dir: u8, plan: u8, flags: u8, steer: i8, thr: i8, timer: u16 };

fn arrowsAt(s: *S, t: *const c.Transform) ?u4 {
    const cell = sim.map.floorCell(s.grid, t.x, t.y, t.z, sim.tuning.car_step);
    if (sim.map.groundOf(cell) != sim.map.Ground.road) return null;
    return sim.map.arrowsOf(cell);
}

fn caseOf(s: *S, v: *const c.Vehicle, t: *const c.Transform) Case {
    return .{ .x = fx.toInt(t.x), .y = fx.toInt(t.y), .z = fx.toInt(t.z), .heading = t.heading, .ai_flags = v.ai_flags, .dir = v.ai_dir, .arrows = arrowsAt(s, t) orelse 0 };
}

/// Opposite-arrow bit for heading `h` (the lane runs the other way).
fn againstLane(arrows: u4, h: u16) bool {
    if (@popCount(arrows) != 1) return false;
    const d: u2 = @intCast(((@as(u32, h) + 8192) >> 14) & 3);
    // Arrow bits as the sim's map uses them, per direction 0 +x, 1 +y, 2 -x, 3 -y.
    const bits = [4]u4{ sim.map.Arrow.pos_x, sim.map.Arrow.pos_y, sim.map.Arrow.neg_x, sim.map.Arrow.neg_y };
    return arrows == bits[(@as(u3, d) + 2) & 3];
}

fn pavementBeside(g: *const abi.Grid, x: i32, y: i32) ?[2]fx.Fx {
    const sx = [4]i32{ 1, 0, -1, 0 };
    const sy = [4]i32{ 0, 1, 0, -1 };
    var k: i32 = 1;
    while (k <= 4) : (k += 1) for (0..4) |d| {
        const px = fx.fromInt(x + sx[d] * k) + fx.half;
        const py = fx.fromInt(y + sy[d] * k) + fx.half;
        const z = sim.map.floorAt(g, px, py, fx.fromInt(sim.map.size_z - 1), sim.tuning.ped_step);
        if (z < 0) continue;
        if (sim.map.groundOf(sim.map.floorCell(g, px, py, z, sim.tuning.car_step)) == sim.map.Ground.pavement) return .{ px, py };
    };
    return null;
}

pub fn run(s: *S, grid: *abi.Grid, seed: u32, ticks: u32, roads: []const u32) Counts {
    s.init(grid, .{ .seed = seed, .mode = .authoritative });
    var frames = [1]Frame{Frame.neutral(0)};
    s.step(&frames, &.{.{ .op = .join, .slot = 0, .arg = 0 }});
    var tr: Track = .{};
    var out: Counts = .{};
    var rng: u32 = seed | 1;
    for (0..ticks) |ti| {
        if (ti % move_ticks == move_ticks - 1 and roads.len > 0) {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            const r = roads[@intCast((@as(u64, rng) * roads.len) >> 32)];
            // On the pavement beside the road, out of the traffic's way.
            if (pavementBeside(s.grid, @intCast(r % sim.map.size_x), @intCast(r / sim.map.size_x))) |p| {
                if (s.pedOf(0)) |ped| if (s.state.world.get(ped, c.Transform)) |t| {
                    t.x = p[0];
                    t.y = p[1];
                    t.z = sim.map.floorAt(s.grid, t.x, t.y, fx.fromInt(sim.map.size_z - 1), sim.tuning.ped_step);
                };
            }
        }
        frames[0] = Frame.neutral(@truncate(s.tick()));
        s.step(&frames, &.{});
        const Ctx = struct { s: *S, tr: *Track, out: *Counts, n: u32 = 0 };
        var ctx = Ctx{ .s = s, .tr = &tr, .out = &out };
        s.state.world.each(.{ c.Vehicle, c.Velocity, c.Transform, c.Controller }, &ctx, struct {
            fn f(cx: *Ctx, id: EntityId, v: *c.Vehicle, vel: *c.Velocity, t: *c.Transform, ctl: *c.Controller) void {
                const i = id.index();
                const tk: u32 = @intCast(cx.s.tick());
                cx.tr.ring[i][tk % 80] = .{ .tick = tk, .x = t.x >> 12, .y = t.y >> 12, .z = t.z >> 12, .h = t.heading, .dir = v.ai_dir, .plan = v.ai_plan, .flags = v.ai_flags, .steer = ctl.in.steer, .thr = ctl.in.throttle, .timer = v.timer };
                if (cx.tr.gen[i] != id.gen()) {
                    cx.tr.gen[i] = id.gen();
                    cx.tr.still[i] = 0;
                    cx.tr.wrong[i] = 0;
                    cx.tr.gave_up[i] = false;
                    cx.tr.off[i] = 0;
                    cx.tr.last[i] = caseOf(cx.s, v, t);
                }
                if (v.flags & c.Vehicle.flag_ai == 0 or v.flags & c.Vehicle.flag_wrecked != 0) return;
                cx.n += 1;
                const held = v.halt > 0 or v.ai_yield > 0 or v.ai_flags & (c.Vehicle.ai_halted | c.Vehicle.ai_abandoned) != 0;
                if (!held and fx.length(vel.vx, vel.vy) < fx.ratio(1, 100)) cx.tr.still[i] += 1 else cx.tr.still[i] = 0;
                if (cx.tr.still[i] == stuck_ticks) {
                    cx.out.stuck += 1;
                    if (cx.out.n_stuck < max_cases) {
                        cx.out.stuck_cases[cx.out.n_stuck] = caseOf(cx.s, v, t);
                        cx.out.n_stuck += 1;
                    }
                }
                if (arrowsAt(cx.s, t) != null) {
                    cx.tr.off[i] = 0;
                    cx.tr.last[i] = caseOf(cx.s, v, t);
                } else {
                    cx.tr.off[i] += 1;
                    if (cx.tr.off[i] == off_ticks) {
                        if (cx.tr.printed < trace_n) {
                            cx.tr.printed += 1;
                            std.debug.print("--- car {d} left road from {d},{d}\n", .{ i, cx.tr.last[i].x, cx.tr.last[i].y });
                            for (0..80) |k| {
                                const r = cx.tr.ring[i][(tk + 1 + k) % 80];
                                std.debug.print("t{d} {d},{d},{d} h{d} d{d} p{x} f{x} s{d} th{d} tm{d}\n", .{ r.tick, r.x, r.y, r.z, r.h, r.dir, r.plan, r.flags, r.steer, r.thr, r.timer });
                            }
                        }
                        cx.out.left_road += 1;
                        if (cx.out.n_left < max_cases) {
                            cx.out.left_cases[cx.out.n_left] = cx.tr.last[i];
                            cx.out.n_left += 1;
                        }
                    }
                }
                const moving = fx.length(vel.vx, vel.vy) > fx.ratio(2, 100);
                const a = arrowsAt(cx.s, t) orelse 0;
                if (moving and againstLane(a, t.heading)) cx.tr.wrong[i] += 1 else cx.tr.wrong[i] = 0;
                if (cx.tr.wrong[i] == wrong_ticks and cx.tr.printed < trace_n) {
                    cx.tr.printed += 1;
                    std.debug.print("--- car {d} wrong way\n", .{i});
                    for (0..80) |k| {
                        const r = cx.tr.ring[i][(tk + 1 + k) % 80];
                        std.debug.print("t{d} {d},{d},{d} h{d} d{d} p{x} f{x} s{d} th{d} tm{d}\n", .{ r.tick, r.x, r.y, r.z, r.h, r.dir, r.plan, r.flags, r.steer, r.thr, r.timer });
                    }
                }
                if (cx.tr.wrong[i] == wrong_ticks) {
                    cx.out.wrong_way += 1;
                    if (cx.out.n_wrong < max_cases) {
                        cx.out.wrong_cases[cx.out.n_wrong] = caseOf(cx.s, v, t);
                        cx.out.n_wrong += 1;
                    }
                }
                if (v.ai_flags & c.Vehicle.ai_abandoned != 0 and !cx.tr.gave_up[i]) {
                    cx.tr.gave_up[i] = true;
                    cx.out.abandoned += 1;
                    if (cx.out.n_abandoned < max_cases) {
                        cx.out.abandoned_cases[cx.out.n_abandoned] = caseOf(cx.s, v, t);
                        cx.out.n_abandoned += 1;
                    }
                }
            }
        }.f);
        out.cars_max = @max(out.cars_max, ctx.n);
    }
    out.impacts = s.scratch.stats.impacts;
    const Ctx = struct { out: *Counts };
    var ctx = Ctx{ .out = &out };
    s.state.world.each(.{ c.Vehicle, c.Health }, &ctx, struct {
        fn f(cx: *Ctx, _: EntityId, v: *c.Vehicle, hp: *c.Health) void {
            if (v.flags & c.Vehicle.flag_wrecked != 0) cx.out.wrecked += 1 else if (hp.hp < sim.tuning.car_damage_max) cx.out.damaged += 1;
        }
    }.f);
    return out;
}

pub fn write(w: *std.Io.Writer, o: Counts) !void {
    try w.print("- AI cars at once (max): {d}\n", .{o.cars_max});
    try w.print("- abandoned: {d}; stuck 300 ticks: {d}; wrong way 30 ticks: {d}\n", .{ o.abandoned, o.stuck, o.wrong_way });
    try w.print("- left the road for {d} ticks: {d}\n", .{ off_ticks, o.left_road });
    try w.print("- car impacts: {d}; cars damaged at the end: {d}; wrecked: {d}\n", .{ o.impacts, o.damaged, o.wrecked });
    try cases(w, "stuck", o.stuck_cases[0..o.n_stuck]);
    try cases(w, "wrong way", o.wrong_cases[0..o.n_wrong]);
    try cases(w, "abandoned", o.abandoned_cases[0..o.n_abandoned]);
    try cases(w, "left the road from", o.left_cases[0..o.n_left]);
    try w.print("\n", .{});
}

fn cases(w: *std.Io.Writer, what: []const u8, cs: []const Case) !void {
    for (cs) |k| try w.print("  - {s} at block {d},{d},{d} heading {d} dir {d} arrows {x} ai {x}\n", .{ what, k.x, k.y, k.z, k.heading, k.dir, k.arrows, k.ai_flags });
}

/// `--dump X,Y`: print the road around block (X, Y), one cell per block:
/// ground (`#` none, `_` pavement, `+` road without arrows, `*` several
/// arrows, `> < v ^` lanes) and the floor level.
pub fn dump(g: *const abi.Grid, cx: i32, cy: i32, r: i32) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const px = fx.fromInt(x) + fx.half;
            const py = fx.fromInt(y) + fx.half;
            const z = sim.map.floorAt(g, px, py, fx.fromInt(sim.map.size_z - 1), sim.tuning.ped_step);
            const cell = sim.map.floorCell(g, px, py, z, sim.tuning.car_step);
            const gr = sim.map.groundOf(cell);
            const a = sim.map.arrowsOf(cell);
            const ch: u8 = if (gr != sim.map.Ground.road) (if (gr == sim.map.Ground.pavement) '_' else '#') else switch (a) {
                sim.map.Arrow.pos_x => '>',
                sim.map.Arrow.neg_x => '<',
                sim.map.Arrow.pos_y => 'v',
                sim.map.Arrow.neg_y => '^',
                0 => '+',
                else => '*',
            };
            std.debug.print("{c}{d}", .{ ch, @as(u32, @intCast(@max(0, fx.toInt(z)))) % 10 });
        }
        std.debug.print("   y={d}\n", .{y});
    }
}
