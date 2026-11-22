//! Vehicle weapons (weapons.md 3.7). Owner: workstream G. A car's weapon
//! belongs to the car and is fired by its driver with the fire button.
//! Built-in ones (tank gun, army jeep gun, fire truck cannon) come from the
//! car's model role (`tuning/career.zig`) and never run out; fitted ones
//! (car guns, oil, mines, car bomb from a pickup, a weapon shop, a kill
//! frenzy or a script) live on the car itself, in `c.Vehicle` (`arm`,
//! `arm_ammo`, `bomb_fuse`), so they work in every configuration and reach
//! joining players with the car. Oil and mines are dropped as B's objects.
//! Like the other weapons, only the authoritative sim fires them; a
//! predicting client sees the shots in the next snapshot.
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
const TC = @import("../tuning/career.zig");
const CarWeapon = TC.CarWeapon;

pub fn Sys(comptime Self: type) type {
    return struct {
        const Shot = Self.Shot;

        fn vehicle(self: *Self, car: EntityId) ?*c.Vehicle {
            if (car.isNone()) return null;
            return self.state.world.get(car, c.Vehicle);
        }

        /// The fitted weapon of `car` while it has ammo (or an armed bomb),
        /// else none.
        pub fn fittedOf(self: *Self, car: EntityId) CarWeapon {
            const v = vehicle(self, car) orelse return .none;
            if (v.arm == 0 or v.arm >= TC.car_weapon_kinds) return .none;
            if (v.arm_ammo == 0 and v.bomb_fuse == 0) return .none;
            return @enumFromInt(v.arm);
        }

        /// The weapon `car` carries: fitted, else built in, else none.
        pub fn weaponOf(self: *Self, car: EntityId) CarWeapon {
            const v = vehicle(self, car) orelse return .none;
            const f = fittedOf(self, car);
            if (f != .none) return f;
            return TC.builtinCarWeapon(v.model);
        }

        /// The fitted weapon's ammo in tenths of a displayed round (0 for
        /// none or a built-in one).
        pub fn ammoOf(self: *Self, car: EntityId) u16 {
            const v = vehicle(self, car) orelse return 0;
            return if (v.arm == 0) 0 else v.arm_ammo;
        }

        /// Fit `kind` to `car` with `rounds` displayed rounds (a pickup, a
        /// shop, a kill frenzy or a script). The same kind adds ammo up to
        /// its maximum; another kind replaces the old one. False when the
        /// car already has that kind full (or an armed bomb).
        pub fn arm(self: *Self, car: EntityId, kind: CarWeapon, rounds: u16) bool {
            if (self.predicting()) return false;
            const k = @intFromEnum(kind);
            if (k == 0 or k >= TC.car_weapon_kinds) return false;
            const v = vehicle(self, car) orelse return false;
            if (v.flags & c.Vehicle.flag_wrecked != 0) return false;
            if (v.bomb_fuse > 0) return false;
            const def = TC.car_weapons[k];
            if (v.arm != k) {
                v.arm = k;
                v.arm_ammo = 0;
            } else if (v.arm_ammo >= def.max_tenths) return false;
            v.arm_ammo = @min(def.max_tenths, v.arm_ammo +| rounds *| 10);
            return true;
        }

        /// Would `arm(car, kind, ..)` take anything? (A shop charges only
        /// then.)
        pub fn canArm(self: *Self, car: EntityId, kind: CarWeapon) bool {
            const k = @intFromEnum(kind);
            if (k == 0 or k >= TC.car_weapon_kinds) return false;
            const v = vehicle(self, car) orelse return false;
            if (v.flags & c.Vehicle.flag_wrecked != 0 or v.bomb_fuse > 0) return false;
            return v.arm != k or v.arm_ammo < TC.car_weapons[k].max_tenths;
        }

        /// Remove `car`'s fitted weapon (death and arrest, kill frenzy end).
        /// An armed bomb stays armed.
        pub fn disarm(self: *Self, car: EntityId) void {
            const v = vehicle(self, car) orelse return;
            v.arm_ammo = 0;
            if (v.bomb_fuse == 0) v.arm = 0;
        }

        /// Is a car bomb armed on `car` (script-cars.md 2.6, type 305)?
        pub fn bombArmed(self: *Self, car: EntityId) bool {
            const v = vehicle(self, car) orelse return false;
            return v.bomb_fuse > 0;
        }

        /// Once a tick, before hand weapons: weapon waits run down, armed
        /// bombs burn down, and each player's car fires while its driver
        /// holds fire (or on a fresh press, for the car bomb, oil, mines
        /// and the tank gun).
        pub fn sysCarWeapons(self: *Self) void {
            if (self.predicting()) return;
            const w = &self.state.world;
            w.each(.{ c.Vehicle, c.Health }, self, struct {
                fn f(sim: *Self, _: EntityId, v: *c.Vehicle, h: *c.Health) void {
                    if (v.arm_wait > 0) v.arm_wait -= 1;
                    if (v.bomb_fuse == 0) return;
                    v.bomb_fuse -= 1;
                    if (v.bomb_fuse > 0) return;
                    // The bomb goes off: the car is destroyed, credited to
                    // whoever armed it (sysHealth explodes it).
                    if (v.flags & c.Vehicle.flag_wrecked == 0) {
                        h.hp = 0;
                        if (v.bomb_by > 0 and v.bomb_by <= sim.state.players.len) {
                            h.last_hit_by = sim.state.players[v.bomb_by - 1].ped;
                        }
                    }
                    v.bomb_by = 0;
                    if ((v.arm == @intFromEnum(CarWeapon.car_bomb) or v.arm == @intFromEnum(CarWeapon.instant_bomb)) and v.arm_ammo == 0) v.arm = 0;
                }
            }.f);
            for (self.state.players, 0..) |pl, slot| {
                if (pl.flags & abi.PlayerRow.flag_active == 0 or pl.car.isNone()) continue;
                fireCar(self, pl.car, pl.ped, @intCast(slot));
            }
        }

        /// The driver `driver` (player `slot`) of `car` works its weapon
        /// this tick.
        pub fn fireCar(self: *Self, car: EntityId, driver: EntityId, slot: u8) void {
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle) orelse return;
            if (!eql(v.driver, driver) or v.flags & c.Vehicle.flag_wrecked != 0) return;
            const ctl = w.get(car, c.Controller) orelse return;
            const held = ctl.in.buttons & Button.fire != 0;
            const fresh = held and @as(u16, @truncate(ctl.prev_buttons)) & Button.fire == 0;
            if (!held) return;
            const fitted = fittedOf(self, car);
            const kind: CarWeapon = if (fitted != .none) fitted else TC.builtinCarWeapon(v.model);
            const k = @intFromEnum(kind);
            if (k == 0 or k >= TC.car_weapon_kinds) return;
            const def = TC.car_weapons[k];
            if (def.fresh_press and !fresh) {
                // Oil keeps dropping while held after the press.
                if (kind != .oil) return;
            }
            if (v.arm_wait > 0) return;
            // An armed bomb is already ticking; pressing again does nothing.
            if ((kind == .car_bomb or kind == .instant_bomb) and v.bomb_fuse > 0) return;
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
                    const dropped = if (kind == .oil) Self.objects.dropOil(self, ox, oy, t.z, car) else Self.objects.dropMine(self, ox, oy, t.z, driver);
                    if (dropped == null) return;
                    // A sound for the press (oil then keeps dropping quietly).
                    if (fresh) self.pushEvent(.{ .kind = .car_weapon, .a = slot, .b = k, .c = @intFromEnum(Fitted.dropped), .x = ox, .y = oy, .z = t.z });
                },
                .car_bomb, .instant_bomb => {
                    // The instant bomb goes off on the next tick.
                    v.bomb_fuse = if (kind == .instant_bomb) 1 else TC.car_bomb_fuse;
                    v.bomb_by = slot + 1;
                    self.pushEvent(.{ .kind = .car_weapon, .a = slot, .b = k, .c = @intFromEnum(Fitted.bomb_armed), .x = t.x, .y = t.y, .z = t.z });
                },
                else => return,
            }
            v.arm_wait = def.wait;
            if (fitted != .none) {
                v.arm_ammo -|= def.tenths_per_use;
                // Spent: the car goes back to its built-in weapon, if any
                // (an armed bomb keeps its kind until it goes off).
                if (v.arm_ammo == 0 and v.bomb_fuse == 0) v.arm = 0;
            }
            self.scratch.stats.shots += 1;
            // Armed attacks are reported as a crime (weapons.md 3.7); the
            // wanted API (E) files it in the living city.
            if (def.armed_attack) Self.wanted.reportCrime(self, .shot_fired, driver, t.x, t.y, t.z);
        }

        /// What a `car_weapon` event's `c` says (`wire.EventKind`).
        pub const Fitted = enum(u8) {
            /// A pickup or shop fitted the weapon (b = the kind).
            fitted = 0,
            /// A shop could not fit it: not enough cash or points.
            cannot_pay = 1,
            /// The car already carries it in full.
            full = 2,
            /// The driver armed the car bomb.
            bomb_armed = 3,
            /// The driver dropped a mine or started an oil slick.
            dropped = 4,
        };

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
