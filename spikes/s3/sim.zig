//! Spike S3 throwaway sim: one player car and one bot car on a flat arena
//! with pillars. Fixed-point only (Q16.16), no floats at runtime, no
//! allocation. Several independent world "slots" live in linear memory so
//! one page can run the server sim and the client's predicted sim side by
//! side, and save/load is a plain byte copy.

const FRAC = 16;
const ONE: i32 = 1 << FRAC;

pub const ARENA_W: i32 = 2400 * ONE;
pub const ARENA_H: i32 = 1600 * ONE;
const CAR_R: i32 = 18 * ONE;
const PILLAR_R: i32 = 36 * ONE;

const Car = extern struct {
    x: i32,
    y: i32,
    vx: i32, // world units per tick, Q16
    vy: i32,
    heading: i32, // 0..65535 = full turn
    angvel: i32, // heading units per tick
    steer: i32, // last applied input, -127..127
    throttle: i32, // -127..127
    buttons: i32, // bit0 = handbrake
};

const World = extern struct {
    tick: u32,
    _pad: u32,
    cars: [2]Car,
};

const MAX_SLOTS = 8;
var slots: [MAX_SLOTS]World = undefined;

const Pillar = struct { x: i32, y: i32 };
const pillars = [_]Pillar{
    .{ .x = 600 * ONE, .y = 400 * ONE },
    .{ .x = 1200 * ONE, .y = 800 * ONE },
    .{ .x = 1800 * ONE, .y = 400 * ONE },
    .{ .x = 600 * ONE, .y = 1200 * ONE },
    .{ .x = 1800 * ONE, .y = 1200 * ONE },
    .{ .x = 1200 * ONE, .y = 300 * ONE },
    .{ .x = 1200 * ONE, .y = 1300 * ONE },
};

// Sine table, built at compile time; runtime only reads integers.
const SIN_BITS = 12;
const SIN_N = 1 << SIN_BITS;
const sin_table: [SIN_N]i32 = blk: {
    @setEvalBranchQuota(200000);
    var t: [SIN_N]i32 = undefined;
    for (0..SIN_N) |i| {
        const a: f64 = @as(f64, @floatFromInt(i)) * (2.0 * 3.14159265358979323846) / @as(f64, SIN_N);
        t[i] = @intFromFloat(@round(@sin(a) * @as(f64, ONE)));
    }
    break :blk t;
};

fn sinA(h: i32) i32 {
    const idx: u32 = @intCast((h & 0xFFFF) >> (16 - SIN_BITS));
    return sin_table[idx];
}
fn cosA(h: i32) i32 {
    return sinA(h + 16384);
}

fn mul(a: i32, b: i32) i32 {
    return @intCast((@as(i64, a) * @as(i64, b)) >> FRAC);
}
fn div(a: i32, b: i32) i32 {
    return @intCast(@divTrunc(@as(i64, a) << FRAC, @as(i64, b)));
}
fn clamp(v: i32, lo: i32, hi: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}
fn absI(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn isqrt64(n: u64) u64 {
    if (n == 0) return 0;
    var x: u64 = n;
    var y: u64 = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}
/// length of (dx, dy) in Q16
fn len(dx: i32, dy: i32) i32 {
    const s: u64 = @intCast(@as(i64, dx) * dx + @as(i64, dy) * dy);
    return @intCast(isqrt64(s));
}

// Handling constants (per tick at 30 Hz).
const ACCEL: i32 = 58982; // 0.9 u/tick^2
const BRAKE: i32 = 98304; // 1.5
const REVERSE_ACCEL: i32 = 32768;
const DRAG: i32 = 2949; // fraction of forward speed lost per tick
const GRIP: i32 = 19661; // 0.30 of lateral speed removed per tick
const GRIP_SLIDE: i32 = 5243; // 0.08 when sliding hard
const GRIP_HANDBRAKE: i32 = 2621; // 0.04
const SLIDE_THRESHOLD: i32 = 3 * ONE;
const MAX_TURN: i32 = 1214; // ~200 deg/s
const FULL_TURN_SPEED: i32 = 6 * ONE;

fn stepCar(c: *Car) void {
    const fx = cosA(c.heading);
    const fy = sinA(c.heading);
    // right vector = (-fy, fx)
    var vf = mul(c.vx, fx) + mul(c.vy, fy);
    var vl = mul(c.vx, -fy) + mul(c.vy, fx);
    const hb = (c.buttons & 1) != 0;
    const thr = c.throttle;

    if (thr > 0) {
        vf += @divTrunc(ACCEL * thr, 127);
    } else if (thr < 0) {
        if (vf > ONE / 2) {
            vf += @divTrunc(BRAKE * thr, 127);
        } else {
            vf += @divTrunc(REVERSE_ACCEL * thr, 127);
        }
    }
    if (hb) vf -= mul(vf, 1311); // handbrake bleeds speed
    vf -= mul(vf, DRAG);
    if (thr == 0 and absI(vf) < ONE / 8) vf = 0;

    const grip = if (hb) GRIP_HANDBRAKE else if (absI(vl) > SLIDE_THRESHOLD) GRIP_SLIDE else GRIP;
    vl -= mul(vl, grip);

    // steering: rate scales with forward speed, flips in reverse
    const speed_factor = clamp(div(vf, FULL_TURN_SPEED), -ONE, ONE);
    var target = mul(@divTrunc(MAX_TURN * c.steer, 127) * ONE, speed_factor) >> FRAC;
    if (hb) target = @divTrunc(target * 3, 2);
    c.angvel += @divTrunc(target - c.angvel, 3);
    c.heading = (c.heading + c.angvel) & 0xFFFF;

    c.vx = mul(vf, fx) + mul(vl, -fy);
    c.vy = mul(vf, fy) + mul(vl, fx);
    c.x += c.vx;
    c.y += c.vy;
}

fn collideWalls(c: *Car) void {
    if (c.x < CAR_R) {
        c.x = CAR_R;
        if (c.vx < 0) c.vx = -mul(c.vx, 19661);
    }
    if (c.x > ARENA_W - CAR_R) {
        c.x = ARENA_W - CAR_R;
        if (c.vx > 0) c.vx = -mul(c.vx, 19661);
    }
    if (c.y < CAR_R) {
        c.y = CAR_R;
        if (c.vy < 0) c.vy = -mul(c.vy, 19661);
    }
    if (c.y > ARENA_H - CAR_R) {
        c.y = ARENA_H - CAR_R;
        if (c.vy > 0) c.vy = -mul(c.vy, 19661);
    }
}

fn collidePillars(c: *Car) void {
    for (pillars) |p| {
        const dx = c.x - p.x;
        const dy = c.y - p.y;
        const minD = CAR_R + PILLAR_R;
        if (absI(dx) >= minD or absI(dy) >= minD) continue;
        const d = len(dx, dy);
        if (d >= minD or d == 0) continue;
        const nx = div(dx, d);
        const ny = div(dy, d);
        c.x = p.x + mul(nx, minD);
        c.y = p.y + mul(ny, minD);
        const vn = mul(c.vx, nx) + mul(c.vy, ny);
        if (vn < 0) {
            // remove normal component and bounce back 30%
            const k = vn + mul(vn, 19661);
            c.vx -= mul(k, nx);
            c.vy -= mul(k, ny);
        }
    }
}

fn collideCars(a: *Car, b: *Car) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const minD = 2 * CAR_R;
    if (absI(dx) >= minD or absI(dy) >= minD) return;
    const d = len(dx, dy);
    if (d >= minD) return;
    var nx: i32 = ONE;
    var ny: i32 = 0;
    if (d != 0) {
        nx = div(dx, d);
        ny = div(dy, d);
    }
    const push = @divTrunc(minD - d, 2);
    a.x -= mul(nx, push);
    a.y -= mul(ny, push);
    b.x += mul(nx, push);
    b.y += mul(ny, push);
    const van = mul(a.vx, nx) + mul(a.vy, ny);
    const vbn = mul(b.vx, nx) + mul(b.vy, ny);
    const rel = van - vbn;
    if (rel > 0) {
        // equal masses, restitution 0.4: impulse = (1+e)/2 * rel
        const j = mul(rel, 45875); // 0.7
        a.vx -= mul(j, nx);
        a.vy -= mul(j, ny);
        b.vx += mul(j, nx);
        b.vy += mul(j, ny);
        // a knock spins both cars a little, which is what makes bumps hard to predict
        a.angvel += @divTrunc(j, 1024);
        b.angvel -= @divTrunc(j, 1024);
    }
}

// ---- exported ABI -------------------------------------------------------

export fn stateSize() u32 {
    return @sizeOf(World);
}
export fn slotPtr(slot: u32) usize {
    return @intFromPtr(&slots[slot]);
}
export fn init(slot: u32) void {
    const w = &slots[slot];
    w.* = .{ .tick = 0, ._pad = 0, .cars = undefined };
    w.cars[0] = .{ .x = 300 * ONE, .y = 800 * ONE, .vx = 0, .vy = 0, .heading = 0, .angvel = 0, .steer = 0, .throttle = 0, .buttons = 0 };
    w.cars[1] = .{ .x = 2100 * ONE, .y = 800 * ONE, .vx = 0, .vy = 0, .heading = 32768, .angvel = 0, .steer = 0, .throttle = 0, .buttons = 0 };
}
export fn copySlot(dst: u32, src: u32) void {
    slots[dst] = slots[src];
}
export fn setInput(slot: u32, car: u32, steer: i32, throttle: i32, buttons: i32) void {
    const c = &slots[slot].cars[car];
    c.steer = clamp(steer, -127, 127);
    c.throttle = clamp(throttle, -127, 127);
    c.buttons = buttons;
}
/// Advance one tick using each car's stored input.
export fn step(slot: u32) void {
    const w = &slots[slot];
    for (&w.cars) |*c| stepCar(c);
    collideCars(&w.cars[0], &w.cars[1]);
    for (&w.cars) |*c| {
        collidePillars(c);
        collideWalls(c);
    }
    w.tick +%= 1;
}
export fn tick(slot: u32) u32 {
    return slots[slot].tick;
}
export fn carX(slot: u32, car: u32) i32 {
    return slots[slot].cars[car].x;
}
export fn carY(slot: u32, car: u32) i32 {
    return slots[slot].cars[car].y;
}
export fn carH(slot: u32, car: u32) i32 {
    return slots[slot].cars[car].heading;
}
export fn carVX(slot: u32, car: u32) i32 {
    return slots[slot].cars[car].vx;
}
export fn carVY(slot: u32, car: u32) i32 {
    return slots[slot].cars[car].vy;
}
export fn hash(slot: u32) u32 {
    const bytes: [*]const u8 = @ptrCast(&slots[slot]);
    var h: u32 = 2166136261;
    for (0..@sizeOf(World)) |i| {
        h ^= bytes[i];
        h *%= 16777619;
    }
    return h;
}
export fn pillarCount() u32 {
    return pillars.len;
}
export fn pillarX(i: u32) i32 {
    return pillars[i].x;
}
export fn pillarY(i: u32) i32 {
    return pillars[i].y;
}
export fn pillarR() i32 {
    return PILLAR_R;
}
export fn carR() i32 {
    return CAR_R;
}
export fn arenaW() i32 {
    return ARENA_W;
}
export fn arenaH() i32 {
    return ARENA_H;
}
