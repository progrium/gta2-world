//! Bodies against the map: blocked tests, settling on floors and ramps.
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
        /// Is a circle body blocked at (x, y)? Tested at height z, and again
        /// at the floor it would stand on there when that is higher (up a
        /// ramp), so a step never lifts its head into matter: a ramp that
        /// runs under a low ceiling stops it where the head would hit.
        pub fn circleBlocked(self: *const Self, x: Fx, y: Fx, z: Fx, r: Fx, step_h: Fx) bool {
            if (circleBlockedAt(self, x, y, z, r, step_h)) return true;
            const f = map.floorAt(self.grid, x, y, z, step_h);
            return f > z and circleBlockedAt(self, x, y, f, r, step_h);
        }

        /// Sample points of a circle body: centre, four axis points, four
        /// diagonals. A void under the centre also blocks.
        fn circleBlockedAt(self: *const Self, x: Fx, y: Fx, z: Fx, r: Fx, step_h: Fx) bool {
            const d = fx.mul(r, fx.ratio(70711, 100000));
            const pts = [_][2]Fx{
                .{ 0, 0 }, .{ r, 0 },  .{ -r, 0 }, .{ 0, r },   .{ 0, -r },
                .{ d, d }, .{ d, -d }, .{ -d, d }, .{ -d, -d },
            };
            if (map.isVoid(self.grid, x, y, z + step_h)) return true;
            for (pts) |p| {
                if (map.blocks(self.grid, x + p[0], y + p[1], z, step_h)) return true;
                if (map.pastTopEdge(x + p[0], y + p[1], z)) return true;
            }
            // Wall faces, against the body's square (a ped is a small
            // square: shape-and-map-collision.md 2).
            return map.rectHitsWall(self.grid, map.Rect.square(x, y, r), z, step_h);
        }

        /// Is a car's box blocked at (x, y)? Like `circleBlocked`, also
        /// tested at the floor under its centre when that is higher.
        pub fn boxBlocked(self: *const Self, x: Fx, y: Fx, z: Fx, heading: u16, m: *const T.CarModel) bool {
            if (boxBlockedAt(self, x, y, z, heading, m)) return true;
            const f = map.floorAt(self.grid, x, y, z, T.car_step);
            return f > z and boxBlockedAt(self, x, y, f, heading, m);
        }

        /// Sample points of a car's box: corners, side midpoints and the
        /// middle of the front and back.
        fn boxBlockedAt(self: *const Self, x: Fx, y: Fx, z: Fx, heading: u16, m: *const T.CarModel) bool {
            const cx = fx.cos(heading);
            const sy = fx.sin(heading);
            const pts = [_][2]Fx{
                .{ m.half_len, m.half_wid }, .{ m.half_len, -m.half_wid }, .{ -m.half_len, m.half_wid }, .{ -m.half_len, -m.half_wid },
                .{ 0, m.half_wid },          .{ 0, -m.half_wid },          .{ m.half_len, 0 },           .{ -m.half_len, 0 },
            };
            for (pts, 0..) |p, i| {
                const px = x + fx.mul(p[0], cx) - fx.mul(p[1], sy);
                const py = y + fx.mul(p[0], sy) + fx.mul(p[1], cx);
                if (map.blocks(self.grid, px, py, z, T.car_step)) return true;
                if (map.pastTopEdge(px, py, z)) return true;
                // Voids: checked at the middle of the front and the back.
                if (i >= 6 and map.isVoid(self.grid, px, py, z + T.car_step)) return true;
            }
            // And under the centre, so a car tipped or pushed over an edge
            // never ends up hanging over nothing.
            if (map.isVoid(self.grid, x, y, z + T.car_step)) return true;
            return map.rectHitsWall(self.grid, .{ .x = x, .y = y, .cos = cx, .sin = sy, .a = m.half_len, .b = m.half_wid }, z, T.car_step);
        }

        pub fn substeps(vel: *const c.Velocity) i32 {
            const m = @max(fx.abs(vel.vx), fx.abs(vel.vy));
            return @max(1, @divTrunc(m + T.max_substep - 1, T.max_substep));
        }

        /// Gravity, floor following and landing for any body.
        pub fn settle(self: *const Self, t: *c.Transform, vel: *c.Velocity, col: *c.Collider, step_h: Fx, grav: Fx, max_fall: Fx) void {
            const floor = map.floorAt(self.grid, t.x, t.y, t.z, step_h);
            const grounded = col.flags & c.Collider.flag_grounded != 0;
            if (grounded and vel.vz <= 0 and floor >= t.z - T.snap_down) {
                t.z = floor;
                vel.vz = 0;
                return;
            }
            vel.vz = @max(vel.vz - grav, -max_fall);
            // Rising into a ceiling stops the rise.
            if (vel.vz > 0 and map.blocks(self.grid, t.x, t.y, t.z + vel.vz, step_h)) vel.vz = 0;
            t.z += vel.vz;
            if (t.z <= floor) {
                t.z = floor;
                vel.vz = 0;
                col.flags |= c.Collider.flag_grounded;
            } else col.flags &= ~c.Collider.flag_grounded;
        }

        /// A car's height (car-height.md 3.1-3.4): it follows the ground
        /// down by up to half a block; further, it is tipped over the edge
        /// while a corner is still on the ground, then leaves the ground at
        /// the rate it was climbing or descending, falling with gravity 1/64.
        pub fn carSettle(self: *const Self, t: *c.Transform, vel: *c.Velocity, col: *c.Collider, m: *const T.CarModel) void {
            const floor = map.floorAt(self.grid, t.x, t.y, t.z, T.car_step);
            if (col.flags & c.Collider.flag_grounded != 0 and vel.vz <= 0) {
                if (floor >= t.z - T.car_drop) {
                    t.z = floor;
                    vel.vz = 0;
                    return;
                }
                // Off the edge while climbing (a ramp top): leave the
                // ground at the rate of the last step, a ramp jump.
                const b1 = map.floorAt(self.grid, t.x - vel.vx, t.y - vel.vy, t.z, T.car_step);
                const b2 = map.floorAt(self.grid, t.x - 2 * vel.vx, t.y - 2 * vel.vy, t.z, T.car_step);
                const rate = b1 - b2;
                if (rate > 0 and rate < T.car_drop) {
                    vel.vz = rate;
                } else {
                    // Centre over a drop: corners still on the ground tip
                    // it over the edge, and it stays up until none are.
                    const cs = fx.cos(t.heading);
                    const sn = fx.sin(t.heading);
                    const corners = [_][2]Fx{ .{ m.half_len, m.half_wid }, .{ m.half_len, -m.half_wid }, .{ -m.half_len, m.half_wid }, .{ -m.half_len, -m.half_wid } };
                    var supported = false;
                    var push: [2]Fx = .{ 0, 0 };
                    for (corners) |cn| {
                        const o = [2]Fx{ fx.mul(cn[0], cs) - fx.mul(cn[1], sn), fx.mul(cn[0], sn) + fx.mul(cn[1], cs) };
                        const f = map.floorAt(self.grid, t.x + o[0], t.y + o[1], t.z, T.car_step);
                        if (f >= t.z - T.car_drop) {
                            supported = true;
                        } else {
                            push[0] += @divTrunc(o[0], T.car_tip_div);
                            push[1] += @divTrunc(o[1], T.car_tip_div);
                        }
                    }
                    if (supported) {
                        // Moved straight away (ours), so the parked-car
                        // damping does not cancel the push.
                        if (!self.boxBlocked(t.x + push[0], t.y + push[1], t.z, t.heading, m)) {
                            t.x += push[0];
                            t.y += push[1];
                        }
                        return;
                    }
                    vel.vz = if (rate < 0 and rate > -T.car_drop) rate else 0;
                }
                col.flags &= ~c.Collider.flag_grounded;
            }
            vel.vz = @max(vel.vz - T.car_gravity, -T.car_max_fall);
            // Rising into a ceiling stops the rise.
            if (vel.vz > 0 and map.blocks(self.grid, t.x, t.y, t.z + vel.vz, T.car_step)) vel.vz = 0;
            t.z = @min(t.z + vel.vz, T.car_ceiling);
            if (t.z <= floor) {
                t.z = floor;
                vel.vz = 0;
                col.flags |= c.Collider.flag_grounded;
            } else col.flags &= ~c.Collider.flag_grounded;
        }
    };
}
