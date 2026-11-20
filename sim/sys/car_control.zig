//! Driven cars: per-tick handling (car-handling.md).
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
        /// Car handling (docs/behaviour/car-handling.md, steps 1-13): up and
        /// down mean throttle, foot brake or reverse by the direction of
        /// travel; a gas pedal 0-5 and three gears make the engine force; each
        /// axle's tyre pushes against its sideways slip and rolling drag, the
        /// rear one steering slightly against the front at low speed, scaled
        /// by rear end stability, with the handbrake cutting its grip; then
        /// damping, the speed cap and the lane-arrow snap. Spin is in radians
        /// a tick (fixed point). Cars in the air only damp.
        pub fn sysCarControl(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Vehicle, c.Controller, c.Transform, c.Velocity, c.Collider, c.Health }, self.predicting(), self, struct {
                fn f(sim: *Self, _: EntityId, v: *c.Vehicle, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, col: *c.Collider, hp: *c.Health) void {
                    const m = T.carModel(v.model);
                    const ai = v.flags & c.Vehicle.flag_ai != 0;
                    const driven = (!v.driver.isNone() or ai) and v.flags & c.Vehicle.flag_wrecked == 0;
                    const in = if (driven) ctl.in else Frame.neutral(0);
                    const player = !v.driver.isNone() and ctl.player != c.Controller.no_player;
                    const handbrake = in.buttons & Button.handbrake_jump != 0;
                    const in_water = v.flags & c.Vehicle.flag_in_water != 0;
                    const keep = v.flags & (c.Vehicle.flag_ai | c.Vehicle.flag_burning | c.Vehicle.flag_wrecked | c.Vehicle.flag_in_water);
                    v.flags = keep | (if (handbrake) c.Vehicle.flag_handbrake else 0) | (if (in.buttons & Button.special != 0) c.Vehicle.flag_horn else 0);
                    v.steer = in.steer;

                    const fwd_x = fx.cos(t.heading);
                    const fwd_y = fx.sin(t.heading);
                    const vf0 = fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y);
                    const speed = fx.length(vel.vx, vel.vy);
                    const stopped = vel.vx == 0 and vel.vy == 0;
                    const forwards = vf0 >= 0;

                    // 1. Input: up and down by the direction of travel; a
                    // change of direction costs a tick with nothing held.
                    const up = in.throttle > 0;
                    const down = in.throttle < 0;
                    var thr = false;
                    var rev = false;
                    var brake = false;
                    if (stopped) {
                        thr = up;
                        rev = down;
                    } else if (forwards) {
                        if (v.drive != c.Vehicle.drive_reverse) {
                            thr = up;
                            brake = down;
                        }
                    } else if (v.drive != c.Vehicle.drive_forward) {
                        rev = down;
                        brake = up;
                    }
                    v.drive = if (thr) c.Vehicle.drive_forward else if (rev) c.Vehicle.drive_reverse else c.Vehicle.drive_none;

                    // 2-4. Pedal (a stick's deflection caps it), brake
                    // pressure, handbrake ramp, turbo, damage factor.
                    const amount: i32 = @intCast(@abs(@as(i32, in.throttle)));
                    const cap: i32 = @max(1, @divTrunc(amount * T.pedal_quarters_max + 126, 127));
                    var pedal: i32 = v.pedal;
                    pedal = if (thr or rev) @min(pedal + 1, cap) else @max(pedal - 1, 0);
                    v.pedal = @intCast(pedal);
                    v.brake = if (brake and !in_water) @min(v.brake + 1, T.brake_quarters_max) else 0;
                    v.handbrake_n = if (handbrake) @min(v.handbrake_n +| 1, T.handbrake_ramp) else 0;
                    const turbo = m.turbo != 0 and pedal >= T.turbo_quarters;
                    const damage = T.car_damage_max - hp.hp;
                    const dmg_factor: Fx = if (damage < T.car_fire_damage) fx.one else frac(T.car_damage_max + 1 - damage, T.car_fire_damage);

                    if (col.flags & c.Collider.flag_grounded == 0) {
                        damp(vel, t.heading, T.damp_lateral_air, T.damp_long_air, T.damp_spin_air);
                        return;
                    }

                    // 5. Engine force.
                    var engine: Fx = 0;
                    if (driven and (thr or rev) and !in_water) {
                        const base = m.thrust >> 1;
                        var pterm = fx.mul(frac(pedal, 4), @divTrunc(m.thrust, 5));
                        if (turbo) pterm *= 2;
                        if (player) {
                            if (rev) {
                                engine = -fx.mul(base + pterm, m.gear1);
                            } else if (!(handbrake and stopped)) {
                                const gear: Fx = if (speed > m.gear3_speed) m.gear3 else if (speed > m.gear2_speed) m.gear2 else m.gear1;
                                const p2 = if (speed > m.gear2_speed) fx.mul(pterm, dmg_factor) else pterm;
                                engine = fx.mul(base + p2, gear);
                            }
                        } else {
                            const e = base + fx.mul(pterm, dmg_factor);
                            engine = if (rev) -e else e;
                        }
                    }
                    const brake_force = fx.mul(frac(v.brake, 4), m.brake_friction);

                    // 7. Steering angle (radians).
                    const dir = frac(in.steer, 127);
                    var angle = fx.mul(dir, m.turn_ratio);
                    if (player) angle = fx.div(fx.mul(angle, @max(T.steer_speed_min, T.steer_speed_ref - speed)), T.steer_div);
                    const steering = in.steer != 0;

                    // 8. Tyre forces at each axle.
                    var mass = m.mass;
                    if (player) mass = fx.mul(mass, T.player_mass);
                    var force = [2]Fx{ 0, 0 };
                    var torque: Fx = 0;
                    const ra = fx.div(fx.mul(angle, T.steer_speed_ref - speed), T.rear_steer_div);
                    const oiled = v.oil > 0;
                    inline for (.{ true, false }) |front| {
                        const d = if (front) m.front_axle else m.rear_axle;
                        const share = if (front) fx.mul(engine, m.front_drive_bias) else engine - fx.mul(engine, m.front_drive_bias);
                        // On oil, an axle with no engine force on it exerts
                        // no force at all; one with engine force keeps its
                        // grip, ignores the brakes and is turned 30 degrees,
                        // the front one way and the rear the other.
                        const skip = oiled and share == 0;
                        const off: u16 = if (!oiled) 0 else if ((v.oil_dir == 0) == front) T.oil_axle_angle else 0 -% T.oil_axle_angle;
                        const a_rad = if (front) angle else -ra;
                        const a = t.heading +% radToAngle(a_rad) +% off;
                        const ax = fx.cos(a);
                        const ay = fx.sin(a);
                        // Velocity of the axle point, with the spin.
                        const rx = fx.mul(d, fwd_x);
                        const ry = fx.mul(d, fwd_y);
                        const px = vel.vx - fx.mul(vel.spin, ry);
                        const py = vel.vy + fx.mul(vel.spin, rx);
                        const v_long = fx.mul(px, ax) + fx.mul(py, ay);
                        const v_lat = fx.mul(px, -ay) + fx.mul(py, ax);
                        var grip: Fx = fx.one;
                        if (steering) grip = if (front) fx.one + m.turn_in else fx.one - m.turn_in;
                        if (!front and handbrake and !oiled) grip = fx.mul(grip, m.handbrake_slide);
                        var drag = T.rolling_drag;
                        if (!oiled) {
                            drag += fx.mul(brake_force, if (front) T.front_brake_share else T.rear_brake_share);
                            if (!front) drag += fx.mul(m.brake_friction, frac(v.handbrake_n, T.handbrake_ramp));
                        }
                        const f_lat = if (skip) 0 else -fx.mul(v_lat, grip);
                        const f_long = if (skip) 0 else -fx.mul(v_long, drag) + share;
                        var fwx = fx.mul(f_long, ax) - fx.mul(f_lat, ay);
                        var fwy = fx.mul(f_long, ay) + fx.mul(f_lat, ax);
                        if (!front) {
                            fwx = fx.mul(fwx, m.rear_end_stability);
                            fwy = fx.mul(fwy, m.rear_end_stability);
                        }
                        force[0] += fwx;
                        force[1] += fwy;
                        torque += fx.mul(rx, fwy) - fx.mul(ry, fwx);
                    }

                    // 9. Steep-slope roll-back: on a 45 degree ramp with
                    // neither brake on, 0.04 x mass pushes it downhill.
                    if (v.brake == 0 and !handbrake) {
                        const cell = map.floorCell(sim.grid, t.x, t.y, t.z, T.car_step);
                        const code = map.codeOf(cell);
                        if (map.shapeOf(cell) == map.Shape.slope and code >= 41 and code <= 44) {
                            const push = fx.mul(T.slope_rollback, mass);
                            switch (code - 41) {
                                0 => force[1] += push, // high end toward -y
                                1 => force[1] -= push,
                                2 => force[0] += push, // high end toward -x
                                else => force[0] -= push,
                            }
                        }
                    }

                    // 10. Integrate, with dead zones.
                    vel.vx += fx.div(force[0], mass);
                    vel.vy += fx.div(force[1], mass);
                    vel.spin += fx.div(torque, m.inertia);
                    if (fx.abs(vel.vx) + fx.abs(vel.vy) < T.dead_zone) {
                        vel.vx = 0;
                        vel.vy = 0;
                    }
                    if (fx.abs(vel.spin) < T.dead_zone) vel.spin = 0;

                    // 11. Damping.
                    damp(vel, t.heading, T.damp_lateral, T.damp_long, T.damp_spin);

                    // 12. Speed cap: max speed forwards, gear 2 speed back.
                    const sp = fx.length(vel.vx, vel.vy);
                    const back = fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y) < 0;
                    const cap_v = if (back) m.gear2_speed else m.max_speed;
                    if (sp > cap_v and sp > 0) {
                        vel.vx = fx.mul(vel.vx, fx.div(cap_v, sp));
                        vel.vy = fx.mul(vel.vy, fx.div(cap_v, sp));
                    }

                    // 13. Arrow snap: no steering, moving forwards on a road
                    // with one-axis arrows, within 25 degrees of the lane:
                    // a nudge of the heading toward it.
                    if (driven and !steering and !back and sp > 0 and v.oil == 0 and (!player or pedal >= 8)) {
                        const cell = map.floorCell(sim.grid, t.x, t.y, t.z, T.car_step);
                        const arrows = map.arrowsOf(cell);
                        if (map.groundOf(cell) == map.Ground.road and arrows != 0) {
                            const along_x = arrows & (map.Arrow.pos_x | map.Arrow.neg_x) != 0;
                            const along_y = arrows & (map.Arrow.pos_y | map.Arrow.neg_y) != 0;
                            if (along_x != along_y) {
                                const base_h: u16 = if (along_x) 0 else 16384;
                                var err: i16 = @bitCast(base_h -% t.heading);
                                if (@abs(@as(i32, err)) > 16384) err = @bitCast(@as(u16, @bitCast(err)) +% 32768);
                                if (@abs(@as(i32, err)) <= T.snap_window) {
                                    const rate = if (m.long != 0) T.snap_rate >> 1 else T.snap_rate;
                                    const lim: i32 = radToAngle(fx.mul(rate, sp));
                                    t.heading +%= @as(u16, @bitCast(@as(i16, @intCast(std.math.clamp(@as(i32, err), -lim, lim)))));
                                }
                            }
                        }
                    }
                    oilTick(v);
                }
            }.f);
        }

        /// Count down the oil spin, once a tick (step 13).
        pub fn oilTick(v: *c.Vehicle) void {
            if (v.oil > 0) v.oil -= 1;
        }

        /// Damp velocity in the car's frame (lateral, longitudinal) and spin.
        /// When both world components are already tiny, the whole velocity
        /// takes the lateral factor and spin is left alone.
        pub fn damp(vel: *c.Velocity, heading: u16, lat: Fx, long: Fx, spin: Fx) void {
            if (fx.abs(vel.vx) <= T.slow_zone and fx.abs(vel.vy) <= T.slow_zone) {
                vel.vx = fx.mul(vel.vx, lat);
                vel.vy = fx.mul(vel.vy, lat);
                return;
            }
            const fwd_x = fx.cos(heading);
            const fwd_y = fx.sin(heading);
            const vf = fx.mul(fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y), long);
            const vl = fx.mul(fx.mul(vel.vx, -fwd_y) + fx.mul(vel.vy, fwd_x), lat);
            vel.vx = fx.mul(vf, fwd_x) - fx.mul(vl, fwd_y);
            vel.vy = fx.mul(vf, fwd_y) + fx.mul(vl, fwd_x);
            vel.spin = fx.mul(vel.spin, spin);
        }

        /// a / b in fixed point, for runtime integers.
        pub fn frac(a: i32, b: i32) Fx {
            return @intCast(@divTrunc(@as(i64, a) << fx.frac_bits, b));
        }

        /// Radians (fixed point) to angle units, rounded.
        pub fn radToAngle(r: Fx) u16 {
            const a: i64 = (@as(i64, r) * T.rad_to_angle + (1 << 15)) >> 16;
            return @truncate(@as(u64, @bitCast(a)));
        }
    };
}
