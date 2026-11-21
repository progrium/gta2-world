//! Vehicle weapons (weapons.md 3.7). Owner: workstream G. A car's weapon
//! belongs to the car and is fired by its driver with the fire button.
//! Built-in ones (tank gun, army jeep gun, fire truck cannon) come from the
//! car's model role (`tuning/career.zig`) and never run out; fitted ones
//! (car guns, oil, mines, car bomb, or any of the others from a kill
//! frenzy or a script) are kept in a small table in the single-player
//! block, `state.sp.arms`. Oil and mines are dropped as B's objects.
//!
//! The electro baton (weapons.md 3.6) is a hand weapon that the weapon
//! table does not have yet; it is not here.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const Button = prelude.Button;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const TC = @import("../tuning/career.zig");
const CarWeapon = TC.CarWeapon;

/// One fitted vehicle weapon.
pub const Arm = extern struct {
    car: EntityId = .none,
    /// `CarWeapon`.
    kind: u8 = 0,
    /// Ticks until it can fire again.
    cooldown: u8 = 0,
    flags: u8 = 0,
    _pad: u8 = 0,
    /// Ammo in tenths of a displayed round.
    ammo: u16 = 0,
    /// An armed car bomb: ticks until it goes off (0 = not armed).
    fuse: u16 = 0,
    /// Who armed the bomb (credited with the blast).
    armed_by: EntityId = .none,
};

/// In the SP state block (`state.sp.arms`).
pub const State = extern struct {
    arms: [TC.max_armed_cars]Arm = @splat(.{}),
    /// Cooldown of a built-in weapon, per player slot's car (ours: one
    /// player in `sp`, so one counter is enough).
    builtin_cooldown: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.single_player;
        const Shot = Self.Shot;

        /// The fitted weapon of `car`, if any.
        pub fn armOf(self: *Self, car: EntityId) ?*Arm {
            if (comptime !sp) return null;
            if (car.isNone()) return null;
            for (&self.state.sp.arms.arms) |*a| {
                if (eql(a.car, car)) return a;
            }
            return null;
        }

        /// The weapon `car` carries: fitted, else built in, else none.
        pub fn weaponOf(self: *Self, car: EntityId) CarWeapon {
            if (armOf(self, car)) |a| {
                if (a.ammo > 0 or a.fuse > 0) return @enumFromInt(a.kind);
            }
            const v = self.state.world.get(car, c.Vehicle) orelse return .none;
            return TC.builtinCarWeapon(v.model);
        }

        /// Fit `kind` to `car` with `rounds` displayed rounds (a pickup, a
        /// shop, a kill frenzy or a script). The same kind adds ammo up to
        /// its maximum; another kind replaces the old one. False when the
        /// table is full or it is already full of that kind.
        pub fn arm(self: *Self, car: EntityId, kind: CarWeapon, rounds: u16) bool {
            if (comptime !sp) return false;
            if (self.predicting()) return false;
            const k = @intFromEnum(kind);
            if (k == 0 or k >= TC.car_weapon_kinds) return false;
            if (self.state.world.get(car, c.Vehicle) == null) return false;
            const def = TC.car_weapons[k];
            const a = armOf(self, car) orelse freeSlot(self) orelse return false;
            if (a.car.isNone() or a.kind != k) {
                a.* = .{ .car = car, .kind = k };
            } else if (a.ammo >= def.max_tenths) return false;
            a.ammo = @min(def.max_tenths, a.ammo +| rounds *| 10);
            return true;
        }

        /// Remove `car`'s fitted weapon (death and arrest, kill frenzy end).
        /// An armed bomb stays armed.
        pub fn disarm(self: *Self, car: EntityId) void {
            const a = armOf(self, car) orelse return;
            if (a.fuse > 0) {
                a.ammo = 0;
                return;
            }
            a.* = .{};
        }

        /// Is a car bomb armed on `car` (script-cars.md 2.6, type 305)?
        pub fn bombArmed(self: *Self, car: EntityId) bool {
            const a = armOf(self, car) orelse return false;
            return a.fuse > 0;
        }

        fn freeSlot(self: *Self) ?*Arm {
            const w = &self.state.world;
            for (&self.state.sp.arms.arms) |*a| {
                if (a.car.isNone() or !w.isAlive(a.car)) {
                    a.* = .{};
                    return a;
                }
            }
            return null;
        }

        /// Once a tick, before hand weapons: each driven car's weapon fires
        /// while its driver holds fire (or on a fresh press, for the car
        /// bomb, oil, mines and the tank gun); armed bombs burn down.
        pub fn sysCarWeapons(self: *Self) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            const w = &self.state.world;
            for (&self.state.sp.arms.arms) |*a| {
                if (a.car.isNone()) continue;
                if (!w.isAlive(a.car)) {
                    a.* = .{};
                    continue;
                }
                if (a.cooldown > 0) a.cooldown -= 1;
                if (a.fuse > 0) {
                    a.fuse -= 1;
                    if (a.fuse == 0) {
                        // The bomb goes off: the car is destroyed, credited
                        // to whoever armed it (sysHealth explodes it).
                        if (w.get(a.car, c.Health)) |h| {
                            h.hp = 0;
                            h.last_hit_by = a.armed_by;
                        }
                        a.* = .{};
                    }
                }
            }
            const bs = &self.state.sp.arms;
            if (bs.builtin_cooldown > 0) bs.builtin_cooldown -= 1;
            for (self.state.players) |pl| {
                if (pl.flags & abi.PlayerRow.flag_active == 0 or pl.car.isNone()) continue;
                fireCar(self, pl.car, pl.ped);
            }
        }

        /// The driver `driver` of `car` works its weapon this tick.
        pub fn fireCar(self: *Self, car: EntityId, driver: EntityId) void {
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle) orelse return;
            if (!eql(v.driver, driver) or v.flags & c.Vehicle.flag_wrecked != 0) return;
            const ctl = w.get(car, c.Controller) orelse return;
            const held = ctl.in.buttons & Button.fire != 0;
            const fresh = held and @as(u16, @truncate(ctl.prev_buttons)) & Button.fire == 0;
            if (!held) return;
            const fitted = armOf(self, car);
            var kind: CarWeapon = .none;
            var cooldown: *u8 = &self.state.sp.arms.builtin_cooldown;
            if (fitted) |a| {
                if (a.ammo > 0) {
                    kind = @enumFromInt(a.kind);
                    cooldown = &a.cooldown;
                }
            }
            if (kind == .none) kind = TC.builtinCarWeapon(v.model);
            const k = @intFromEnum(kind);
            if (k == 0 or k >= TC.car_weapon_kinds) return;
            const def = TC.car_weapons[k];
            if (def.fresh_press and !fresh) {
                // Oil keeps dropping while held after the press.
                if (kind != .oil) return;
            }
            if (cooldown.* > 0) return;
            const t = w.get(car, c.Transform) orelse return;
            const vel = w.get(car, c.Velocity) orelse return;
            const m = T.carModel(v.model);
            const dx = fx.cos(t.heading);
            const dy = fx.sin(t.heading);
            switch (kind) {
                .car_guns => {
                    // Left and right front corners, a little ahead.
                    const ahead = m.half_len + T.shot_radius * 2;
                    const side = m.half_wid - T.shot_radius;
                    shoot(self, car, t, vel, fx.mul(dx, ahead) - fx.mul(-dy, side), fx.mul(dy, ahead) - fx.mul(dx, side), kind);
                    shoot(self, car, t, vel, fx.mul(dx, ahead) + fx.mul(-dy, side), fx.mul(dy, ahead) + fx.mul(dx, side), kind);
                },
                .tank_gun => shoot(self, car, t, vel, fx.mul(dx, @max(TC.tank_barrel, m.half_len + T.shot_radius * 2)), fx.mul(dy, @max(TC.tank_barrel, m.half_len + T.shot_radius * 2)), kind),
                .jeep_gun, .water_cannon, .flamethrower => {
                    const reach = @max(TC.turret_reach, m.half_len + T.shot_radius * 2);
                    shoot(self, car, t, vel, fx.mul(dx, reach), fx.mul(dy, reach), kind);
                },
                .oil, .mines => {
                    const back = m.half_len + TC.drop_behind;
                    const ox = t.x - fx.mul(dx, back);
                    const oy = t.y - fx.mul(dy, back);
                    // Credited: oil to the car, a mine's blast to the driver.
                    _ = if (kind == .oil) Self.objects.dropOil(self, ox, oy, t.z, car) else Self.objects.dropMine(self, ox, oy, t.z, driver);
                },
                .car_bomb => {
                    const a = fitted orelse return;
                    a.fuse = TC.car_bomb_fuse;
                    a.armed_by = driver;
                },
                else => return,
            }
            cooldown.* = def.wait;
            if (fitted) |a| {
                if (a.ammo > 0 and @intFromEnum(kind) == a.kind) a.ammo -|= def.tenths_per_use;
            }
            self.scratch.stats.shots += 1;
            // Armed attacks are reported as a crime (weapons.md 3.7); the
            // wanted API (E) files it.
            if (def.armed_attack) Self.wanted.reportCrime(self, .shot_fired, driver, t.x, t.y, t.z);
        }

        /// A vehicle weapon's projectile from (t + off), flying along the
        /// car's heading with the car's own velocity added. Its owner is
        /// the car, so it never hits the car itself; kills are credited to
        /// the driver through the car.
        fn shoot(self: *Self, car: EntityId, t: *const c.Transform, vel: *const c.Velocity, ox: Fx, oy: Fx, kind: CarWeapon) void {
            const weapon: u8 = T.car_shot_base + @intFromEnum(kind) - 1;
            const def = T.shotDef(weapon);
            const sx = t.x + ox;
            const sy = t.y + oy;
            const sz = t.z + T.shot_height;
            if (map.blocks(self.grid, sx, sy, t.z, T.shot_height)) return;
            const w = &self.state.world;
            const sid = w.spawn(Shot) orelse return;
            w.get(sid, c.Transform).?.* = .{ .x = sx, .y = sy, .z = sz, .heading = t.heading };
            const dx = fx.cos(t.heading);
            const dy = fx.sin(t.heading);
            w.get(sid, c.Velocity).?.* = .{ .vx = vel.vx + fx.mul(dx, def.speed), .vy = vel.vy + fx.mul(dy, def.speed), .vz = 0, .spin = 0 };
            w.get(sid, c.Projectile).?.* = .{ .owner = car, .ttl = def.ttl, .damage = 0, .weapon = weapon };
        }
    };
}
