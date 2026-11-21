//! The S5 handling bench: one car driven by one player on sim/'s synthetic
//! test map, with handling from sim/ (docs/behaviour/car-handling.md) and
//! per-model numbers from the player's own `.gci` and style car info, read
//! through formats/. Nothing here models the car itself; it only sets up the
//! sim, feeds it input and reports what it did.
//!
//! JavaScript copies a file into memory from `alloc`, then calls `loadSty`
//! or `loadGci`; `step(bits)` runs one tick (30 a second) and `view()`
//! points at the car's state for drawing.

const std = @import("std");
const builtin = @import("builtin");
const formats = @import("formats");
const sim = @import("sim");
const abi = @import("interfaces").abi;
const input = @import("interfaces").input;
const Frame = input.Frame;
const B = input.Button;
const fx = sim.fx;
const Fx = fx.Fx;
const T = sim.tuning;
const c = sim.c;

const gpa = if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;

const cfg: abi.Config = .{ .name = "s5bench", .max_players = 1, .car_capacity = 4, .ped_capacity = 4, .projectile_capacity = 4, .pickup_capacity = 4, .map_object_capacity = 4 };
const S = sim.Sim(cfg);

var grid: abi.Grid = undefined;
var game: S = undefined;
var probe: S = undefined;
var car: sim.ecs.EntityId = .none;
var ready = false;

// --------------------------------------------------------------- car models

/// The style's car info we keep after loading (the style itself is freed).
const Info = struct { model: u8, w: i32, h: i32, fw: i32, rw: i32, sprite: i32, ambient: bool };

var infos: [T.max_car_models]Info = undefined;
var info_count: usize = 0;
var records: [256]formats.gci.Record = undefined;
var record_count: usize = 0;

/// One bench entry per model: a CarSpec the tuning panel edits, the model
/// number and whether its sizes came from the style.
var specs: [T.max_car_models]T.CarSpec = undefined;
var numbers: [T.max_car_models]u8 = undefined;
var skid: [T.max_car_models]Fx = undefined;
var value: [T.max_car_models]u8 = undefined;
var from_sty: [T.max_car_models]bool = undefined;
var count: usize = 1;
var current: usize = 0;
var have_gci = false;

fn applyRecord(sp: *T.CarSpec, r: *const formats.gci.Record) void {
    sp.mass = r.get(.mass);
    sp.front_drive_bias = r.get(.front_drive_bias);
    sp.front_mass_bias = r.get(.front_mass_bias);
    sp.brake_friction = r.get(.brake_friction);
    sp.turn_in = r.get(.turn_in);
    sp.turn_ratio = r.get(.turn_ratio);
    sp.rear_end_stability = r.get(.rear_end_stability);
    sp.handbrake_slide = r.get(.handbrake_slide);
    sp.thrust = r.get(.thrust);
    sp.max_speed = r.get(.max_speed);
    sp.anti_strength = r.get(.anti_strength);
    sp.gear1 = r.get(.gear1_multiplier);
    sp.gear2 = r.get(.gear2_multiplier);
    sp.gear3 = r.get(.gear3_multiplier);
    sp.gear2_speed = r.get(.gear2_speed);
    sp.gear3_speed = r.get(.gear3_speed);
    sp.turbo = r.turbo;
}

/// Rebuild the bench's model list from what is loaded: one entry per style
/// car when a style is loaded, else one per `.gci` record, else the sim's
/// default model alone.
fn rebuild() void {
    const prev_number: ?u8 = if (current < count and have_gci) numbers[current] else null;
    have_gci = record_count > 0;
    if (info_count > 0) {
        count = info_count;
        for (infos[0..info_count], 0..) |ci, i| {
            var sp = T.default_spec;
            skid[i] = 0;
            value[i] = 0;
            for (records[0..record_count]) |*r| if (r.model == ci.model) {
                applyRecord(&sp, r);
                skid[i] = r.get(.skid_threshold);
                value[i] = r.value;
                break;
            };
            sp.w_px = ci.w;
            sp.h_px = ci.h;
            sp.front_wheel_px = ci.fw;
            sp.rear_wheel_px = ci.rw;
            sp.sprite = ci.sprite;
            sp.ambient = ci.ambient;
            specs[i] = sp;
            numbers[i] = ci.model;
            from_sty[i] = true;
        }
    } else if (record_count > 0) {
        count = @min(record_count, T.max_car_models);
        for (records[0..count], 0..) |*r, i| {
            var sp = T.default_spec;
            applyRecord(&sp, r);
            specs[i] = sp;
            numbers[i] = r.model;
            skid[i] = r.get(.skid_threshold);
            value[i] = r.value;
            from_sty[i] = false;
        }
    } else {
        count = 1;
        specs[0] = T.default_spec;
        numbers[0] = 0;
        skid[0] = 0;
        value[0] = 0;
        from_sty[0] = false;
    }
    current = 0;
    if (prev_number) |n| for (numbers[0..count], 0..) |m, i| if (m == n) {
        current = i;
        break;
    };
    install();
    reset();
}

fn install() void {
    if (!have_gci and info_count == 0) {
        T.setCarModels(&.{});
        return;
    }
    var models: [T.max_car_models]T.CarModel = undefined;
    for (specs[0..count], models[0..count]) |sp, *m| m.* = T.deriveModel(sp);
    T.setCarModels(models[0..count]);
}

// --------------------------------------------------------------- the world

/// Start of the bench: the east-bound lane of the top road of the test
/// city, with the open fields behind (west of x = 32).
const start_x = 40;
const start_y = 34;

/// Fresh sim with the player in the current model on the road. The whole
/// sim restarts, so a reset leaves nothing from the last run.
fn setup(s: *S, bx: u8, by: u8, heading: u16) ?sim.ecs.EntityId {
    var fr: [1]Frame = .{Frame.neutral(0)};
    s.init(&grid, .{ .seed = 1, .mode = .authoritative });
    // Ped one block behind the car, facing it, so enter works at once.
    const fwd_x: i32 = if (heading == 0) 1 else 0;
    const fwd_y: i32 = if (heading == 0x4000) 1 else 0;
    const px: u32 = @intCast(@as(i32, bx) - fwd_x);
    const py: u32 = @intCast(@as(i32, by) - fwd_y);
    s.step(&fr, &.{.{ .op = .join, .slot = 0, .arg = px | (py << 8) }});
    const id = s.spawnCarAt(fx.fromInt(bx) + fx.half, fx.fromInt(by) + fx.half, heading, @intCast(current)) orelse return null;
    if (s.pedOf(0)) |ped| if (s.transformOf(ped)) |t| {
        t.heading = heading;
    };
    fr[0].buttons = B.enter_exit;
    s.step(&fr, &.{});
    fr[0] = Frame.neutral(0);
    s.step(&fr, &.{});
    return id;
}

fn reset() void {
    if (!ready) return;
    car = setup(&game, start_x, start_y, 0) orelse .none;
    impact = 0;
}

fn frameFor(bits: u32) Frame {
    var f = Frame.neutral(@truncate(game.tick()));
    if (bits & 1 != 0) f.throttle = 127;
    if (bits & 2 != 0) f.throttle = -127;
    if (bits & 1 != 0 and bits & 2 != 0) f.throttle = 0;
    // The original is digital: left and right together is no steering.
    if (bits & 4 != 0) f.steer -= 127;
    if (bits & 8 != 0) f.steer += 127;
    if (bits & 16 != 0) f.buttons |= B.handbrake_jump;
    return f;
}

// --------------------------------------------------------------- exports

export fn init() void {
    sim.testmap.build(&grid);
    ready = true;
    rebuild();
}

export fn alloc(n: usize) ?[*]u8 {
    const s = gpa.alignedAlloc(u8, .@"4", n) catch return null;
    return s.ptr;
}
export fn free(p: [*]u8, n: usize) void {
    gpa.free(@as([]align(4) u8, @alignCast(p[0..n])));
}

/// Style file: keeps its car info. Returns the car count, or -1 not a
/// style, -2 truncated or unreadable, -3 no car info.
export fn loadSty(p: [*]const u8, n: usize) i32 {
    var st = formats.sty.parse(gpa, p[0..n]) catch |e| return switch (e) {
        error.OutOfMemory => -2,
        else => if (n < 4 or !std.mem.eql(u8, p[0..4], formats.sty.magic)) -1 else -2,
    };
    defer st.deinit();
    if (st.cars.len == 0) return -3;
    info_count = @min(st.cars.len, T.max_car_models);
    for (st.cars[0..info_count], infos[0..info_count], 0..) |ci, *o, i| o.* = .{
        .model = ci.model,
        .w = ci.w,
        .h = ci.h,
        .fw = ci.front_wheel,
        .rw = ci.rear_wheel,
        .sprite = st.carSprite(i),
        .ambient = ci.num_doors > 0 and ci.h <= 120 and ci.info_flags & 1 == 0,
    };
    rebuild();
    return @intCast(info_count);
}

/// `.gci` text. Returns the record count, or -1 unreadable token, -2 not a
/// whole number of records, -3 too many records.
export fn loadGci(p: [*]const u8, n: usize) i32 {
    const recs = formats.gci.parse(gpa, p[0..n]) catch |e| return switch (e) {
        error.BadToken => -1,
        error.BadLength => -2,
        error.OutOfMemory => -3,
    };
    defer gpa.free(recs);
    if (recs.len > records.len) return -3;
    @memcpy(records[0..recs.len], recs);
    record_count = recs.len;
    rebuild();
    return @intCast(recs.len);
}

export fn usePlaceholders() void {
    record_count = 0;
    info_count = 0;
    rebuild();
}

/// 1 when the handling numbers come from the player's `.gci`.
export fn source() i32 {
    return @intFromBool(have_gci);
}
export fn styCount() i32 {
    return @intCast(info_count);
}
export fn modelCount() i32 {
    return @intCast(count);
}
export fn modelNumber(i: u32) i32 {
    return if (i < count) numbers[i] else -1;
}
export fn hasStyDims(i: u32) i32 {
    return @intFromBool(i < count and from_sty[i]);
}
/// Whether a style car has a `.gci` record with its model number.
export fn hasRecord(i: u32) i32 {
    if (i >= count) return 0;
    if (!from_sty[i]) return @intFromBool(have_gci);
    for (records[0..record_count]) |r| if (r.model == numbers[i]) return 1;
    return 0;
}
/// Style cars whose front wheel is not ahead of the rear one.
export fn styWheelsBehind() i32 {
    var k: i32 = 0;
    for (infos[0..info_count]) |ci| k += @intFromBool(ci.fw <= ci.rw);
    return k;
}
/// Models whose gears break gear 2 speed <= gear 3 speed <= max speed (the
/// game refuses such a file).
export fn badGears() i32 {
    var k: i32 = 0;
    for (records[0..record_count]) |r| k += @intFromBool(!(r.get(.gear2_speed) <= r.get(.gear3_speed) and r.get(.gear3_speed) <= r.get(.max_speed)));
    return k;
}
export fn recordCount() i32 {
    return @intCast(record_count);
}
export fn currentModel() i32 {
    return @intCast(current);
}
export fn selectModel(i: u32) void {
    if (i >= count) return;
    current = i;
    reset();
}
export fn resetCar() void {
    reset();
}

// --------------------------------------------------------------- tuning

/// Tunable numbers in `.gci` order (skid threshold kept for the record
/// only: it drives skid effects, not handling), then the style geometry.
const field_names = [_][]const u8{ "mass", "front_drive_bias", "front_mass_bias", "brake_friction", "turn_in", "turn_ratio", "rear_end_stability", "handbrake_slide", "thrust", "max_speed", "anti_strength", "skid_threshold", "gear1", "gear2", "gear3", "gear2_speed", "gear3_speed" };
const dim_names = [_][]const u8{ "w_px", "h_px", "front_wheel_px", "rear_wheel_px" };

export fn getField(i: u32) i32 {
    const sp = &specs[current];
    inline for (field_names, 0..) |n, k| if (i == k) {
        if (comptime std.mem.eql(u8, n, "skid_threshold")) return skid[current];
        return @field(sp, n);
    };
    return 0;
}
export fn setField(i: u32, v: i32) void {
    const sp = &specs[current];
    inline for (field_names, 0..) |n, k| if (i == k) {
        if (comptime std.mem.eql(u8, n, "skid_threshold")) skid[current] = v else @field(sp, n) = v;
    };
    retune();
}
export fn getDim(i: u32) i32 {
    const sp = &specs[current];
    inline for (dim_names, 0..) |n, k| if (i == k) return @field(sp, n);
    return 0;
}
export fn setDim(i: u32, v: i32) void {
    const sp = &specs[current];
    inline for (dim_names, 0..) |n, k| if (i == k) {
        @field(sp, n) = std.math.clamp(v, if (k < 2) 4 else -127, 127);
    };
    retune();
}
export fn turbo() i32 {
    return @intFromBool(specs[current].turbo);
}
export fn setTurbo(on: bool) void {
    specs[current].turbo = on;
    retune();
}
export fn recordValue() i32 {
    return value[current];
}

/// Install the edited model without moving the car (tuning is offline and
/// this host is the only one).
fn retune() void {
    if (!have_gci and info_count == 0) {
        // Placeholder: still honour edits to the one default model.
        var m = [1]T.CarModel{T.deriveModel(specs[0])};
        T.setCarModels(&m);
        return;
    }
    install();
}

// --------------------------------------------------------------- stepping

var impact: Fx = 0;
var view_buf: [24]i32 = @splat(0);

export fn step(bits: u32) void {
    if (!ready or car.isNone()) return;
    const w = &game.state.world;
    const before = if (w.get(car, c.Velocity)) |v| v.* else return;
    var fr = [1]Frame{frameFor(bits)};
    game.step(&fr, &.{});
    const after = w.get(car, c.Velocity) orelse return;
    // A sudden change of velocity beyond what the tyres do: a hit.
    const dv = fx.length(after.vx - before.vx, after.vy - before.vy);
    impact = if (dv > fx.ratio(4, 100)) dv else 0;
}

/// [x, y, z, heading (65536 a turn), vx, vy, spin (radians a tick), speed,
///  pedal quarters, brake quarters, handbrake ticks, drive, flags, damage,
///  tick, half_len, half_wid, front_axle, rear_axle, impact, gear2_speed,
///  gear3_speed, max_speed, forward speed]  (fixed point 16.16 unless
///  noted)
export fn view() [*]const i32 {
    const v = &view_buf;
    const w = &game.state.world;
    if (car.isNone()) return v;
    const t = w.get(car, c.Transform) orelse return v;
    const vel = w.get(car, c.Velocity).?;
    const veh = w.get(car, c.Vehicle).?;
    const hp = w.get(car, c.Health).?;
    const m = T.carModel(veh.model);
    v[0] = t.x;
    v[1] = t.y;
    v[2] = t.z;
    v[3] = t.heading;
    v[4] = vel.vx;
    v[5] = vel.vy;
    v[6] = vel.spin;
    v[7] = fx.length(vel.vx, vel.vy);
    v[8] = veh.pedal;
    v[9] = veh.brake;
    v[10] = veh.handbrake_n;
    v[11] = veh.drive;
    v[12] = veh.flags;
    v[13] = T.car_damage_max - hp.hp;
    v[14] = @intCast(game.tick());
    v[15] = m.half_len;
    v[16] = m.half_wid;
    v[17] = m.front_axle;
    v[18] = m.rear_axle;
    v[19] = impact;
    v[20] = m.gear2_speed;
    v[21] = m.gear3_speed;
    v[22] = m.max_speed;
    v[23] = fx.mul(vel.vx, fx.cos(t.heading)) + fx.mul(vel.vy, fx.sin(t.heading));
    return v;
}

// --------------------------------------------------------------- the map

export fn mapSize() i32 {
    return sim.map.size_x;
}

/// The top of one column: bits 0-3 layer of the highest matter (0 street
/// level), 4-6 its shape, 8-9 ground type, 12-15 lid arrows.
export fn mapCell(x: u32, y: u32) u32 {
    var z: i32 = sim.map.size_z - 1;
    while (z >= 0) : (z -= 1) {
        const cell = sim.map.cellAt(&grid, @intCast(x), @intCast(y), z);
        const sh = sim.map.shapeOf(cell);
        if (sh == sim.map.Shape.air or sh == sim.map.Shape.water) continue;
        return @as(u32, @intCast(z)) | (@as(u32, sh) << 4) | (@as(u32, sim.map.groundOf(cell)) << 8) | (@as(u32, sim.map.arrowsOf(cell)) << 12);
    }
    return 0;
}

// --------------------------------------------------------------- self-test and measuring

/// 10,000 scripted ticks of the current model from a fixed start, hashed.
/// The native test prints the value the page compares against.
export fn selfTest() u32 {
    const keep = current;
    defer current = keep;
    current = 0;
    const saved_count = T.car_model_count;
    var saved: [T.max_car_models]T.CarModel = undefined;
    @memcpy(saved[0..saved_count], T.car_models[0..saved_count]);
    defer T.setCarModels(saved[0..saved_count]);
    T.setCarModels(&.{});
    _ = setup(&probe, start_x, start_y, 0) orelse return 0;
    var rng: u32 = 0x5eed;
    var bits: u32 = 1;
    var fr: [1]Frame = undefined;
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        if (i % 45 == 0) {
            rng = rng *% 1664525 +% 1013904223;
            bits = (rng >> 24) & 31;
        }
        var f = Frame.neutral(@truncate(probe.tick()));
        if (bits & 1 != 0) f.throttle = 127 else if (bits & 2 != 0) f.throttle = -127;
        if (bits & 4 != 0) f.steer = -127 else if (bits & 8 != 0) f.steer = 127;
        if (bits & 16 != 0) f.buttons = B.handbrake_jump;
        fr[0] = f;
        probe.step(&fr, &.{});
    }
    const h = probe.hash();
    return @truncate(h ^ (h >> 32));
}

var measure_buf: [6]i32 = @splat(0);

/// The current model on the open fields west of the city (x < 32), driving
/// south: [top speed, ticks to 90% of it, ticks to stop from top, stopping
/// distance, ticks for one full-lock circle, its diameter].
export fn measure() [*]const i32 {
    const out = &measure_buf;
    out.* = @splat(0);
    const id = setup(&probe, 16, 4, 0x4000) orelse return out;
    const w = &probe.state.world;
    var fr = [1]Frame{Frame.neutral(0)};
    const v = w.get(id, c.Velocity).?;
    const t = w.get(id, c.Transform).?;
    // Full throttle from rest for 8 s.
    fr[0].throttle = 127;
    var speeds: [240]Fx = undefined;
    for (&speeds) |*s| {
        probe.step(&fr, &.{});
        s.* = fx.length(v.vx, v.vy);
    }
    var top: Fx = 0;
    for (speeds) |s| top = @max(top, s);
    out[0] = top;
    for (speeds, 0..) |s, k| if (@as(i64, s) * 10 >= @as(i64, top) * 9) {
        out[1] = @intCast(k + 1);
        break;
    };
    // Brake from there to a stop.
    fr[0].throttle = -127;
    const y0 = t.y;
    var k: i32 = 0;
    while (k < 600) : (k += 1) {
        const fwd = fx.mul(v.vx, fx.cos(t.heading)) + fx.mul(v.vy, fx.sin(t.heading));
        if (fwd <= 0) break;
        probe.step(&fr, &.{});
    }
    out[2] = k;
    out[3] = t.y - y0;
    // Full lock right at full throttle in the middle of the fields: let it
    // settle, then time one full turn and measure its extent.
    const id2 = setup(&probe, 16, 128, 0) orelse return out;
    const v2 = w.get(id2, c.Velocity).?;
    _ = v2;
    const t2 = w.get(id2, c.Transform).?;
    fr[0] = Frame.neutral(0);
    fr[0].throttle = 127;
    fr[0].steer = 127;
    for (0..150) |_| probe.step(&fr, &.{});
    var turned: i64 = 0;
    var last = t2.heading;
    var min_x = t2.x;
    var max_x = t2.x;
    var min_y = t2.y;
    var max_y = t2.y;
    var n: i32 = 0;
    while (n < 900 and @abs(turned) < 65536) : (n += 1) {
        probe.step(&fr, &.{});
        const d: i16 = @bitCast(t2.heading -% last);
        turned += d;
        last = t2.heading;
        min_x = @min(min_x, t2.x);
        max_x = @max(max_x, t2.x);
        min_y = @min(min_y, t2.y);
        max_y = @max(max_y, t2.y);
    }
    out[4] = if (@abs(turned) >= 65536) n else 0;
    out[5] = @divTrunc((max_x - min_x) + (max_y - min_y), 2);
    return out;
}

test "the bench drives the default car and the self-test is stable" {
    init();
    const x0 = view()[0];
    for (0..60) |_| step(1);
    const v = view();
    try std.testing.expect(v[0] > x0 + fx.one);
    try std.testing.expect(v[8] > 0);
    const h = selfTest();
    try std.testing.expectEqual(h, selfTest());
    std.debug.print("\nself-test hash {x:0>8}\n", .{h});
    const m = measure();
    std.debug.print("top {d:.2} blk/s, 90% in {d:.2} s, stop {d:.2} s over {d:.2} blk, circle {d:.2} s, {d:.2} blk\n", .{
        @as(f64, @floatFromInt(m[0])) / 65536.0 * 30.0,
        @as(f64, @floatFromInt(m[1])) / 30.0,
        @as(f64, @floatFromInt(m[2])) / 30.0,
        @as(f64, @floatFromInt(m[3])) / 65536.0,
        @as(f64, @floatFromInt(m[4])) / 30.0,
        @as(f64, @floatFromInt(m[5])) / 65536.0,
    });
}

test "a .gci and a tuned field change the model" {
    init();
    const text =
        \\{Bench car}
        \\0 {model} 0 {turbo} 50 0
        \\f16.500 f1.000 f0.500 f1.750 f0.145 f0.450 f1.250 f0.180 f0.152
        \\f0.245 f1.000 f0.065 f0.550 f0.680 f1.000 f0.107 f0.165
    ;
    try std.testing.expectEqual(@as(i32, 1), loadGci(text.ptr, text.len));
    try std.testing.expectEqual(@as(i32, 1), source());
    try std.testing.expectEqual(@as(i32, 1), modelCount());
    setField(9, fx.ratio(1, 10));
    try std.testing.expectEqual(fx.ratio(1, 10), T.carModel(0).max_speed);
    for (0..300) |_| step(1);
    try std.testing.expect(view()[7] <= fx.ratio(1, 10) + 1);
    usePlaceholders();
    try std.testing.expectEqual(@as(i32, 0), source());
}
