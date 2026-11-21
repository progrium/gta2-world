//! Peds on foot: turning, walking, jumping (ped-movement.md).
//! Methods of `Sim(cfg)`, aliased in `sim.zig`; `step()` there calls the
//! systems in their fixed order.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const input = prelude.input;
const fx = prelude.fx;
const ecs = prelude.ecs;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const Frame = prelude.Frame;
const Button = prelude.Button;
const eql = prelude.eql;

pub fn Sys(comptime Self: type) type {
    return struct {
        /// On-foot control (ped-movement.md 3.1-3.6): tank turning that
        /// builds up while held, one running pace forward and back, and a
        /// jump on a fresh press that carries the ped forward without
        /// leaving the ground. Direct mode (sticks) turns toward the aim.
        /// Knocked-over peds and falling peds take no control.
        pub fn sysPedControl(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Riding, c.Controller, c.Transform, c.Velocity, c.Collider }, self.predicting(), {}, struct {
                fn f(_: void, _: EntityId, ped: *c.Pedestrian, ride: *c.Riding, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    const jump_pressed = ped.flags & c.Pedestrian.flag_jump_pressed != 0;
                    ped.flags &= ~c.Pedestrian.flag_jump_pressed;
                    if (!ride.vehicle.isNone()) {
                        ped.turn = 0;
                        ped.jump = 0;
                        return;
                    }
                    if (ped.state != c.Pedestrian.state_up) return;
                    const grounded = col.flags & c.Collider.flag_grounded != 0;
                    const jumping = ped.jump > 0;
                    // Falling: keeps its motion (3.5).
                    if (!grounded and !jumping) {
                        ped.anim = c.Pedestrian.anim_jump;
                        return;
                    }
                    const in = ctl.in;
                    const run = in.buttons & Button.run != 0;
                    var speed: Fx = 0;
                    var dir: u16 = t.heading;
                    if (in.buttons & Button.direct != 0) {
                        ped.turn = 0;
                        const diff: i16 = @bitCast(in.aim -% t.heading);
                        const lim: i32 = if (jumping) T.ped_turn_jump_max else T.ped_direct_turn;
                        const turn = std.math.clamp(@as(i32, diff), -lim, lim);
                        t.heading +%= @as(u16, @truncate(@as(u32, @bitCast(turn))));
                        if (in.throttle > 0) {
                            speed = fx.mulAxis(if (run) T.ped_run else T.ped_walk, in.throttle);
                            dir = in.aim;
                        }
                    } else {
                        if (in.steer == 0) {
                            ped.turn = 0;
                        } else {
                            // The turn speed steps toward the held side, up
                            // to a cap (a stick's deflection scales the cap).
                            const aiming = in.buttons & Button.fire != 0 and in.throttle <= 0;
                            const rate: i32 = if (jumping) T.ped_turn_jump else if (aiming) T.ped_turn_aim else T.ped_tank_turn;
                            const max: i32 = if (jumping) T.ped_turn_jump_max else T.ped_turn_max;
                            const cap = @divTrunc(max * @as(i32, @abs(in.steer)), 127);
                            const sign: i32 = if (in.steer > 0) 1 else -1;
                            ped.turn = @intCast(std.math.clamp(@as(i32, ped.turn) + sign * rate, -cap, cap));
                        }
                        t.heading +%= @as(u16, @bitCast(ped.turn));
                        dir = t.heading;
                        if (in.throttle > 0) {
                            speed = fx.mulAxis(if (run) T.ped_run else T.ped_walk, in.throttle);
                        } else if (in.throttle < 0) {
                            speed = fx.mulAxis(T.ped_back, -in.throttle);
                            dir = t.heading +% 32768;
                        }
                    }
                    if (jumping) {
                        ped.jump -= 1;
                    } else if (jump_pressed) {
                        ped.jump = T.ped_jump_ticks;
                    }
                    // A jump always carries him forward at the run pace.
                    if (ped.jump > 0 and speed == 0) {
                        speed = T.ped_run;
                        dir = t.heading;
                    }
                    vel.vx = fx.mul(fx.cos(dir), speed);
                    vel.vy = fx.mul(fx.sin(dir), speed);
                    vel.vz = 0;
                    ped.anim = if (ped.jump > 0) c.Pedestrian.anim_jump else if (speed == 0) c.Pedestrian.anim_stand else if (run) c.Pedestrian.anim_run else c.Pedestrian.anim_walk;
                }
            }.f);
        }
    };
}
