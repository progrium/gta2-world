//! Ped movement, thrown bodies and knock-downs (ped-movement.md).
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
const anim = @import("../anim.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        const Me = @This();
        const substeps = Self.substeps;

        /// Peds move a step at a time; a blocked step slides along one map
        /// axis at half speed (ped-movement.md 3.3). Mid-jump a ped never
        /// drops below the height he jumped from (3.6). Knocked bodies are
        /// thrown and slide (`moveThrown`).
        pub fn sysMovePeds(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Transform, c.Velocity, c.Collider }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, ped: *c.Pedestrian, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    if (ped.state == c.Pedestrian.state_falling) return Me.moveFalling(sim, id, ped, t, vel, col);
                    if (ped.state != c.Pedestrian.state_up) return sim.moveThrown(id, ped, t, vel, col);
                    const n = substeps(vel);
                    const sx = @divTrunc(vel.vx, n);
                    const sy = @divTrunc(vel.vy, n);
                    var i: i32 = 0;
                    while (i < n) : (i += 1) {
                        if (!sim.pedBlocked(t.x, t.y, t.x + sx, t.y + sy, t.z)) {
                            t.x += sx;
                            t.y += sy;
                            continue;
                        }
                        const hx = sx >> T.ped_slide_shift;
                        const hy = sy >> T.ped_slide_shift;
                        const x_first = fx.abs(sx) >= fx.abs(sy);
                        if (x_first and hx != 0 and !sim.pedBlocked(t.x, t.y, t.x + hx, t.y, t.z)) {
                            t.x += hx;
                        } else if (hy != 0 and !sim.pedBlocked(t.x, t.y, t.x, t.y + hy, t.z)) {
                            t.y += hy;
                        } else if (!x_first and hx != 0 and !sim.pedBlocked(t.x, t.y, t.x + hx, t.y, t.z)) {
                            t.x += hx;
                        }
                    }
                    if (ped.jump > 0) {
                        // Up a step if the ground rises; never down.
                        const floor = map.floorAt(sim.grid, t.x, t.y, t.z, T.ped_step);
                        if (floor > t.z) t.z = floor;
                        vel.vz = 0;
                        col.flags |= c.Collider.flag_grounded;
                        return;
                    }
                    const z0 = t.z;
                    sim.settle(t, vel, col, T.ped_step, T.ped_gravity, T.ped_max_fall);
                    if (t.z < z0) sim.pushOutCircle(t, T.ped_radius, T.ped_step);
                    // Stepped off an edge (3.5): he falls, keeping his
                    // horizontal speed, and takes no control until he lands.
                    if (col.flags & c.Collider.flag_grounded == 0) {
                        ped.state = c.Pedestrian.state_falling;
                        ped.anim = c.Pedestrian.anim_fall;
                        ped.fall = 0;
                        ped.turn = 0;
                    }
                }
            }.f);
        }

        /// A falling ped (ped-movement.md 3.5): carried at the horizontal
        /// speed he left the edge with, stopped by walls, falling at +0.01
        /// a tick up to 0.1. The fall animation's frames 12 and 13 each
        /// deal 4; from frame 14 the fall is lethal and he dies on landing
        /// unless invulnerable. Frame length is `anim.ticks_per_frame.fall`
        /// (ours).
        pub fn moveFalling(self: *Self, id: EntityId, ped: *c.Pedestrian, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
            ped.anim = c.Pedestrian.anim_fall;
            ped.jump = 0;
            const n = substeps(vel);
            const sx = @divTrunc(vel.vx, n);
            const sy = @divTrunc(vel.vy, n);
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                if (sx != 0) {
                    if (self.pedBlocked(t.x, t.y, t.x + sx, t.y, t.z)) vel.vx = 0 else t.x += sx;
                }
                if (sy != 0) {
                    if (self.pedBlocked(t.x, t.y, t.x, t.y + sy, t.z)) vel.vy = 0 else t.y += sy;
                }
            }
            ped.fall +|= 1;
            const per = anim.ticks_per_frame.fall;
            const frame = anim.frameAt(ped.fall, per);
            if (ped.fall % per == 0 and frame >= anim.frames.fall_hurt_first and frame < anim.frames.fall_lethal) {
                if (self.state.world.get(id, c.Health)) |h| self.hurt(id, T.fall_damage, h.last_hit_by);
            }
            const z0 = t.z;
            self.settle(t, vel, col, T.ped_step, T.ped_gravity, T.ped_max_fall);
            if (t.z < z0) self.pushOutCircle(t, T.ped_radius, T.ped_step);
            if (col.flags & c.Collider.flag_grounded == 0) return;
            // Landed.
            const lethal = frame >= anim.frames.fall_lethal;
            ped.fall = 0;
            ped.state = c.Pedestrian.state_up;
            ped.anim = c.Pedestrian.anim_stand;
            if (lethal and ped.invulnerable == 0) {
                if (self.state.world.get(id, c.Health)) |h| self.killPed(id, h.last_hit_by);
            }
        }

        /// Can a ped at (x0, y0) step to (x1, y1)? A step can be longer
        /// than the ped is wide, so a wall face is also looked for halfway.
        pub fn pedBlocked(self: *const Self, x0: Fx, y0: Fx, x1: Fx, y1: Fx, z: Fx) bool {
            if (self.circleBlocked(x1, y1, z, T.ped_radius, T.ped_step)) return true;
            const mx = x0 + ((x1 - x0) >> 1);
            const my = y0 + ((y1 - y0) >> 1);
            return map.rectHitsWall(self.grid, map.Rect.square(mx, my, T.ped_radius), z, T.ped_step);
        }

        /// A knocked ped (explosions-and-damage.md 3.9): carried at its
        /// speed with gravity 0.02, stopped by walls, sliding to rest on the
        /// ground. At rest: a fatal throw kills; otherwise he lies for
        /// `down` ticks and gets up.
        pub fn moveThrown(self: *Self, id: EntityId, ped: *c.Pedestrian, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
            ped.anim = c.Pedestrian.anim_down;
            ped.jump = 0;
            ped.turn = 0;
            const n = substeps(vel);
            const sx = @divTrunc(vel.vx, n);
            const sy = @divTrunc(vel.vy, n);
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                if (sx != 0) {
                    if (self.pedBlocked(t.x, t.y, t.x + sx, t.y, t.z)) vel.vx = 0 else t.x += sx;
                }
                if (sy != 0) {
                    if (self.pedBlocked(t.x, t.y, t.x, t.y + sy, t.z)) vel.vy = 0 else t.y += sy;
                }
            }
            const in_air = col.flags & c.Collider.flag_grounded == 0 or vel.vz > 0;
            const z0 = t.z;
            self.settle(t, vel, col, T.ped_step, T.thrown_gravity, T.max_fall);
            if (t.z < z0) self.pushOutCircle(t, T.ped_radius, T.ped_step);
            if (in_air) return;
            // Sliding on the ground.
            const sp = fx.length(vel.vx, vel.vy);
            if (sp > T.thrown_friction) {
                const k = fx.div(sp - T.thrown_friction, sp);
                vel.vx = fx.mul(vel.vx, k);
                vel.vy = fx.mul(vel.vy, k);
                return;
            }
            vel.vx = 0;
            vel.vy = 0;
            if (ped.state == c.Pedestrian.state_fatal) {
                if (self.state.world.get(id, c.Health)) |h| h.hp = 0;
                return;
            }
            if (ped.down > 0) {
                ped.down -= 1;
                return;
            }
            ped.state = c.Pedestrian.state_up;
            ped.anim = c.Pedestrian.anim_stand;
        }

        /// Knock ped `id` off his feet: thrown along (nx, ny) at `speed`,
        /// rising at `lift`. `by` is credited if he dies of it.
        pub fn knock(self: *Self, id: EntityId, state: u8, nx: Fx, ny: Fx, speed: Fx, lift: Fx, by: EntityId) void {
            if (!self.writable(id)) return;
            const w = &self.state.world;
            const ped = w.get(id, c.Pedestrian) orelse return;
            if (!w.get(id, c.Riding).?.vehicle.isNone()) return;
            // Invulnerable: every knock is the mildest kind.
            ped.state = if (ped.invulnerable > 0) c.Pedestrian.state_over else state;
            ped.down = if (state == c.Pedestrian.state_over) T.knock_over_ticks else T.knock_down_ticks;
            ped.jump = 0;
            ped.turn = 0;
            ped.anim = c.Pedestrian.anim_down;
            const vel = w.get(id, c.Velocity).?;
            vel.* = .{ .vx = fx.mul(nx, speed), .vy = fx.mul(ny, speed), .vz = lift, .spin = 0 };
            if (lift > 0) w.get(id, c.Collider).?.flags &= ~c.Collider.flag_grounded;
            if (!by.isNone()) w.get(id, c.Health).?.last_hit_by = by;
        }

        /// A ped is killed where he stands (by a hit that kills outright).
        pub fn killPed(self: *Self, id: EntityId, by: EntityId) void {
            if (!self.writable(id)) return;
            if (self.state.world.get(id, c.Pedestrian)) |p| {
                // Invulnerable: knocked over, never killed.
                if (p.invulnerable > 0) return self.knock(id, c.Pedestrian.state_over, fx.one, 0, 0, 0, by);
            }
            const h = self.state.world.get(id, c.Health) orelse return;
            h.hp = 0;
            if (!by.isNone()) h.last_hit_by = by;
        }
    };
}
