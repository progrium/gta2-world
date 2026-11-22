//! Trailers and towing (car-height.md 3.7, car-handling.md 7,
//! car-collision.md 3.4, script-cars.md 2.4, docs/research/public-sources.md
//! 5). A cab's `Vehicle.trailerId()` names the car it tows and the trailer's
//! `Vehicle.towId()` names the cab; both replicate, so joiners see the pair.
//!
//! The notes leave the towing itself open (no hitch point, articulation or
//! coupling), so the model is ours: the trailer is pulled, not driven. Each
//! tick, after the cars move, the trailer turns so its rear axle trails
//! the cab's hitch and is placed with its kingpin on the hitch, which gives
//! the cut-in on corners and lets it swing out when the cab turns hard,
//! up to a jack-knife stop. A trailer that would go into a wall stays put
//! and holds the cab back instead. Heights follow the note: the lower half
//! is raised to the other's height and takes its vertical speed.
//!
//! Hitching: a cab created with a trailer model (the creation forms' last
//! field, CAR_DATA's TRAILERMODEL) gets one behind it, and script command
//! 316 joins two cars. A player in a cab drops the trailer with a fresh
//! fire press when the car has no vehicle weapon (public-sources.md 5: a
//! car with a gun selected will not detach), and picks a free one up by
//! backing the hitch slowly onto its kingpin, unless it was hit recently
//! (car-collision.md 3.4). Nobody can get into a towed trailer.

const std = @import("std");
const prelude = @import("../prelude.zig");
const fx = prelude.fx;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const Button = prelude.Button;
const eql = prelude.eql;
const TV = @import("../tuning/vehicles.zig");
const TCars = @import("../tuning/cars.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        const Me = @This();

        /// Can this model be an articulated cab (the style's cab flag)?
        pub fn isCabModel(model: u8) bool {
            return T.carModel(model).flags & TCars.car_flag_cab != 0;
        }
        /// Is this model an articulated trailer (the style's trailer flag)?
        pub fn isTrailerModel(model: u8) bool {
            return T.carModel(model).flags & TCars.car_flag_trailer != 0;
        }

        /// The cab's hitch, along its heading from its centre: over the
        /// rear wheels on a truck cab, the rear bumper on anything else.
        pub fn hitchOffset(model: u8) Fx {
            const m = T.carModel(model);
            return if (isCabModel(model)) -(m.half_len - TV.cab_hitch_in) else -m.half_len;
        }
        /// The trailer's kingpin, forward from its centre.
        pub fn kingpinOffset(model: u8) Fx {
            const m = T.carModel(model);
            return if (isTrailerModel(model)) m.half_len - TV.kingpin_in else m.half_len;
        }

        fn along(t: *const c.Transform, d: Fx) [2]Fx {
            return .{ t.x + fx.mul(fx.cos(t.heading), d), t.y + fx.mul(fx.sin(t.heading), d) };
        }

        /// The car towing `car`, or none.
        pub fn cabOf(self: *Self, car: EntityId) EntityId {
            const v = self.state.world.get(car, c.Vehicle) orelse return .none;
            return v.towId();
        }
        /// The trailer `car` tows, or none.
        pub fn trailerOf(self: *Self, car: EntityId) EntityId {
            const v = self.state.world.get(car, c.Vehicle) orelse return .none;
            return v.trailerId();
        }

        /// Hook `trailer` onto `cab` (316). With `place`, the trailer is
        /// first lined up behind the cab (creation). False if either is
        /// gone, wrecked, already in a pair, or the same car.
        pub fn attach(self: *Self, cab: EntityId, trailer: EntityId, place: bool) bool {
            if (eql(cab, trailer)) return false;
            if (!self.writable(cab) or !self.writable(trailer)) return false;
            const w = &self.state.world;
            const vc = w.get(cab, c.Vehicle) orelse return false;
            const vt = w.get(trailer, c.Vehicle) orelse return false;
            if ((vc.flags | vt.flags) & c.Vehicle.flag_wrecked != 0) return false;
            if (!vc.trailerId().isNone() or !vc.towId().isNone() or !vt.trailerId().isNone() or !vt.towId().isNone()) return false;
            if (!vt.driver.isNone()) return false;
            vc.setTrailer(trailer);
            vt.setTow(cab);
            vt.flags &= ~c.Vehicle.flag_ai;
            if (place) {
                const tc = w.get(cab, c.Transform).?.*;
                const h = along(&tc, hitchOffset(vc.model));
                const tt = w.get(trailer, c.Transform).?;
                tt.heading = tc.heading;
                tt.x = h[0] - fx.mul(fx.cos(tc.heading), kingpinOffset(vt.model));
                tt.y = h[1] - fx.mul(fx.sin(tc.heading), kingpinOffset(vt.model));
                tt.z = tc.z;
                w.get(trailer, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            }
            return true;
        }

        /// Unhook whatever `car` tows, or whatever tows it.
        pub fn detach(self: *Self, car: EntityId) void {
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle) orelse return;
            if (!v.trailerId().isNone()) {
                if (w.get(v.trailerId(), c.Vehicle)) |vt| vt.setTow(.none);
                v.setTrailer(.none);
                v.hit_n = @max(v.hit_n, TV.rehitch_wait);
            }
            if (!v.towId().isNone()) {
                if (w.get(v.towId(), c.Vehicle)) |vc| {
                    vc.setTrailer(.none);
                    vc.hit_n = @max(vc.hit_n, TV.rehitch_wait);
                }
                v.setTow(.none);
            }
        }

        /// A new car of `model` hooked behind `cab` (creation with a
        /// trailer model), or null.
        pub fn spawnBehind(self: *Self, cab: EntityId, model: u16) ?EntityId {
            if (self.predicting()) return null;
            if (model >= T.car_model_count) return null;
            const w = &self.state.world;
            const tc = (w.get(cab, c.Transform) orelse return null).*;
            const id = w.spawn(Self.Car) orelse return null;
            self.initCar(id, .{ .x = tc.x, .y = tc.y, .z = tc.z, .heading = tc.heading }, @intCast(model));
            if (!attach(self, cab, id, true)) {
                w.despawn(id);
                return null;
            }
            return id;
        }

        /// The mass a towing car pulls on top of its own when it
        /// accelerates (none for a truck cab).
        pub fn towMass(self: *Self, v: *const c.Vehicle) Fx {
            if (v.trailerId().isNone()) return 0;
            const vt = self.state.world.get(v.trailerId(), c.Vehicle) orelse return 0;
            const share = if (isCabModel(v.model)) TV.cab_tow_share else TV.car_tow_share;
            return fx.mul(T.carModel(vt.model).mass, share);
        }

        /// Steering multiplier for a car towing (car-handling.md 7: a truck
        /// cab with a trailer x 2.5).
        pub fn turnMul(v: *const c.Vehicle) Fx {
            return if (!v.trailerId().isNone() and isCabModel(v.model)) TV.cab_turn_mul else fx.one;
        }

        /// Are `a` and `b` the two halves of one pair (they never collide)?
        pub fn paired(self: *Self, a: EntityId, b: EntityId) bool {
            const w = &self.state.world;
            const va = w.get(a, c.Vehicle) orelse return false;
            return eql(va.trailerId(), b) or eql(va.towId(), b);
        }

        /// After the cars move: every pair is pulled together, players
        /// drop or pick up trailers.
        pub fn sysTrailers(self: *Self) void {
            playerHitches(self);
            self.state.world.each(.{ c.Vehicle, c.Transform }, self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, _: *c.Transform) void {
                    if (v.trailerId().isNone()) return;
                    Me.follow(sim, id, v);
                }
            }.f);
        }

        /// One pair, one tick.
        fn follow(self: *Self, cab: EntityId, v: *c.Vehicle) void {
            const w = &self.state.world;
            const trailer = v.trailerId();
            const vt = w.get(trailer, c.Vehicle) orelse {
                if (self.writable(cab)) v.setTrailer(.none);
                return;
            };
            if (!eql(vt.towId(), cab)) {
                if (self.writable(cab)) v.setTrailer(.none);
                return;
            }
            if ((v.flags | vt.flags) & c.Vehicle.flag_wrecked != 0 or (v.xflags | vt.xflags) & c.Vehicle.xf_lifted != 0) {
                if (self.writable(cab) and self.writable(trailer)) detach(self, cab);
                return;
            }
            const mine = self.writable(trailer);
            const cab_w = self.writable(cab);
            if (!mine and !cab_w) return;
            const tc = w.get(cab, c.Transform).?;
            const tt = w.get(trailer, c.Transform).?;
            const vel_t = w.get(trailer, c.Velocity).?;
            const mt = T.carModel(vt.model);
            const h = along(tc, hitchOffset(v.model));
            const kp = kingpinOffset(vt.model);
            // The trailer's rear axle trails the hitch.
            const axle = along(tt, mt.rear_axle);
            var heading = fx.atan2(h[1] - axle[1], h[0] - axle[0]);
            if (h[0] == axle[0] and h[1] == axle[1]) heading = tt.heading;
            // Jack-knife stop.
            const art: i16 = @bitCast(heading -% tc.heading);
            const lim: i16 = @intCast(TV.max_articulation);
            if (art > lim) heading = tc.heading +% @as(u16, @bitCast(lim));
            if (art < -lim) heading = tc.heading -% @as(u16, @bitCast(lim));
            const nx = h[0] - fx.mul(fx.cos(heading), kp);
            const ny = h[1] - fx.mul(fx.sin(heading), kp);
            const blocked = self.boxBlocked(nx, ny, tt.z, heading, mt);
            if (mine and !blocked) {
                const dh: i16 = @bitCast(heading -% tt.heading);
                vel_t.vx = nx - tt.x;
                vel_t.vy = ny - tt.y;
                vel_t.spin = angleToRad(dh);
                tt.x = nx;
                tt.y = ny;
                tt.heading = heading;
                self.carSettle(tt, vel_t, w.get(trailer, c.Collider).?, mt);
            } else if (cab_w) {
                // The trailer is jammed: the cab is held back so its hitch
                // stays on the kingpin, and loses its speed.
                const k = along(tt, kp);
                const gap = fx.length(k[0] - h[0], k[1] - h[1]);
                if (gap > TV.break_gap) {
                    if (mine) detach(self, cab);
                    return;
                }
                const mc = T.carModel(v.model);
                const cx = tc.x + (k[0] - h[0]);
                const cy = tc.y + (k[1] - h[1]);
                if (!self.boxBlocked(cx, cy, tc.z, tc.heading, mc)) {
                    tc.x = cx;
                    tc.y = cy;
                }
                const vc = w.get(cab, c.Velocity).?;
                vc.vx = 0;
                vc.vy = 0;
                if (mine) vel_t.* = std.mem.zeroes(c.Velocity);
            }
            // Heights: the lower half rises to the other (car-height.md 3.7).
            if (mine and cab_w) {
                const vc = w.get(cab, c.Velocity).?;
                if (tt.z < tc.z) {
                    tt.z = tc.z;
                    vel_t.vz = vc.vz;
                } else if (tc.z < tt.z) {
                    tc.z = tt.z;
                    vc.vz = vel_t.vz;
                }
            }
        }

        /// Angle units to radians a tick (fixed point), the spin's unit.
        fn angleToRad(a: i16) Fx {
            return @intCast(@divTrunc(@as(i64, a) << fx.frac_bits, T.rad_to_angle));
        }

        /// Players in cars: a fresh fire press with no vehicle weapon drops
        /// the trailer; backing slowly onto a free trailer picks it up.
        fn playerHitches(self: *Self) void {
            const w = &self.state.world;
            for (&self.state.players) |*pl| {
                const car = pl.car;
                const v = w.get(car, c.Vehicle) orelse continue;
                if (!self.writable(car)) continue;
                if (!eql(v.driver, pl.ped)) continue;
                // The car's controller carries the driver's frame and the
                // one before it.
                const ctl = w.get(car, c.Controller) orelse continue;
                if (!v.trailerId().isNone()) {
                    const fresh = ctl.in.buttons & Button.fire != 0 and @as(u16, @truncate(ctl.prev_buttons)) & Button.fire == 0;
                    if (fresh and !hasCarWeapon(self, car) and self.writable(v.trailerId())) detach(self, car);
                    continue;
                }
                if (v.hit_n > 0 or !v.towId().isNone()) continue;
                const vel = w.get(car, c.Velocity).?;
                if (Self.speedOf(vel) > TV.hitch_speed) continue;
                const tc = w.get(car, c.Transform).?.*;
                const h = along(&tc, hitchOffset(v.model));
                const Ctx = struct { sim: *Self, cab: EntityId, h: [2]Fx, z: Fx, heading: u16, best: EntityId = .none, d: Fx = TV.hitch_reach };
                var ctx = Ctx{ .sim = self, .cab = car, .h = h, .z = tc.z, .heading = tc.heading };
                w.each(.{ c.Vehicle, c.Transform }, &ctx, struct {
                    fn f(cx: *Ctx, id: EntityId, vt: *c.Vehicle, tt: *c.Transform) void {
                        if (eql(id, cx.cab)) return;
                        if (!isTrailerModel(vt.model)) return;
                        if (!vt.towId().isNone() or !vt.trailerId().isNone() or !vt.driver.isNone()) return;
                        if (vt.hit_n > 0 or vt.flags & c.Vehicle.flag_wrecked != 0) return;
                        if (fx.abs(tt.z - cx.z) > fx.half) return;
                        const dh: i16 = @bitCast(tt.heading -% cx.heading);
                        if (@abs(@as(i32, dh)) > TV.hitch_angle) return;
                        const k = along(tt, kingpinOffset(vt.model));
                        const d = fx.length(k[0] - cx.h[0], k[1] - cx.h[1]);
                        if (d < cx.d) {
                            cx.d = d;
                            cx.best = id;
                        }
                    }
                }.f);
                if (!ctx.best.isNone()) _ = attach(self, car, ctx.best, false);
            }
        }

        /// Does `car` carry a vehicle weapon?
        fn hasCarWeapon(self: *Self, car: EntityId) bool {
            return Self.car_weapons.weaponOf(self, car) != .none;
        }
    };
}
