//! Projectiles hitting bodies and walls.
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
        const nil = Self.nil;
        const cell_shift = Self.cell_shift;
        const cells_x = Self.cells_x;
        const cells_y = Self.cells_y;
        const isExplosion = Self.isExplosion;

        pub fn sysProjectileHits(self: *Self) void {
            if (self.predicting()) return;
            self.state.world.each(.{ c.Transform, c.Velocity, c.Projectile }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile) void {
                    if (isExplosion(p) or p.damage == c.Projectile.visual) return;
                    const shot = T.shotDef(p.weapon).shot;
                    if (shot == T.shot_grenade) return; // grenades go off by their fuse
                    const sc = &sim.scratch;
                    // Swept test: the segment travelled this tick against each
                    // body's circle; the earliest hit along the segment wins.
                    const x0 = t.x - vel.vx;
                    const y0 = t.y - vel.vy;
                    const dd: i64 = @as(i64, vel.vx) * vel.vx + @as(i64, vel.vy) * vel.vy;
                    const ccx: i32 = std.math.clamp(t.x >> cell_shift, 0, cells_x - 1);
                    const ccy: i32 = std.math.clamp(t.y >> cell_shift, 0, cells_y - 1);
                    var best_t: i64 = std.math.maxInt(i64);
                    var best: u32 = nil;
                    var dy: i32 = -1;
                    while (dy <= 1) : (dy += 1) {
                        var dx: i32 = -1;
                        while (dx <= 1) : (dx += 1) {
                            const nx = ccx + dx;
                            const ny = ccy + dy;
                            if (nx < 0 or ny < 0 or nx >= cells_x or ny >= cells_y) continue;
                            const cell: u32 = @intCast(ny * cells_x + nx);
                            if (sc.cell_stamp[cell] != sc.stamp) continue;
                            var j = sc.cell_head[cell];
                            while (j != nil) : (j = sc.entries[j].next) {
                                const e = sc.entries[j];
                                if (eql(e.id, p.owner)) continue;
                                if (t.z < e.z or t.z > e.z + fx.half) continue;
                                const fxv: i64 = e.x - x0;
                                const fyv: i64 = e.y - y0;
                                var tq: i64 = if (dd == 0) 0 else @divTrunc((fxv * vel.vx + fyv * vel.vy) << 16, dd);
                                tq = std.math.clamp(tq, 0, 1 << 16);
                                const px: i64 = x0 + ((vel.vx * tq) >> 16);
                                const py: i64 = y0 + ((vel.vy * tq) >> 16);
                                const ex = e.x - px;
                                const ey = e.y - py;
                                const rr: i64 = e.r + T.shot_radius;
                                if (ex * ex + ey * ey < rr * rr and tq < best_t) {
                                    best_t = tq;
                                    best = j;
                                }
                            }
                        }
                    }
                    if (best != nil and p.ttl != 0) {
                        sc.stats.shot_hits += 1;
                        const e = sc.entries[best];
                        sim.countPlayerHit(p, e.id);
                        // Scripts test what hit what (mission-scripts.md 3.4).
                        Self.hooks.entityHit(sim, e.id, p.weapon, p.owner);
                        const def = T.shotDef(p.weapon);
                        const ww = &sim.state.world;
                        // Double damage on the shooter doubles the bullet
                        // and flame figures (projectiles.md 3.2-3.3).
                        var mult: i32 = 1;
                        if (ww.get(p.owner, c.Pedestrian)) |op| {
                            if (op.double_damage > 0) mult = 2;
                        }
                        if (ww.get(e.id, c.Vehicle) != null) {
                            // Cars: raw damage by anti-strength; a rocket
                            // blows up at the hit point.
                            const raw: i64 = if (def.explosive) def.damage_car else @as(i64, def.damage_car) * mult;
                            // Proofing (script-cars.md 2.5): rockets and
                            // molotovs, flames, bullets.
                            const cause: Self.CarHitCause = if (def.explosive or shot == T.shot_molotov) .rocket else if (shot == T.shot_flame) .flame else if (shot == T.shot_water) .other else .bullet;
                            // The hit lands halfway between the shot and the
                            // car's centre, which picks the dent
                            // (projectiles.md).
                            if (!Self.car_flags.shielded(sim, e.id, cause)) sim.damageCarAt(e.id, raw << fx.frac_bits, p.owner, (t.x + e.x) >> 1, (t.y + e.y) >> 1);
                            if (def.explosive) sim.explodeAt((t.x + e.x) >> 1, (t.y + e.y) >> 1, e.z, p.owner, 0);
                        } else {
                            const player = ww.get(e.id, c.Controller).?.player != c.Controller.no_player;
                            const ped = ww.get(e.id, c.Pedestrian).?;
                            if (player and ped.armour > 0) {
                                // Armour soaks the whole hit.
                                if (sim.writable(e.id)) ped.armour -= 1;
                            } else sim.hurt(e.id, mult * @as(i32, if (player) def.damage_player else def.damage_other), p.owner);
                            if (shot == T.shot_flame) sim.ignite(e.id, p.owner);
                            if (shot == T.shot_water and sim.writable(e.id)) ped.burn = 0;
                            if (def.explosive) sim.explodeAt(e.x, e.y, e.z, p.owner, 0);
                        }
                        if (shot == T.shot_molotov) sim.startFire(e.x, e.y, e.z, p.owner);
                        p.ttl = 0;
                        sim.kill(id);
                    }
                }
            }.f);
        }

        /// Accuracy (scoring.md 3.4): a player's projectile hit, counted by
        /// weapon as on a threat or on someone else. Ours: a threat is a
        /// ped whose objective targets the shooter (D1 fills objectives).
        pub fn countPlayerHit(self: *Self, p: *const c.Projectile, victim: EntityId) void {
            if (comptime !Self.single_player) return;
            const slot = self.creditSlot(p.owner);
            if (slot == Self.Event.no_slot) return;
            const w = &self.state.world;
            const me = self.state.players[slot].ped;
            const threat = if (w.get(victim, c.Objective)) |o| eql(o.main_target, me) else false;
            Self.career.countHit(self, slot, p.weapon, threat);
        }
    };
}
