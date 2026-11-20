//! Projectile movement: bullets, thrown grenades and molotovs (projectiles.md).
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
        const isExplosion = Self.isExplosion;

        pub fn sysMoveProjectiles(self: *Self) void {
            if (self.predicting()) return; // not predicted; replicated only
            self.state.world.each(.{ c.Transform, c.Velocity, c.Projectile }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile) void {
                    if (isExplosion(p)) return;
                    const shot = T.shotDef(p.weapon).shot;
                    if (p.damage != c.Projectile.visual and (shot == T.shot_grenade or shot == T.shot_molotov)) return sim.moveThrownShot(id, t, vel, p, shot);
                    // Out of range: gone (a rocket too, without exploding).
                    if (p.ttl == 0) return sim.kill(id);
                    p.ttl -= 1;
                    if (p.damage == c.Projectile.visual) return;
                    const explosive = T.shotDef(p.weapon).explosive and (p.weapon < T.weapon_count or p.weapon >= T.car_shot_base);
                    const base = t.z - T.shot_height;
                    // Four samples along the move, so a fast round cannot
                    // skip the corner of a block.
                    var i: i32 = 1;
                    while (i <= 4) : (i += 1) {
                        const x = t.x + @divTrunc(vel.vx * i, 4);
                        const y = t.y + @divTrunc(vel.vy * i, 4);
                        const px = t.x + @divTrunc(vel.vx * (i - 1), 4);
                        const py = t.y + @divTrunc(vel.vy * (i - 1), 4);
                        if (map.blocks(sim.grid, x, y, base, T.shot_height) or map.moveHitsWall(sim.grid, px, py, x, y, t.z, map.bullet)) {
                            if (explosive) {
                                // Blow up just short of the wall.
                                sim.explodeAt(px, py, base, p.owner, 0);
                            }
                            t.x = x;
                            t.y = y;
                            p.ttl = 0;
                            return sim.kill(id);
                        }
                    }
                    t.x += vel.vx;
                    t.y += vel.vy;
                }
            }.f);
        }

        /// A thrown grenade or molotov (projectiles.md 3.1): falls with
        /// gravity 1/512, bounces off walls and the ground (ours: keeping
        /// half its speed), rolls with friction 0.01 a tick. A grenade goes
        /// off when its fuse (`ttl`) runs out; a molotov bursts into fire on
        /// any contact.
        pub fn moveThrownShot(self: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile, shot: u8) void {
            const molotov = shot == T.shot_molotov;
            if (p.ttl == 0) {
                if (molotov) self.startFire(t.x, t.y, map.floorAt(self.grid, t.x, t.y, t.z, fx.ratio(1, 8)), p.owner) else self.explodeAt(t.x, t.y, t.z, p.owner, 0);
                return self.kill(id);
            }
            p.ttl -= 1;
            const lift = fx.ratio(1, 8);
            if (vel.vx != 0) {
                const nx = t.x + vel.vx;
                if (map.blocks(self.grid, nx, t.y, t.z, lift) or map.moveHitsWall(self.grid, t.x, t.y, nx, t.y, t.z + lift, 0)) {
                    if (molotov) return self.burstMolotov(id, t, p);
                    vel.vx = -@divTrunc(vel.vx * T.bounce_8ths, 8);
                } else t.x = nx;
            }
            if (vel.vy != 0) {
                const ny = t.y + vel.vy;
                if (map.blocks(self.grid, t.x, ny, t.z, lift) or map.moveHitsWall(self.grid, t.x, t.y, t.x, ny, t.z + lift, 0)) {
                    if (molotov) return self.burstMolotov(id, t, p);
                    vel.vy = -@divTrunc(vel.vy * T.bounce_8ths, 8);
                } else t.y = ny;
            }
            const floor = map.floorAt(self.grid, t.x, t.y, t.z, lift);
            vel.vz -= T.throw_gravity;
            t.z += vel.vz;
            if (t.z <= floor) {
                t.z = floor;
                if (molotov) return self.burstMolotov(id, t, p);
                vel.vz = if (vel.vz < -fx.ratio(2, 100)) -@divTrunc(vel.vz * T.bounce_8ths, 8) else 0;
                // Rolling: friction takes 0.01 a tick off the speed.
                const sp = fx.length(vel.vx, vel.vy);
                if (sp <= T.throw_friction) {
                    vel.vx = 0;
                    vel.vy = 0;
                } else {
                    vel.vx = @intCast(@divTrunc(@as(i64, vel.vx) * (sp - T.throw_friction), sp));
                    vel.vy = @intCast(@divTrunc(@as(i64, vel.vy) * (sp - T.throw_friction), sp));
                }
            }
        }

        pub fn burstMolotov(self: *Self, id: EntityId, t: *const c.Transform, p: *c.Projectile) void {
            self.startFire(t.x, t.y, map.floorAt(self.grid, t.x, t.y, t.z, fx.ratio(1, 8)), p.owner);
            p.ttl = 0;
            self.kill(id);
        }
    };
}
