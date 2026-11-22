//! Per-car flags a script sets (script-cars.md 2.2 and 2.5,
//! docs/research/public-sources.md 4): door locks, bulletproof,
//! rocketproof and flameproof, the alarm, the jammed accelerator, the siren
//! and emergency lights, and the roof number. They live in `c.Vehicle`
//! (`lock`, `xflags`, `roof`, `alarm_n`), so they replicate to joiners like
//! the rest of the car. Every configuration has them; only a level script
//! (or a host) sets them.

const prelude = @import("../prelude.zig");
const c = prelude.c;
const T = prelude.T;
const EntityId = prelude.EntityId;
const TV = @import("../tuning/vehicles.zig");
const TC = @import("../tuning/career.zig");
const TCars = @import("../tuning/cars.zig");

/// What a hit on a car is, for the proof flags.
pub const Cause = enum { bullet, rocket, flame, blast, bomb_close, other };

pub fn Sys(comptime Self: type) type {
    return struct {
        /// Does `car`'s proofing stop damage of this kind? Bulletproof stops
        /// bullets; rocketproof stops rockets, molotovs and explosions,
        /// except a car-size blast very close; flameproof stops fire. The
        /// electro gun, impacts and crushing go through everything.
        pub fn shielded(self: *Self, car: EntityId, cause: Cause) bool {
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            return switch (cause) {
                .bullet => v.xflags & c.Vehicle.xf_bulletproof != 0,
                .rocket, .blast => v.xflags & c.Vehicle.xf_rocketproof != 0,
                .flame => v.xflags & c.Vehicle.xf_flameproof != 0,
                .bomb_close, .other => false,
            };
        }

        /// Set or clear one `xf_*` flag.
        pub fn setFlag(self: *Self, car: EntityId, bit: u8, on: bool) void {
            if (!self.writable(car)) return;
            const v = self.state.world.get(car, c.Vehicle) orelse return;
            if (on) v.xflags |= bit else v.xflags &= ~bit;
        }

        /// CHANGE_CAR_LOCK: a permanent lock is never replaced, except by
        /// another permanent lock (script-cars.md 5).
        pub fn setLock(self: *Self, car: EntityId, lock: u8) void {
            if (!self.writable(car)) return;
            const v = self.state.world.get(car, c.Vehicle) orelse return;
            if (v.lock == c.Vehicle.lock_permanent) return;
            if (lock > c.Vehicle.lock_player) return;
            v.lock = lock;
        }

        /// Is a ped locked out of `car`? `player` for a player's ped,
        /// `thief` for an AI car thief.
        pub fn lockedOut(self: *Self, car: EntityId, player: bool, thief: bool) bool {
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            return switch (v.lock) {
                c.Vehicle.lock_locked, c.Vehicle.lock_permanent => true,
                c.Vehicle.lock_player => player,
                c.Vehicle.lock_thief => thief,
                else => false,
            };
        }

        /// Set the alarm off, if the car has one and it is not ringing.
        pub fn ringAlarm(self: *Self, car: EntityId) void {
            if (self.predicting()) return;
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle) orelse return;
            if (v.xflags & c.Vehicle.xf_alarm == 0 or v.alarm_n > 0) return;
            if (v.flags & c.Vehicle.flag_wrecked != 0) return;
            v.alarm_n = TV.alarm_ticks;
            const t = w.get(car, c.Transform).?;
            self.pushEvent(.{ .kind = .car_alarm, .a = 1, .x = t.x, .y = t.y, .z = t.z });
        }

        /// Can `car` show a siren and emergency lights? Models the style
        /// flags as emergency vehicles, and the FBI car regardless
        /// (script-cars.md 2.5, 361).
        pub fn hasSiren(self: *Self, car: EntityId) bool {
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            return T.carModel(v.model).flags & TCars.car_flag_emerg_lights != 0 or TC.roleOf(v.model) == .fbi;
        }

        /// SET_CAR_EMERG_LIGHTS (361): only on a car that has them.
        pub fn setSiren(self: *Self, car: EntityId, on: bool) void {
            if (!self.writable(car)) return;
            if (on and !hasSiren(self, car)) return;
            const v = self.state.world.get(car, c.Vehicle) orelse return;
            const was = v.xflags & c.Vehicle.xf_siren != 0;
            setFlag(self, car, c.Vehicle.xf_siren, on);
            if (was != on) {
                const t = self.state.world.get(car, c.Transform).?;
                self.pushEvent(.{ .kind = .siren, .a = @intFromBool(on), .x = t.x, .y = t.y, .z = t.z });
            }
        }

        pub fn sirenOn(self: *Self, car: EntityId) bool {
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            return v.xflags & c.Vehicle.xf_siren != 0;
        }

        /// The jammed accelerator (374): a player's throttle with nothing
        /// held reads as full up; down still brakes and reverses.
        pub fn jammedThrottle(v: *const c.Vehicle, throttle: i8, player: bool) i8 {
            if (!player or v.xflags & c.Vehicle.xf_jammed == 0) return throttle;
            return if (throttle == 0) 127 else throttle;
        }

        /// Once a tick: the alarm and "recently hit" timers run down.
        pub fn sysCarFlags(self: *Self) void {
            self.state.world.eachFiltered(.{c.Vehicle}, self.predicting(), self, struct {
                fn f(_: *Self, _: EntityId, v: *c.Vehicle) void {
                    if (v.alarm_n > 0) v.alarm_n -= 1;
                    if (v.hit_n > 0) v.hit_n -= 1;
                }
            }.f);
        }

        /// A car took a hit: the alarm goes off, and the "recently hit"
        /// window opens (car-collision.md 3.4).
        pub fn onHit(self: *Self, car: EntityId, base: u8) void {
            if (!self.writable(car)) return;
            const v = self.state.world.get(car, c.Vehicle) orelse return;
            v.hit_n = @max(v.hit_n, base);
            ringAlarm(self, car);
        }
    };
}
