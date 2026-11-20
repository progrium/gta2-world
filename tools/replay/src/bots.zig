//! Scripted bots that produce I2 frames from the sim state, for the golden
//! replay, benches and soak runs. Integer-only and seeded, so a bot run is
//! the same on every target. Each bot wanders on foot (tank or direct
//! controls, jumping and firing now and then), walks to the nearest free car,
//! gets in, drives around for a while (steering, handbrake, reversing out of
//! walls) and gets out again.

const sim = @import("sim");
const fx = sim.fx;
const c = sim.c;
const Frame = sim.input.Frame;
const Button = sim.input.Button;
const EntityId = sim.abi.EntityId;

pub const Bot = struct {
    rng: u32,
    mode: Mode = .wander,
    timer: u32 = 0,
    direct: bool = false,
    steer: i8 = 0,
    aim: u16 = 0,
    target: EntityId = .none,
    stuck: u32 = 0,
    reverse: u32 = 0,
    last_x: fx.Fx = 0,
    last_y: fx.Fx = 0,
    press: bool = false,

    const Mode = enum { wander, seek_car, drive };

    pub fn init(seed: u32, slot: u32) Bot {
        var b: Bot = .{ .rng = (seed ^ (slot *% 0x9E3779B9)) | 1 };
        _ = b.next();
        b.direct = slot % 2 == 1;
        return b;
    }

    fn next(b: *Bot) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }

    fn below(b: *Bot, n: u32) u32 {
        return @truncate((@as(u64, b.next()) * n) >> 32);
    }

    /// One frame for this bot's player slot.
    pub fn frame(b: *Bot, comptime S: type, s: *S, slot: u32) Frame {
        var f = Frame.neutral(@truncate(s.tick()));
        const ped = s.pedOf(slot) orelse {
            b.mode = .wander;
            return f;
        };
        const w = &s.state.world;
        const t = w.get(ped, c.Transform).?.*;
        const riding = w.get(ped, c.Riding).?.vehicle;
        // Edge buttons need a release between presses.
        const edge: u16 = if (b.press) 0 else Button.enter_exit;
        if (!riding.isNone()) {
            if (b.mode != .drive) {
                b.mode = .drive;
                b.timer = 300 + b.below(600);
            }
            return b.drive(S, s, riding, &f, edge);
        }
        if (b.mode == .drive) {
            b.mode = .wander;
            b.timer = 0;
        }
        if (b.timer == 0) {
            b.timer = 30 + b.below(150);
            b.steer = @intCast(@as(i32, @intCast(b.below(121))) - 60);
            b.aim = @truncate(b.next());
            if (b.below(3) == 0) b.direct = !b.direct;
            if (b.below(2) == 0) {
                b.target = nearestFreeCar(S, s, t.x, t.y);
                b.mode = if (b.target.isNone()) .wander else .seek_car;
            }
        } else b.timer -= 1;

        if (b.mode == .seek_car) {
            const ct = w.get(b.target, c.Transform);
            const v = w.get(b.target, c.Vehicle);
            if (ct == null or v == null or !v.?.driver.isNone()) {
                b.mode = .wander;
            } else {
                const dx = ct.?.x - t.x;
                const dy = ct.?.y - t.y;
                f.buttons = Button.direct | Button.run;
                f.aim = fx.atan2(dy, dx);
                f.throttle = 127;
                if (fx.length(dx, dy) < fx.ratio(13, 10)) {
                    f.throttle = 0;
                    f.buttons |= edge;
                    b.press = !b.press;
                }
                return f;
            }
        }
        // Wander.
        f.throttle = 127;
        if (b.direct) {
            f.buttons = Button.direct;
            f.aim = b.aim;
            if (b.below(4) == 0) f.buttons |= Button.run;
        } else f.steer = b.steer;
        if (b.below(40) == 0) f.buttons |= Button.handbrake_jump;
        if (b.below(25) == 0) f.buttons |= Button.fire;
        return f;
    }

    fn drive(b: *Bot, comptime S: type, s: *S, car: EntityId, f: *Frame, edge: u16) Frame {
        const w = &s.state.world;
        const t = w.get(car, c.Transform).?.*;
        if (b.timer == 0) {
            // Time to get out; brake first.
            const v = w.get(car, c.Velocity).?;
            f.throttle = -127;
            if (fx.length(v.vx, v.vy) < fx.ratio(5, 100)) {
                f.throttle = 0;
                f.buttons = edge;
                b.press = !b.press;
            }
            return f.*;
        }
        b.timer -= 1;
        const moved = fx.abs(t.x - b.last_x) + fx.abs(t.y - b.last_y);
        b.last_x = t.x;
        b.last_y = t.y;
        if (b.reverse > 0) {
            b.reverse -= 1;
            f.throttle = -127;
            f.steer = b.steer;
            return f.*;
        }
        if (moved < fx.ratio(1, 100)) b.stuck += 1 else b.stuck = 0;
        if (b.stuck > 15) {
            b.stuck = 0;
            b.reverse = 20 + b.below(20);
            b.steer = if (b.below(2) == 0) 127 else -127;
        }
        if (b.below(20) == 0) b.steer = @intCast(@as(i32, @intCast(b.below(255))) - 127);
        if (b.below(6) == 0) b.steer = 0;
        f.throttle = if (b.below(10) == 0) 60 else 127;
        f.steer = b.steer;
        if (b.below(30) == 0) f.buttons |= Button.handbrake_jump;
        if (b.below(50) == 0) f.buttons |= Button.special;
        return f.*;
    }
};

fn nearestFreeCar(comptime S: type, s: *S, x: fx.Fx, y: fx.Fx) EntityId {
    const Best = struct { id: EntityId = .none, d: fx.Fx = fx.fromInt(14) };
    var best: Best = .{};
    const Ctx = struct { best: *Best, x: fx.Fx, y: fx.Fx };
    s.state.world.each(.{ c.Vehicle, c.Transform }, Ctx{ .best = &best, .x = x, .y = y }, struct {
        fn f(ctx: Ctx, id: EntityId, v: *c.Vehicle, t: *c.Transform) void {
            if (!v.driver.isNone()) return;
            const d = fx.length(t.x - ctx.x, t.y - ctx.y);
            if (d < ctx.best.d) ctx.best.* = .{ .id = id, .d = d };
        }
    }.f);
    return best.id;
}

/// Frames for every slot of `s` from `bots`.
pub fn tick(comptime S: type, s: *S, bots: []Bot, frames: []Frame) void {
    for (frames, 0..) |*f, i| {
        f.* = if (i < bots.len) bots[i].frame(S, s, @intCast(i)) else Frame.neutral(@truncate(s.tick()));
    }
}
