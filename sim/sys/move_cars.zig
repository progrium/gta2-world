//! Car movement and wall hits (car-height.md, car-collision.md).
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
        const applyImpulse = Self.applyImpulse;
        const carCorners = Self.carCorners;
        const radToAngle = Self.radToAngle;
        const substeps = Self.substeps;

        pub fn sysMoveCars(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Vehicle, c.Transform, c.Velocity, c.Collider }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    const m = T.carModel(v.model);
                    // Towed trailers and cars on a crane are placed by
                    // their own systems.
                    // Trains run on their rails (`sys/trains.zig`).
                    if (!v.towId().isNone() or v.xflags & c.Vehicle.xf_lifted != 0 or v.train != 0) return;
                    // Rotate first; a turn that would put a corner in a wall
                    // does not happen.
                    if (vel.spin != 0) {
                        const h = t.heading +% radToAngle(vel.spin);
                        if (sim.boxBlocked(t.x, t.y, t.z, h, m)) {
                            vel.spin = 0;
                        } else t.heading = h;
                    }
                    const n = substeps(vel);
                    var i: i32 = 0;
                    var moved = false;
                    var blocked_x: Fx = 0;
                    var blocked_y: Fx = 0;
                    while (i < n) : (i += 1) {
                        const sx = @divTrunc(vel.vx, n);
                        const sy = @divTrunc(vel.vy, n);
                        if (sx != 0) {
                            if (sim.boxBlocked(t.x + sx, t.y, t.z, t.heading, m)) {
                                sim.wallHit(id, t, vel, true, sx, m);
                                blocked_x = sx;
                            } else {
                                t.x += sx;
                                moved = true;
                            }
                        }
                        if (sy != 0) {
                            if (sim.boxBlocked(t.x, t.y + sy, t.z, t.heading, m)) {
                                sim.wallHit(id, t, vel, false, sy, m);
                                blocked_y = sy;
                            } else {
                                t.y += sy;
                                moved = true;
                            }
                        }
                    }
                    // Unstick (car-collision.md 3.2): fully blocked with gas
                    // or reverse held, turn 1 degree toward running along
                    // the wall and step 1/64 away from it.
                    if (!moved and (blocked_x != 0 or blocked_y != 0) and v.drive != c.Vehicle.drive_none) {
                        const travel = if (v.drive == c.Vehicle.drive_reverse) t.heading +% 32768 else t.heading;
                        // Parallel to a wall across x is +-y (16384 or
                        // 49152), to one across y is 0 or 32768.
                        const off: i16 = @bitCast(travel -% @as(u16, if (blocked_x != 0) 16384 else 0));
                        const far_side = @abs(off) > 16384;
                        const toward_plus = (off > 0) == far_side;
                        const turn: u16 = if (toward_plus) T.unstick_turn else 0 -% T.unstick_turn;
                        const h = t.heading +% turn;
                        if (!sim.boxBlocked(t.x, t.y, t.z, h, m)) t.heading = h;
                        const px: Fx = if (blocked_x > 0) -T.unstick_push else if (blocked_x < 0) T.unstick_push else 0;
                        const py: Fx = if (blocked_y > 0) -T.unstick_push else if (blocked_y < 0) T.unstick_push else 0;
                        if (!sim.boxBlocked(t.x + px, t.y + py, t.z, t.heading, m)) {
                            t.x += px;
                            t.y += py;
                        }
                    }
                    sim.carSettle(t, vel, col, m);
                    sim.carWater(id, v, t, vel, col, m);
                }
            }.f);
        }

        /// Bounce off a wall along one axis (restitution 0.25) and scrub some
        /// speed along the other. The impulse, (1 + e) x speed x mass,
        /// damages the car (car-collision.md 3.5).
        pub fn wallHit(self: *Self, id: EntityId, t: *const c.Transform, vel: *c.Velocity, x_axis: bool, dir: Fx, m: *const T.CarModel) void {
            self.scratch.stats.wall_hits += 1;
            // Contact point: the corner furthest along the blocked move
            // (car-collision.md 3.3); n is the wall's axis, toward the car.
            var r: [2]Fx = .{ 0, 0 };
            var far: Fx = std.math.minInt(Fx);
            for (carCorners(t, m)) |k| {
                const along = if (x_axis) k[0] else k[1];
                const a = if (dir > 0) along else -along;
                if (a > far) {
                    far = a;
                    r = k;
                }
            }
            const nx: Fx = if (x_axis) (if (dir > 0) -fx.one else fx.one) else 0;
            const ny: Fx = if (x_axis) 0 else (if (dir > 0) -fx.one else fx.one);
            const vpx = vel.vx - fx.mul(vel.spin, r[1]);
            const vpy = vel.vy + fx.mul(vel.spin, r[0]);
            const vn = fx.mul(vpx, nx) + fx.mul(vpy, ny);
            if (vn < 0) {
                // Damage and the dent go by the speed going in, not the
                // rebound (car-collision.md 3.5).
                const speed_in = fx.length(vel.vx, vel.vy);
                const rn = fx.mul(r[0], ny) - fx.mul(r[1], nx);
                const denom = fx.div(fx.one, m.mass) + fx.div(fx.mul(rn, rn), m.inertia);
                const j: Fx = @intCast(@divTrunc(@as(i64, -fx.div(vn, denom)) * (8 + m.restitution_8ths), 8));
                applyImpulse(vel, m, r[0], r[1], fx.mul(j, nx), fx.mul(j, ny));
                // The normal speed never stays pointing into the wall.
                if (x_axis and fx.mul(vel.vx, nx) < 0) vel.vx = 0;
                if (!x_axis and fx.mul(vel.vy, ny) < 0) vel.vy = 0;
                // The contact corner takes the dent (car-collision.md 3.5).
                if (speed_in > T.impact_min_speed) self.damageCarAt(id, @as(i64, j) * T.impact_damage, .none, t.x + r[0], t.y + r[1]);
            }
            // Airborne and rising or level: bounce down (0.7, cut at 1/32).
            if (vel.vz >= 0 and self.state.world.get(id, c.Collider).?.flags & c.Collider.flag_grounded == 0) {
                vel.vz = -fx.mul(vel.vz, fx.ratio(7, 10));
                if (fx.abs(vel.vz) < fx.one / 32) vel.vz = 0;
            }
        }
    };
}
