//! Fires and explosions (explosions-and-damage.md).
//! Methods of `Sim(cfg)`, aliased in `sim.zig`; `step()` there calls the
//! systems in their fixed order.

const std = @import("std");
const prelude = @import("../prelude.zig");
const TV = @import("../tuning/vehicles.zig");
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
        const Shot = Self.Shot;

        /// A fire on the ground (a molotov's): an explosion entity of kind
        /// `explosion_fire` that burns for `fire_ticks`. No event: clients
        /// draw it from the entity.
        pub fn startFire(self: *Self, x: Fx, y: Fx, z: Fx, by: EntityId) void {
            if (self.predicting()) return;
            const w = &self.state.world;
            const id = w.spawn(Shot) orelse return;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = z, .heading = 0 };
            w.get(id, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            w.get(id, c.Projectile).?.* = .{ .owner = by, .ttl = T.fire_ticks, .damage = 0, .weapon = c.Projectile.explosion_bit | T.explosion_fire };
        }

        /// Set ped `id` on fire, credited to `by`.
        pub fn ignite(self: *Self, id: EntityId, by: EntityId) void {
            if (!self.writable(id)) return;
            const w = &self.state.world;
            const p = w.get(id, c.Pedestrian) orelse return;
            if (p.invulnerable > 0 or !w.get(id, c.Riding).?.vehicle.isNone()) return;
            p.burn = T.burn_ticks;
            if (!by.isNone()) w.get(id, c.Health).?.last_hit_by = by;
        }

        /// Start an explosion (explosions-and-damage.md): an entity that
        /// stays put for 99 ticks and acts from the next tick. `kind` 0 is
        /// small (rockets), 1 a car. `by` is credited.
        pub fn explodeAt(self: *Self, x: Fx, y: Fx, z: Fx, by: EntityId, kind: u8) void {
            if (self.predicting()) return;
            self.scratch.stats.explosions += 1;
            self.pushEvent(.{ .kind = .explosion, .a = kind, .x = x, .y = y, .z = z });
            const w = &self.state.world;
            const id = w.spawn(Shot) orelse return;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = z, .heading = 0 };
            w.get(id, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            w.get(id, c.Projectile).?.* = .{ .owner = by, .ttl = T.explosion_ticks, .damage = 0, .weapon = c.Projectile.explosion_bit | kind };
        }

        /// A fire on the ground, one tick: anyone standing in it catches
        /// fire; cars in it take fire damage every 8 ticks.
        pub fn burnAround(self: *Self, t: *const c.Transform, timer: u16, by: EntityId) void {
            const Ctx = struct { sim: *Self, t: c.Transform, timer: u16, by: EntityId };
            const ctx = Ctx{ .sim = self, .t = t.*, .timer = timer, .by = by };
            self.state.world.each(.{ c.Pedestrian, c.Transform }, ctx, struct {
                fn g(cx: Ctx, pid: EntityId, ped: *c.Pedestrian, pt: *c.Transform) void {
                    if (ped.burn > 0) return;
                    if (fx.abs(pt.z - cx.t.z) > T.explosion_reach_z) return;
                    if (@max(fx.abs(pt.x - cx.t.x), fx.abs(pt.y - cx.t.y)) > T.fire_radius) return;
                    cx.sim.ignite(pid, cx.by);
                }
            }.g);
            if (timer & 7 != 0) return;
            self.state.world.each(.{ c.Vehicle, c.Transform }, ctx, struct {
                fn g(cx: Ctx, cid: EntityId, _: *c.Vehicle, ct: *c.Transform) void {
                    if (fx.abs(ct.z - cx.t.z) > T.explosion_reach_z) return;
                    if (@max(fx.abs(ct.x - cx.t.x), fx.abs(ct.y - cx.t.y)) > T.fire_radius) return;
                    if (Self.car_flags.shielded(cx.sim, cid, .flame)) return;
                    cx.sim.damageCar(cid, @as(i64, T.fire_car_damage) << fx.frac_bits, cx.by);
                }
            }.g);
        }

        pub fn isExplosion(p: *const c.Projectile) bool {
            return p.weapon & c.Projectile.explosion_bit != 0;
        }

        /// Every explosion, every tick: on its first tick it pushes cars
        /// outward; while its timer is above 50 it throws peds and, in two
        /// windows, wrecks cars in its radius. Distances are square
        /// (Chebyshev), with a vertical reach of 0.2.
        pub fn sysExplosions(self: *Self) void {
            if (self.predicting()) return;
            self.state.world.each(.{ c.Transform, c.Projectile }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, p: *c.Projectile) void {
                    if (!isExplosion(p)) return;
                    if (p.ttl == 0) return sim.kill(id);
                    const timer = p.ttl;
                    p.ttl -= 1;
                    if (p.weapon & 3 == T.explosion_fire) return sim.burnAround(t, timer, p.owner);
                    const r = if (p.weapon & 3 == 1) T.explosion_car else T.explosion_small;
                    const Ctx = struct { sim: *Self, x: Fx, y: Fx, z: Fx, r: Fx, timer: u16, by: EntityId, car_size: bool };
                    const ctx = Ctx{ .sim = sim, .x = t.x, .y = t.y, .z = t.z, .r = r, .timer = timer, .by = p.owner, .car_size = p.weapon & 3 == 1 };
                    const car_window = (timer >= 81 and timer <= 89) or (timer >= 51 and timer <= 59);
                    if (timer == T.explosion_ticks or car_window) {
                        sim.state.world.each(.{ c.Vehicle, c.Transform, c.Velocity }, ctx, struct {
                            fn g(cx: Ctx, cid: EntityId, v: *c.Vehicle, ct: *c.Transform, vel: *c.Velocity) void {
                                if (v.flags & c.Vehicle.flag_wrecked != 0) return;
                                if (fx.abs(ct.z - cx.z) > T.explosion_reach_z) return;
                                const dx = ct.x - cx.x;
                                const dy = ct.y - cx.y;
                                if (@max(fx.abs(dx), fx.abs(dy)) > cx.r) return;
                                if (cx.timer == T.explosion_ticks) {
                                    // Outward push of 1 / (4 x distance), by mass.
                                    const d = @max(fx.length(dx, dy), fx.ratio(1, 4));
                                    const imp = fx.div(fx.one, d * 4);
                                    const dv = fx.div(imp, T.carModel(v.model).mass);
                                    vel.vx += fx.mul(fx.div(dx, d), dv);
                                    vel.vy += fx.mul(fx.div(dy, d), dv);
                                } else {
                                    // Rocketproof: only a car-size blast
                                    // right next to it gets through.
                                    const close = cx.car_size and @max(fx.abs(dx), fx.abs(dy)) <= TV.bomb_close;
                                    if (Self.car_flags.shielded(cx.sim, cid, if (close) .bomb_close else .blast)) return;
                                    cx.sim.damageCar(cid, @as(i64, T.blast_car_damage) << fx.frac_bits, cx.by);
                                }
                            }
                        }.g);
                    }
                    if (timer <= T.explosion_active_above) return;
                    sim.state.world.each(.{ c.Pedestrian, c.Transform, c.Riding, c.Controller }, ctx, struct {
                        fn g(cx: Ctx, pid: EntityId, ped: *c.Pedestrian, pt: *c.Transform, ride: *c.Riding, ctl: *c.Controller) void {
                            if (ped.state != c.Pedestrian.state_up or !ride.vehicle.isNone()) return;
                            if (fx.abs(pt.z - cx.z) > T.explosion_reach_z) return;
                            const dx = pt.x - cx.x;
                            const dy = pt.y - cx.y;
                            const d = @max(fx.abs(dx), fx.abs(dy));
                            if (d > 2 * cx.r) return;
                            const len = fx.length(dx, dy);
                            const nx = if (len == 0) fx.one else fx.div(dx, len);
                            const ny = if (len == 0) 0 else fx.div(dy, len);
                            const S = c.Pedestrian;
                            if (d <= cx.r >> 1) {
                                cx.sim.knock(pid, S.state_fatal, nx, ny, T.blast_throw, T.blast_lift_close, cx.by);
                            } else if (d <= cx.r) {
                                const player = ctl.player != c.Controller.no_player;
                                cx.sim.knock(pid, if (player) S.state_down else S.state_fatal, nx, ny, T.blast_throw, T.blast_lift, cx.by);
                            } else if (cx.timer > T.explosion_knock_above) {
                                cx.sim.knock(pid, S.state_over, nx, ny, T.blast_knock, 0, cx.by);
                            }
                        }
                    }.g);
                }
            }.f);
        }
    };
}
