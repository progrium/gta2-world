//! The level runner's player: goes where it is told. The target comes from
//! the mission arrow once the sim has one (workstream A1's `sp/hud.zig`);
//! until then the runner hands it waypoints on the road. On foot it walks
//! straight at the target, or takes the nearest free car when the target is
//! far; in a car it steers toward the target, backs out when stuck, and
//! gets out when close.

const sim = @import("sim");
const fx = sim.fx;
const c = sim.c;
const Frame = sim.input.Frame;
const Button = sim.input.Button;
const EntityId = sim.abi.EntityId;

pub const Autopilot = struct {
    target_x: fx.Fx = 0,
    target_y: fx.Fx = 0,
    has_target: bool = false,
    /// Ticks since the target was set.
    age: u32 = 0,
    stuck: u32 = 0,
    reverse: u32 = 0,
    reverse_steer: i8 = 127,
    last_x: fx.Fx = 0,
    last_y: fx.Fx = 0,
    press: bool = false,
    car: EntityId = .none,

    pub const arrive_dist = fx.fromInt(3);
    pub const car_wanted_dist = fx.fromInt(20);

    pub fn setTarget(a: *Autopilot, x: fx.Fx, y: fx.Fx) void {
        if (a.has_target and x == a.target_x and y == a.target_y) return;
        a.* = .{ .target_x = x, .target_y = y, .has_target = true };
    }

    /// Distance from the player's body (ped, or the car it rides) to the
    /// target, or null with no body.
    pub fn distance(a: *const Autopilot, comptime S: type, s: *S, slot: u32) ?fx.Fx {
        const t = bodyTransform(S, s, slot) orelse return null;
        return fx.length(a.target_x - t.x, a.target_y - t.y);
    }

    pub fn bodyTransform(comptime S: type, s: *S, slot: u32) ?*c.Transform {
        const ped = s.pedOf(slot) orelse return null;
        const w = &s.state.world;
        const r = w.get(ped, c.Riding).?.vehicle;
        if (!r.isNone() and w.isAlive(r)) return w.get(r, c.Transform);
        return w.get(ped, c.Transform);
    }

    pub fn frame(a: *Autopilot, comptime S: type, s: *S, slot: u32) Frame {
        var f = Frame.neutral(@truncate(s.tick()));
        a.age += 1;
        const ped = s.pedOf(slot) orelse return f;
        if (!a.has_target) return f;
        const w = &s.state.world;
        const edge: u16 = if (a.press) 0 else Button.enter_exit;
        const pt = w.get(ped, c.Transform).?.*;
        const riding = w.get(ped, c.Riding).?.vehicle;
        if (!riding.isNone()) {
            const t = w.get(riding, c.Transform).?.*;
            const dx = a.target_x - t.x;
            const dy = a.target_y - t.y;
            const d = fx.length(dx, dy);
            const v = w.get(riding, c.Velocity).?;
            if (d < arrive_dist * 2) {
                // Stop and get out.
                f.throttle = -127;
                if (fx.length(v.vx, v.vy) < fx.ratio(5, 100)) {
                    f.throttle = 0;
                    f.buttons = edge;
                    a.press = !a.press;
                }
                return f;
            }
            const moved = fx.abs(t.x - a.last_x) + fx.abs(t.y - a.last_y);
            a.last_x = t.x;
            a.last_y = t.y;
            if (a.reverse > 0) {
                a.reverse -= 1;
                f.throttle = -127;
                f.steer = a.reverse_steer;
                return f;
            }
            if (moved < fx.ratio(1, 100)) a.stuck += 1 else a.stuck = 0;
            if (a.stuck > 20) {
                a.stuck = 0;
                a.reverse = 25;
                a.reverse_steer = -a.reverse_steer;
            }
            const want = fx.atan2(dy, dx);
            const diff: i16 = @bitCast(want -% t.heading);
            f.steer = if (diff > 2000) 127 else if (diff < -2000) -127 else @intCast(@divTrunc(@as(i32, diff) * 127, 2000));
            // Slow down for sharp turns and near the target.
            f.throttle = if (@abs(diff) > 12000 or d < fx.fromInt(10)) 60 else 127;
            return f;
        }
        const dx = a.target_x - pt.x;
        const dy = a.target_y - pt.y;
        const d = fx.length(dx, dy);
        if (d < arrive_dist) return f;
        f.buttons = Button.direct | Button.run;
        f.aim = fx.atan2(dy, dx);
        f.throttle = 127;
        if (d > car_wanted_dist) {
            if (!w.isAlive(a.car)) a.car = nearestFreeCar(S, s, pt.x, pt.y);
            if (w.get(a.car, c.Transform)) |ct| {
                const cdx = ct.x - pt.x;
                const cdy = ct.y - pt.y;
                f.aim = fx.atan2(cdy, cdx);
                if (fx.length(cdx, cdy) < fx.ratio(13, 10)) {
                    f.throttle = 0;
                    f.buttons |= edge;
                    a.press = !a.press;
                }
            }
        }
        // Walking into a wall: jump now and then.
        const moved = fx.abs(pt.x - a.last_x) + fx.abs(pt.y - a.last_y);
        a.last_x = pt.x;
        a.last_y = pt.y;
        if (moved < fx.ratio(1, 200)) a.stuck += 1 else a.stuck = 0;
        if (a.stuck > 30) {
            a.stuck = 0;
            f.buttons |= Button.handbrake_jump;
            a.car = .none;
        }
        return f;
    }

    /// Put the player's body (car or ped) on the target: the runner's time
    /// limit, so one stuck walk does not end a level run.
    pub fn teleport(a: *Autopilot, comptime S: type, s: *S, slot: u32) void {
        const t = bodyTransform(S, s, slot) orelse return;
        t.x = a.target_x;
        t.y = a.target_y;
        t.z = sim.map.floorAt(s.grid, t.x, t.y, fx.fromInt(sim.map.size_z - 1), sim.tuning.ped_step);
    }
};

fn nearestFreeCar(comptime S: type, s: *S, x: fx.Fx, y: fx.Fx) EntityId {
    const Best = struct { id: EntityId = .none, d: fx.Fx = fx.fromInt(12) };
    var best: Best = .{};
    const Ctx = struct { best: *Best, x: fx.Fx, y: fx.Fx };
    s.state.world.each(.{ c.Vehicle, c.Transform }, Ctx{ .best = &best, .x = x, .y = y }, struct {
        fn f(ctx: Ctx, id: EntityId, v: *c.Vehicle, t: *c.Transform) void {
            if (!v.driver.isNone() or v.flags & c.Vehicle.flag_wrecked != 0) return;
            const d = fx.length(t.x - ctx.x, t.y - ctx.y);
            if (d < ctx.best.d) ctx.best.* = .{ .id = id, .d = d };
        }
    }.f);
    return best.id;
}
