//! Hand weapons: switching, firing, throwing, the electro gun (weapons.md).
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
        const Shot = Self.Shot;

        /// Next (or previous) weapon that has rounds.
        pub fn cycleWeapon(wpn: *c.Weapon, forward: bool) void {
            var k: u8 = wpn.kind;
            var n: u8 = 0;
            while (n < T.weapon_count) : (n += 1) {
                k = if (forward) (k + 1) % T.weapon_count else (k + T.weapon_count - 1) % T.weapon_count;
                if (wpn.rounds()[k] != 0) {
                    wpn.kind = k;
                    return;
                }
            }
        }

        /// Fire held: one pull every `cooldown` ticks while there is ammo
        /// (weapons.md). Ammo is in tenths; a pull spends `tenths_per_pull`.
        /// The muzzle is a quarter block ahead, and the point halfway there
        /// must be clear of walls, or nothing is fired and nothing spent.
        pub fn sysWeapons(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Weapon, c.Controller, c.Transform, c.Velocity, c.Riding }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, wpn: *c.Weapon, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, ride: *c.Riding) void {
                    if (wpn.cooldown > 0) wpn.cooldown -= 1;
                    const ped = sim.state.world.get(id, c.Pedestrian);
                    if (!ride.vehicle.isNone() or (ped != null and ped.?.state != c.Pedestrian.state_up)) {
                        if (ped) |p| p.charge = 0;
                        return;
                    }
                    if (wpn.kind >= T.weapon_count) wpn.kind = T.weapon_pistol;
                    if (wpn.rounds()[wpn.kind] == 0 and (ped == null or ped.?.charge == 0)) cycleWeapon(wpn, false);
                    const k = wpn.kind;
                    const def = T.weapons[k];
                    const have = wpn.rounds()[k];
                    // Fast reload halves the wait after each shot.
                    const fast = ped != null and ped.?.fast_reload > 0;
                    if (def.shot == T.shot_grenade or def.shot == T.shot_molotov) {
                        if (ped) |p| sim.throwStep(id, wpn, p, ctl, t, vel, k, fast);
                        return;
                    }
                    if (ctl.in.buttons & Button.fire == 0 or wpn.cooldown != 0 or have == 0) return;
                    const hx = t.x + fx.mul(fx.cos(t.heading), T.muzzle_ahead >> 1);
                    const hy = t.y + fx.mul(fx.sin(t.heading), T.muzzle_ahead >> 1);
                    if (map.blocks(sim.grid, hx, hy, t.z, T.shot_height)) return;
                    if (map.moveHitsWall(sim.grid, t.x, t.y, hx, hy, t.z + T.shot_height, map.bullet)) return;
                    wpn.cooldown = if (fast) @max(1, def.cooldown >> 1) else def.cooldown;
                    if (have != T.infinite_ammo) wpn.rounds()[k] = have -| def.tenths_per_pull;
                    sim.scratch.stats.shots += 1;
                    if (def.shot == T.shot_electro) return sim.electro(id, t);
                    // Pellets fan out `spread` apart, centred on the aim.
                    const first = t.heading -% @as(u16, @truncate(@as(u32, def.spread) * (def.pellets - 1) / 2));
                    var p: u8 = 0;
                    while (p < def.pellets) : (p += 1) {
                        sim.fire(id, t, vel, first +% @as(u16, @truncate(@as(u32, def.spread) * p)), k, def);
                    }
                }
            }.f);
        }

        pub fn fire(self: *Self, shooter: EntityId, t: *const c.Transform, vel: *const c.Velocity, heading: u16, weapon: u8, def: T.WeaponDef) void {
            const dx = fx.cos(heading);
            const dy = fx.sin(heading);
            const st: c.Transform = .{ .x = t.x + fx.mul(dx, T.muzzle_ahead), .y = t.y + fx.mul(dy, T.muzzle_ahead), .z = t.z + T.shot_height, .heading = heading };
            if (self.predicting()) {
                self.pushIntent(.spawn, .projectile, shooter, st);
                return;
            }
            const w = &self.state.world;
            const sid = w.spawn(Shot) orelse return;
            w.get(sid, c.Transform).?.* = st;
            // Shots carry the shooter's own velocity (projectiles.md 3.1).
            w.get(sid, c.Velocity).?.* = .{ .vx = vel.vx + fx.mul(dx, def.speed), .vy = vel.vy + fx.mul(dy, def.speed), .vz = 0, .spin = 0 };
            w.get(sid, c.Projectile).?.* = .{ .owner = shooter, .ttl = def.ttl, .damage = 0, .weapon = weapon };
        }

        /// Grenades and molotovs (weapons.md 3.4): holding fire winds up a
        /// charge; letting go throws at strength min(charge, 60). A grenade
        /// held to a charge of 96 goes off in the hand.
        pub fn throwStep(self: *Self, id: EntityId, wpn: *c.Weapon, ped: *c.Pedestrian, ctl: *const c.Controller, t: *const c.Transform, vel: *const c.Velocity, k: u8, fast: bool) void {
            if (wpn.cooldown != 0) return;
            const have = wpn.rounds()[k];
            const spend = struct {
                fn f(wp: *c.Weapon, kk: u8, h: u16) void {
                    if (h != T.infinite_ammo) wp.rounds()[kk] = h -| T.weapons[kk].tenths_per_pull;
                }
            }.f;
            if (ctl.in.buttons & Button.fire != 0 and have > 0) {
                if (ped.charge < T.charge_max) ped.charge += 1;
                if (k == T.weapon_grenade and ped.charge >= T.grenade_in_hand) {
                    ped.charge = 0;
                    spend(wpn, k, have);
                    wpn.cooldown = if (fast) 2 else T.weapons[k].cooldown;
                    self.explodeAt(t.x, t.y, t.z, id, 0);
                }
                return;
            }
            if (ped.charge == 0) return;
            const charge = ped.charge;
            ped.charge = 0;
            if (have == 0) return;
            const strength: i32 = @min(charge, T.throw_strength_max);
            const base, const span = if (k == T.weapon_grenade) .{ T.grenade_speed_base, T.grenade_speed_span } else .{ T.molotov_speed_base, T.molotov_speed_span };
            const speed = base + @divTrunc(span * strength, T.throw_strength_max);
            const dx = fx.cos(t.heading);
            const dy = fx.sin(t.heading);
            var vx = fx.mul(dx, speed);
            var vy = fx.mul(dy, speed);
            // Moving forwards adds your own speed and a little more.
            if (fx.mul(vel.vx, dx) + fx.mul(vel.vy, dy) > 0) {
                vx += vel.vx + fx.mul(dx, T.throw_moving_bonus);
                vy += vel.vy + fx.mul(dy, T.throw_moving_bonus);
            }
            const st: c.Transform = .{ .x = t.x, .y = t.y, .z = t.z + T.throw_height, .heading = t.heading };
            if (map.blocks(self.grid, st.x, st.y, st.z, 0)) return;
            spend(wpn, k, have);
            wpn.cooldown = if (fast) 2 else T.weapons[k].cooldown;
            self.scratch.stats.shots += 1;
            if (self.predicting()) {
                self.pushIntent(.spawn, .projectile, id, st);
                return;
            }
            const w = &self.state.world;
            const sid = w.spawn(Shot) orelse return;
            w.get(sid, c.Transform).?.* = st;
            w.get(sid, c.Velocity).?.* = .{ .vx = vx, .vy = vy, .vz = T.throw_rise, .spin = 0 };
            const life: u16 = if (k == T.weapon_grenade) T.grenadeFuse(charge) else 600;
            w.get(sid, c.Projectile).?.* = .{ .owner = id, .ttl = life, .damage = 0, .weapon = k };
        }

        /// Electro gun, one tick (weapons.md 3.5): every ped or car in a
        /// 4 x 4 square around the shooter, within 45 degrees of his facing,
        /// a level up or down and in sight, takes a shock; then the same
        /// from each of them in a 2 x 2 square, aimed along the shooter's
        /// line to it. Two hops at most; nobody twice.
        pub fn electro(self: *Self, shooter: EntityId, t: *const c.Transform) void {
            if (self.predicting()) return;
            var hit: [12]EntityId = undefined;
            var n: usize = 0;
            hit[0] = shooter;
            n = 1;
            const first = self.electroHop(shooter, t.x, t.y, t.z, t.heading, T.electro_reach, &hit, &n);
            const end_first = n;
            var i: usize = first;
            while (i < end_first) : (i += 1) {
                const tt = self.state.world.get(hit[i], c.Transform) orelse continue;
                const dir = fx.atan2(tt.y - t.y, tt.x - t.x);
                _ = self.electroHop(shooter, tt.x, tt.y, tt.z, dir, T.electro_chain_reach, &hit, &n);
            }
        }

        /// One electro search from (x, y, z) along `dir`; hits go on the end
        /// of `hit`. Returns where this hop's hits start.
        pub fn electroHop(self: *Self, shooter: EntityId, x: Fx, y: Fx, z: Fx, dir: u16, reach: Fx, hit: *[12]EntityId, n: *usize) usize {
            const start = n.*;
            const Ctx = struct { sim: *Self, shooter: EntityId, x: Fx, y: Fx, z: Fx, dir: u16, reach: Fx, hit: *[12]EntityId, n: *usize };
            const ctx = Ctx{ .sim = self, .shooter = shooter, .x = x, .y = y, .z = z, .dir = dir, .reach = reach, .hit = hit, .n = n };
            const visit = struct {
                fn f(cx: Ctx, id: EntityId, tt: *c.Transform, col: *c.Collider) void {
                    if (cx.n.* >= cx.hit.len) return;
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    for (cx.hit[0..cx.n.*]) |h| if (eql(h, id)) return;
                    const dx = tt.x - cx.x;
                    const dy = tt.y - cx.y;
                    if (@max(fx.abs(dx), fx.abs(dy)) > cx.reach or fx.abs(tt.z - cx.z) > T.electro_reach_z) return;
                    if (dx != 0 or dy != 0) {
                        const off: i16 = @bitCast(fx.atan2(dy, dx) -% cx.dir);
                        if (@abs(off) > T.electro_cone) return;
                    }
                    const sim = cx.sim;
                    if (map.moveHitsWall(sim.grid, cx.x, cx.y, tt.x, tt.y, cx.z + T.shot_height, map.bullet)) return;
                    cx.hit[cx.n.*] = id;
                    cx.n.* += 1;
                    const w = &sim.state.world;
                    if (w.get(id, c.Vehicle) != null) {
                        sim.damageCar(id, @as(i64, T.weapons[T.weapon_electro].damage_car) << fx.frac_bits, cx.shooter);
                    } else if (w.get(id, c.Pedestrian)) |p| {
                        if (p.invulnerable == 0) p.shock +|= T.shock_gun;
                        w.get(id, c.Health).?.last_hit_by = cx.shooter;
                    }
                    sim.spark(tt.x, tt.y, tt.z, cx.shooter);
                }
            }.f;
            self.state.world.each(.{ c.Vehicle, c.Transform, c.Collider }, ctx, struct {
                fn f(cx: Ctx, id: EntityId, _: *c.Vehicle, tt: *c.Transform, col: *c.Collider) void {
                    visit(cx, id, tt, col);
                }
            }.f);
            self.state.world.each(.{ c.Pedestrian, c.Transform, c.Collider }, ctx, struct {
                fn f(cx: Ctx, id: EntityId, _: *c.Pedestrian, tt: *c.Transform, col: *c.Collider) void {
                    visit(cx, id, tt, col);
                }
            }.f);
            return start;
        }

        /// A projectile that only shows (an electric arc on a target): it
        /// stays put for two ticks and touches nothing.
        pub fn spark(self: *Self, x: Fx, y: Fx, z: Fx, by: EntityId) void {
            const w = &self.state.world;
            const id = w.spawn(Shot) orelse return;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = z + T.shot_height, .heading = 0 };
            w.get(id, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            w.get(id, c.Projectile).?.* = .{ .owner = by, .ttl = 2, .damage = c.Projectile.visual, .weapon = T.weapon_electro };
        }
    };
}
