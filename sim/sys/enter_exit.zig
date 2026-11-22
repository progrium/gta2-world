//! Getting in and out of cars, carjacking, and keeping riders on their car
//! (entering-and-exiting-cars.md). Owner: workstream D2.
//!
//! Methods of `Sim(cfg)`, aliased in `sim.zig`. Shared by every
//! configuration (plan-notes.md 3.7: entering cars is a shared mechanic).
//!
//! A ped's progress is kept in `Pedestrian.car`, `car_phase`, `car_ticks`
//! and `car_flags`:
//!
//!   walk    running to a door (`state_up`, so he moves and collides as
//!           usual; `sysEnterExit` sets his velocity after `sysPedControl`);
//!   door    at the door playing the entry animation (`state_entering`,
//!           collider off, held at the door); a driver inside is pulled out
//!           on frame 5;
//!   exit    beside the car playing the exit animation (`state_exiting`);
//!   pulled  being pulled out by a carjacker (`state_pulled_out`);
//!   thief   an AI ped driving a car he took, for 600 ticks.
//!
//! Ped AI (D1) starts an AI ped's entry with `startEnter` and reads
//! `enterPhase`; it leaves peds in any phase but `none` alone.

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
const ids = @import("../ids.zig");
const E = T.enter_exit;

/// `Pedestrian.car_phase`.
pub const Phase = enum(u8) { none = 0, walk = 1, door = 2, exit = 3, pulled = 4, thief = 5, _ };

/// `Pedestrian.car_flags`: bit 0 is the door.
pub const flag_door_other: u8 = 1;
/// A hijack happened: the entry animation runs the pull-out frames too.
pub const flag_hijacked: u8 = 2;

pub fn Sys(comptime Self: type) type {
    return struct {
        const Me = @This();
        const World = Self.World;
        const speedOf = Self.speedOf;
        const inRect = Self.inRect;

        // --------------------------------------------------------------
        // API

        /// Where `ped` is in getting in or out of a car.
        pub fn enterPhase(self: *Self, ped: EntityId) Phase {
            const p = self.state.world.get(ped, c.Pedestrian) orelse return .none;
            return @enumFromInt(p.car_phase);
        }

        /// Order `ped` to get into `car` as its driver: he runs to a door,
        /// opens it, pulls out anyone driving and gets in (3.2, 3.3). For
        /// players (from the enter key) and AI (from ped AI and scripts).
        pub fn startEnter(self: *Self, ped: EntityId, car: EntityId) void {
            if (!self.writable(ped)) return;
            const w = &self.state.world;
            const p = w.get(ped, c.Pedestrian) orelse return;
            if (w.get(car, c.Vehicle) == null) return;
            p.car = car;
            p.car_phase = @intFromEnum(Phase.walk);
            p.car_ticks = 0;
            p.car_flags = 0;
        }

        /// Drop whatever car order `ped` has and give him back his body.
        pub fn cancelEnter(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const p = w.get(ped, c.Pedestrian) orelse return;
            const ph: Phase = @enumFromInt(p.car_phase);
            if (ph == .none or ph == .thief) return;
            if (ph != .walk) {
                w.get(ped, c.Collider).?.flags = c.Collider.flag_grounded;
                if (p.state != c.Pedestrian.state_up and isCarState(p.state)) p.state = c.Pedestrian.state_up;
                p.anim = c.Pedestrian.anim_stand;
            }
            clearOrder(p);
        }

        /// The enter key on foot (3.1): look for the nearest car to a point
        /// half a block in front of the ped, up to 3 rings of blocks out,
        /// and set the order to get in.
        pub fn tryEnter(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            if (w.get(ped, c.Health)) |hp| if (hp.hp <= 0) return;
            if (Me.enterPhase(self, ped) == .exit) return;
            const t = w.get(ped, c.Transform).?;
            const sx = t.x + fx.mul(fx.cos(t.heading), T.enter_ahead);
            const sy = t.y + fx.mul(fx.sin(t.heading), T.enter_ahead);
            const Best = struct { id: EntityId = .none, ring: i32 = E.search_rings + 1, d: Fx = 0 };
            var best: Best = .{};
            const Ctx = struct { best: *Best, bx: i32, by: i32, x: Fx, y: Fx, z: Fx, ped: EntityId };
            const ctx = Ctx{ .best = &best, .bx = fx.toInt(sx), .by = fx.toInt(sy), .x = sx, .y = sy, .z = t.z, .ped = ped };
            w.each(.{ c.Vehicle, c.Transform }, ctx, struct {
                fn f(cx: Ctx, id: EntityId, v: *c.Vehicle, ct: *c.Transform) void {
                    if (v.flags & c.Vehicle.flag_wrecked != 0 or eql(v.driver, cx.ped)) return;
                    if (!Me.enterable(v)) return;
                    if (fx.abs(ct.z - cx.z) > fx.half) return;
                    const ring: i32 = @intCast(@max(@abs(fx.toInt(ct.x) - cx.bx), @abs(fx.toInt(ct.y) - cx.by)));
                    if (ring > E.search_rings) return;
                    const d = fx.length(ct.x - cx.x, ct.y - cx.y);
                    if (ring < cx.best.ring or (ring == cx.best.ring and d < cx.best.d)) cx.best.* = .{ .id = id, .ring = ring, .d = d };
                }
            }.f);
            if (best.id.isNone()) return;
            Me.startEnter(self, ped, best.id);
        }

        /// The enter key while driving (3.5): out on the first usable door
        /// once the car is below 0.3 a tick.
        pub fn tryExit(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const car = w.get(ped, c.Riding).?.vehicle;
            const ct = (w.get(car, c.Transform) orelse return).*;
            if (speedOf(w.get(car, c.Velocity).?) >= T.exit_max_speed) return;
            // Not while a crane holds the car (3.5: "zoomed").
            if (w.get(car, c.Vehicle).?.xflags & c.Vehicle.xf_lifted != 0) return;
            const m = T.carModel(w.get(car, c.Vehicle).?.model);
            const door = Me.firstUsableDoor(self, car, &ct, m) orelse return;
            const pos = doorPos(&ct, m, door);
            const z = map.floorAt(self.grid, pos.x, pos.y, ct.z, T.ped_step);
            const ctl = w.get(ped, c.Controller).?;
            const is_player = ctl.player != c.Controller.no_player;
            // The handbrake: set if the driver was not a player, else as the
            // player left it (3.5).
            const handbrake = if (is_player) ctl.in.buttons & Button.handbrake_jump != 0 else true;
            Me.releaseCar(self, car);
            if (handbrake) {
                if (w.get(car, c.Controller)) |cc| cc.in.buttons |= Button.handbrake_jump;
            }
            const t = w.get(ped, c.Transform).?;
            t.* = .{ .x = pos.x, .y = pos.y, .z = z, .heading = ct.heading };
            w.get(ped, c.Riding).?.vehicle = .none;
            w.get(ped, c.Collider).?.flags = c.Collider.flag_disabled;
            w.get(ped, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            const p = w.get(ped, c.Pedestrian).?;
            p.state = c.Pedestrian.state_exiting;
            p.anim = c.Pedestrian.anim_exit_car;
            p.car = car;
            p.car_phase = @intFromEnum(Phase.exit);
            p.car_ticks = 0;
            p.car_flags = door;
            if (is_player) self.state.players[ctl.player].car = .none;
            self.scratch.stats.exits += 1;
        }

        /// Seat `ped` as `car`'s driver (the end of the entry animation).
        pub fn board(self: *Self, ped: EntityId, car: EntityId) void {
            const w = &self.state.world;
            const ctl = w.get(ped, c.Controller).?;
            w.get(ped, c.Riding).?.vehicle = car;
            w.get(ped, c.Collider).?.flags = c.Collider.flag_disabled;
            w.get(ped, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            const pd = w.get(ped, c.Pedestrian).?;
            pd.anim = c.Pedestrian.anim_stand;
            pd.state = c.Pedestrian.state_up;
            pd.turn = 0;
            pd.jump = 0;
            clearOrder(pd);
            const veh = w.get(car, c.Vehicle).?;
            veh.driver = ped;
            veh.flags &= ~c.Vehicle.flag_ai;
            veh.timer = 0;
            const cc = w.get(car, c.Controller).?;
            cc.player = ctl.player;
            // The held buttons carry over, so holding enter does not
            // immediately leave again.
            cc.prev_buttons = ctl.prev_buttons;
            w.get(ped, c.Transform).?.* = w.get(car, c.Transform).?.*;
            if (ctl.player != c.Controller.no_player) {
                self.state.players[ctl.player].car = car;
            } else if (Me.tookOnOwn(self, ped)) {
                // An AI ped who took a car on his own drives it for 600
                // ticks (3.4); one ordered in (a script, a mission route)
                // stays.
                pd.car = car;
                pd.car_phase = @intFromEnum(Phase.thief);
                if (comptime Self.city) Self.car_tasks.setCarTask(self, car, .wander, .none, 0, 0);
            }
            if (comptime Self.single_player) Self.hooks.carEntered(self, car, ped);
            self.scratch.stats.boardings += 1;
        }

        /// The car loses its driver and its controls go neutral.
        pub fn releaseCar(self: *Self, car: EntityId) void {
            const w = &self.state.world;
            if (w.get(car, c.Vehicle)) |v| v.driver = .none;
            if (w.get(car, c.Controller)) |cc| cc.* = .{ .player = c.Controller.no_player, .prev_buttons = 0, .in = Frame.neutral(0) };
        }

        // --------------------------------------------------------------
        // Systems

        /// Every ped with a car order, once a tick after `sysPedControl`
        /// (entering-and-exiting-cars.md 4, step 3).
        pub fn sysEnterExit(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Transform, c.Velocity, c.Controller }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, p: *c.Pedestrian, t: *c.Transform, vel: *c.Velocity, ctl: *c.Controller) void {
                    const ph: Phase = @enumFromInt(p.car_phase);
                    switch (ph) {
                        .none => {},
                        .walk => Me.stepWalk(sim, id, p, t, vel, ctl),
                        .door => Me.stepDoor(sim, id, p, t),
                        .exit => {
                            p.car_ticks +|= 1;
                            if (p.state != c.Pedestrian.state_exiting) return Me.cancelEnter(sim, id);
                            if (anim.frameAt(p.car_ticks, anim.ticks_per_frame.exit_car) < anim.frames.exit_car) return;
                            Me.cancelEnter(sim, id);
                        },
                        .pulled => Me.stepPulled(sim, id, p, t),
                        .thief => {
                            const ride = sim.state.world.get(id, c.Riding).?;
                            if (!eql(ride.vehicle, p.car)) return clearOrder(p);
                            p.car_ticks +|= 1;
                            if (p.car_ticks >= E.thief_ticks) Me.tryExit(sim, id);
                        },
                        _ => clearOrder(p),
                    }
                }
            }.f);
        }

        /// Riders follow their vehicle. An AI ped whose car is gone while he
        /// is in it is removed with it (3.4).
        pub fn sysRiders(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Riding, c.Transform }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, ride: *c.Riding, t: *c.Transform) void {
                    if (ride.vehicle.isNone()) return;
                    const w = &sim.state.world;
                    if (w.get(ride.vehicle, c.Transform)) |ct| {
                        t.* = ct.*;
                        return;
                    }
                    ride.vehicle = .none;
                    if (w.get(id, c.Collider)) |col| col.flags = c.Collider.flag_grounded;
                    if (w.get(id, c.Pedestrian)) |p| {
                        if (p.car_phase == @intFromEnum(Phase.thief)) return sim.kill(id);
                    }
                }
            }.f);
        }

        // --------------------------------------------------------------
        // Phases

        /// 3.2: running to the door.
        fn stepWalk(self: *Self, id: EntityId, p: *c.Pedestrian, t: *c.Transform, vel: *c.Velocity, ctl: *c.Controller) void {
            const w = &self.state.world;
            const car = p.car;
            const v = w.get(car, c.Vehicle) orelse return Me.failEnter(self, id, p);
            if (v.flags & c.Vehicle.flag_wrecked != 0 or p.state != c.Pedestrian.state_up) return Me.failEnter(self, id, p);
            // Any movement or turn key cancels a player's order on foot.
            if (ctl.player != c.Controller.no_player and (ctl.in.steer != 0 or ctl.in.throttle != 0)) return Me.failEnter(self, id, p);
            const ct = w.get(car, c.Transform).?;
            const m = T.carModel(v.model);
            if (fx.length(ct.x - t.x, ct.y - t.y) > E.give_up and !Me.ignoresDistance(self, id)) return Me.failEnter(self, id, p);
            const door = Me.firstUsableDoor(self, car, ct, m) orelse return Me.failEnter(self, id, p);
            p.car_flags = (p.car_flags & ~flag_door_other) | door;
            const pos = doorPos(ct, m, door);
            const dx = pos.x - t.x;
            const dy = pos.y - t.y;
            const d = fx.length(dx, dy);
            const fast = speedOf(w.get(car, c.Velocity).?) >= Me.arriveSpeed(self, id);
            if (!fast and d <= E.door_reach and fx.abs(ct.z - t.z) < T.ped_height + fx.half) {
                // Someone else is already getting in as driver: give up.
                if (Me.otherAtDoor(self, id, car)) return Me.failEnter(self, id, p);
                t.* = .{ .x = pos.x, .y = pos.y, .z = t.z, .heading = ct.heading };
                vel.* = std.mem.zeroes(c.Velocity);
                w.get(id, c.Collider).?.flags = c.Collider.flag_disabled;
                p.state = c.Pedestrian.state_entering;
                p.anim = c.Pedestrian.anim_enter_car;
                p.car_phase = @intFromEnum(Phase.door);
                // The alarm goes off at any attempt (3.2's edge case).
                Self.car_flags.ringAlarm(self, car);
                p.car_ticks = 0;
                p.jump = 0;
                p.turn = 0;
                return;
            }
            if (fast and d <= E.wait_near) {
                vel.vx = 0;
                vel.vy = 0;
                p.anim = c.Pedestrian.anim_stand;
                return;
            }
            const heading = headingTo(dx, dy);
            const speed = @min(T.ped_run, d);
            t.heading = heading;
            vel.vx = fx.mul(fx.cos(heading), speed);
            vel.vy = fx.mul(fx.sin(heading), speed);
            p.anim = c.Pedestrian.anim_run;
        }

        /// 3.3: at the door. Frame 3 checks for a refusal, frame 5 pulls
        /// out a driver, the last frame seats him. A car that moves off
        /// throws him.
        fn stepDoor(self: *Self, id: EntityId, p: *c.Pedestrian, t: *c.Transform) void {
            const w = &self.state.world;
            const car = p.car;
            if (p.state != c.Pedestrian.state_entering) return Me.cancelEnter(self, id);
            const v = w.get(car, c.Vehicle) orelse {
                // The car is gone while he gets in: an AI ped goes too.
                const ctl = w.get(id, c.Controller).?;
                Me.cancelEnter(self, id);
                if (ctl.player == c.Controller.no_player) self.kill(id);
                return;
            };
            if (v.flags & c.Vehicle.flag_wrecked != 0) return Me.cancelEnter(self, id);
            const ct = w.get(car, c.Transform).?;
            const cv = w.get(car, c.Velocity).?;
            if (speedOf(cv) >= Me.arriveSpeed(self, id)) {
                // Thrown off a car that moved away (3.3).
                Me.cancelEnter(self, id);
                const sp = speedOf(cv);
                self.knock(id, c.Pedestrian.state_over, fx.div(cv.vx, sp), fx.div(cv.vy, sp), sp, 0, car);
                return;
            }
            const m = T.carModel(v.model);
            const door: u8 = p.car_flags & flag_door_other;
            const pos = doorPos(ct, m, door);
            t.x = pos.x;
            t.y = pos.y;
            t.heading = ct.heading;
            const before = anim.frameAt(p.car_ticks, anim.ticks_per_frame.enter_car);
            p.car_ticks +|= 1;
            const frame = anim.frameAt(p.car_ticks, anim.ticks_per_frame.enter_car);
            const occupied = !v.driver.isNone() or v.flags & c.Vehicle.flag_ai != 0;
            if (frame != before and frame == anim.frames.enter_refuse and ((occupied and Me.refuses(self, car, id)) or Me.locked(self, car, id))) return Me.cancelEnter(self, id);
            if (frame != before and frame == anim.frames.enter_hijack and occupied and p.car_flags & flag_hijacked == 0) {
                p.car_flags |= flag_hijacked;
                Me.hijack(self, id, car, pos, ct.heading, door);
            }
            const total: u16 = anim.frames.enter_car + (if (p.car_flags & flag_hijacked != 0) anim.frames.pull_out else 0);
            if (frame < total) return;
            if (!self.writable(car)) return; // the server seats him
            // Another driver got in meanwhile (a script): give up.
            if (!v.driver.isNone()) return Me.cancelEnter(self, id);
            Me.board(self, id, car);
        }

        /// Being pulled out: held at the door for the pull-out frames, then
        /// left on the pavement.
        fn stepPulled(self: *Self, id: EntityId, p: *c.Pedestrian, t: *c.Transform) void {
            const w = &self.state.world;
            if (p.state != c.Pedestrian.state_pulled_out) return Me.cancelEnter(self, id);
            p.car_ticks +|= 1;
            if (anim.frameAt(p.car_ticks, anim.ticks_per_frame.enter_car) < anim.frames.pull_out) return;
            const jacker_car = p.car;
            // A step further out from the door, if there is room.
            const side = t.heading -% @as(u16, if (p.car_flags & flag_door_other != 0) 49152 else 16384);
            const x = t.x + fx.mul(fx.cos(side), E.pulled_gap);
            const y = t.y + fx.mul(fx.sin(side), E.pulled_gap);
            const z = map.floorAt(self.grid, x, y, t.z, T.ped_step);
            if (z >= t.z - T.snap_down and !self.circleBlocked(x, y, z, T.ped_radius, T.ped_step)) {
                t.x = x;
                t.y = y;
                t.z = z;
            }
            Me.cancelEnter(self, id);
            const jacker = if (w.get(jacker_car, c.Vehicle)) |v| v.driver else EntityId.none;
            if (comptime Self.city) {
                if (@hasDecl(Self.objectives, "onCarjacked")) Self.objectives.onCarjacked(self, id, jacker);
            }
        }

        /// Frame 5 with someone inside: the driver comes out, the jacker
        /// scores a hijack and the car's gang takes it badly (3.3). A
        /// traffic car with nobody modelled inside gets its driver now.
        fn hijack(self: *Self, ped: EntityId, car: EntityId, pos: Point, heading: u16, door: u8) void {
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle).?;
            var victim = v.driver;
            if (victim.isNone() and !self.predicting()) victim = self.spawnPed(c.Controller.no_player, 0) orelse .none;
            const ctl = w.get(ped, c.Controller).?;
            if (ctl.player != c.Controller.no_player) {
                // Scoring's hijack payment when G's scoreHijack is there.
                if (comptime @hasDecl(Self, "scoreHijack")) self.scoreHijack(@intCast(ctl.player), car) else self.addPoints(@intCast(ctl.player), T.carModel(v.model).value);
                if (comptime Self.city) Self.gangs.onHijack(self, car, ped);
            }
            Me.releaseCar(self, car);
            v.flags &= ~c.Vehicle.flag_ai;
            if (victim.isNone() or !self.writable(victim)) return;
            const vp = w.get(victim, c.Pedestrian) orelse return;
            w.get(victim, c.Riding).?.vehicle = .none;
            w.get(victim, c.Collider).?.flags = c.Collider.flag_disabled;
            w.get(victim, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            const z = w.get(car, c.Transform).?.z;
            w.get(victim, c.Transform).?.* = .{ .x = pos.x, .y = pos.y, .z = z, .heading = heading };
            if (w.get(victim, c.Controller)) |vc| {
                if (vc.player != c.Controller.no_player) self.state.players[vc.player].car = .none;
            }
            vp.state = c.Pedestrian.state_pulled_out;
            vp.anim = c.Pedestrian.anim_down;
            vp.jump = 0;
            vp.turn = 0;
            vp.car = car;
            vp.car_phase = @intFromEnum(Phase.pulled);
            vp.car_ticks = 0;
            vp.car_flags = door;
        }

        fn failEnter(self: *Self, id: EntityId, p: *c.Pedestrian) void {
            _ = self;
            _ = id;
            clearOrder(p);
        }

        // --------------------------------------------------------------
        // Helpers

        fn clearOrder(p: *c.Pedestrian) void {
            p.car = .none;
            p.car_phase = 0;
            p.car_ticks = 0;
            p.car_flags = 0;
        }

        fn isCarState(s: u8) bool {
            return s == c.Pedestrian.state_entering or s == c.Pedestrian.state_exiting or s == c.Pedestrian.state_pulled_out;
        }

        pub const Point = struct { x: Fx, y: Fx };

        /// Door `door` (0 the driver's side, left of travel; 1 the other) of
        /// a car at `ct`.
        pub fn doorPos(ct: *const c.Transform, m: *const T.CarModel, door: u8) Point {
            const side = if (door == 0) ct.heading -% 16384 else ct.heading +% 16384;
            const off = m.half_wid + T.ped_radius + E.door_gap;
            return .{
                .x = ct.x + fx.mul(fx.cos(side), off) + fx.mul(fx.cos(ct.heading), E.door_fwd),
                .y = ct.y + fx.mul(fx.sin(side), off) + fx.mul(fx.sin(ct.heading), E.door_fwd),
            };
        }

        /// The first door whose spot is not in a wall, over a drop or
        /// inside another car (3.2; the exact test is an open question in
        /// the note).
        pub fn firstUsableDoor(self: *Self, car: EntityId, ct: *const c.Transform, m: *const T.CarModel) ?u8 {
            var door: u8 = 0;
            while (door < 2) : (door += 1) {
                const pos = doorPos(ct, m, door);
                const z = map.floorAt(self.grid, pos.x, pos.y, ct.z, T.ped_step);
                if (z < ct.z - T.snap_down) continue;
                if (self.circleBlocked(pos.x, pos.y, z, T.ped_radius, T.ped_step)) continue;
                if (Me.carAt(self, car, pos.x, pos.y, ct.z)) continue;
                return door;
            }
            return null;
        }

        /// Is there a car other than `except` covering (x, y)?
        fn carAt(self: *Self, except: EntityId, x: Fx, y: Fx, z: Fx) bool {
            var hit = false;
            const Ctx = struct { hit: *bool, except: EntityId, x: Fx, y: Fx, z: Fx };
            self.state.world.each(.{ c.Vehicle, c.Transform }, Ctx{ .hit = &hit, .except = except, .x = x, .y = y, .z = z }, struct {
                fn f(cx: Ctx, id: EntityId, v: *c.Vehicle, t: *c.Transform) void {
                    if (eql(id, cx.except) or fx.abs(t.z - cx.z) > fx.half) return;
                    if (inRect(t, T.carModel(v.model), cx.x, cx.y)) cx.hit.* = true;
                }
            }.f);
            return hit;
        }

        /// Is a ped other than `me` already at `car`'s door getting in?
        fn otherAtDoor(self: *Self, me: EntityId, car: EntityId) bool {
            var hit = false;
            const Ctx = struct { hit: *bool, me: EntityId, car: EntityId };
            self.state.world.each(.{c.Pedestrian}, Ctx{ .hit = &hit, .me = me, .car = car }, struct {
                fn f(cx: Ctx, id: EntityId, p: *c.Pedestrian) void {
                    if (eql(id, cx.me) or !eql(p.car, cx.car)) return;
                    if (p.car_phase == @intFromEnum(Phase.door)) cx.hit.* = true;
                }
            }.f);
            return hit;
        }

        /// Can anyone get into this car at all? Not a model with no doors
        /// (trains, container trailers), a towed trailer, or a car on a
        /// crane (public-sources.md 5).
        pub fn enterable(v: *const c.Vehicle) bool {
            if (T.carModel(v.model).doors == 0) return false;
            if (!v.towId().isNone()) return false;
            return v.xflags & c.Vehicle.xf_lifted == 0;
        }

        /// Is `ped` locked out of `car` by its door lock (script-cars.md
        /// 2.5, CHANGE_CAR_LOCK)? Checked at the refusal frame, occupied
        /// or not; the alarm goes off at the attempt.
        fn locked(self: *Self, car: EntityId, ped: EntityId) bool {
            const player = self.state.world.get(ped, c.Controller).?.player != c.Controller.no_player;
            const thief = !player and Me.occupation(self, ped) == .car_thief;
            return Self.car_flags.lockedOut(self, car, player, thief);
        }

        /// Does `car` refuse `ped` (3.3)? A car the script locked refuses
        /// everyone.
        fn refuses(self: *Self, car: EntityId, ped: EntityId) bool {
            _ = ped;
            if (comptime !Self.city) return false;
            const tag = self.state.world.get(car, c.ScriptTag) orelse return false;
            return tag.flags & c.ScriptTag.flag_locked != 0;
        }

        /// A car thief, or a ped with no main objective or a steal-car one.
        /// Always in deathmatch (no objectives there).
        fn tookOnOwn(self: *Self, ped: EntityId) bool {
            if (comptime !Self.city) return true;
            if (Me.occupation(self, ped) == .car_thief) return true;
            const k = Self.objectives.objectiveOf(self, ped).kind;
            return k == .none or k == .steal_car;
        }

        fn occupation(self: *Self, ped: EntityId) ?ids.Occupation {
            if (comptime !Self.city) return null;
            const o = self.state.world.get(ped, c.Objective) orelse return null;
            return @enumFromInt(o.occupation);
        }

        /// 0.1 for law enforcement, else 0.2 (3.2).
        fn arriveSpeed(self: *Self, ped: EntityId) Fx {
            const o = Me.occupation(self, ped) orelse return E.arrive_speed;
            return switch (o) {
                .police, .swat, .fbi, .army => E.arrive_speed_law,
                else => E.arrive_speed,
            };
        }

        /// Script-created peds and emergency workers never give up on a
        /// far car (3.2).
        fn ignoresDistance(self: *Self, ped: EntityId) bool {
            if (comptime !Self.city) return false;
            if (Me.occupation(self, ped) == .emergency) return true;
            const tag = self.state.world.get(ped, c.ScriptTag) orelse return false;
            return tag.handle != 0;
        }

        fn headingTo(dx: Fx, dy: Fx) u16 {
            return fx.atan2(dy, dx);
        }
    };
}
