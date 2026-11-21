//! Police crews (single player): one car and its officers on a pursuit.
//! Dispatch and the drive over, the car chase with box-in and ram, the
//! on-foot chase and arrest, searching, and the car that takes away an
//! arrested player's body double. Owner: workstream E (police-ai.md 3.1-3.7).
//!
//! Crews drive through F's car tasks and route planner and fight through
//! D1's objectives; the arrest itself is D1's melee rule calling
//! `career.bust` (G). `sp/police.zig` decides how many crews each pursuit
//! wants and calls `update` on each live crew once a tick.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const TP = @import("../tuning/police.zig");
const TC = @import("../tuning/career.zig");
const TF = @import("../tuning/traffic.zig");
const wanted = @import("../sp/wanted.zig");
const Pursuit = wanted.Pursuit;
const Task = @import("car_tasks.zig").Task;

pub const Phase = enum(u8) {
    free = 0,
    /// Waiting out the spawn delay; no car or officers yet.
    spawning = 1,
    /// Driving to the last known position (responding, or searching).
    driving = 2,
    /// Car chase (`Step`).
    chasing = 3,
    /// Officers out, chasing and fighting on foot.
    on_foot = 4,
    /// Officers out at the last known position, looking around.
    search_foot = 5,
    /// Officers walking back to the car.
    boarding = 6,
    /// Taking an arrested player's body double away (no pursuit).
    escort = 7,
    _,
};

/// The car chase against a target in a car (police-ai.md 3.2).
pub const Step = enum(u8) { follow = 0, approach = 1, alongside = 2, ahead = 3, block = 4, parked = 5, ram = 6, _ };

/// One crew, in `police.State.crews`.
pub const Crew = extern struct {
    car: EntityId = .none,
    members: [4]EntityId = @splat(.none),
    /// `Phase`, the pursued player, `ids.Occupation` of the officers.
    phase: u8 = 0,
    slot: u8 = 0,
    kind: u8 = 0,
    /// Box-in side claimed: 0 none, 1 or 2.
    side: u8 = 0,
    /// `Step`.
    step: u8 = 0,
    _pad: u8 = 0,
    /// Spawn delay, then search wait.
    timer: u16 = 0,
    /// Ticks waiting for a side, or chasing without catching up.
    wait: u16 = 0,
    /// Ticks before this crew's ram counts again.
    ram_cool: u16 = 0,
};

/// Salts (E's range, 0x1500-0x15FF).
const salt_spot: u32 = 0x1500;

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;

        fn crews(self: *Self) *[TP.max_crews]Crew {
            return &self.state.sp.police.crews;
        }

        fn alive(self: *Self, id: EntityId) bool {
            if (id.isNone() or !self.state.world.isAlive(id)) return false;
            const h = self.state.world.get(id, c.Health) orelse return false;
            return h.hp > 0;
        }

        fn carUsable(self: *Self, car: EntityId) bool {
            if (car.isNone() or !self.state.world.isAlive(car)) return false;
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            return v.flags & c.Vehicle.flag_wrecked == 0;
        }

        fn riding(self: *Self, ped: EntityId) EntityId {
            const r = self.state.world.get(ped, c.Riding) orelse return .none;
            return r.vehicle;
        }

        fn dist(self: *Self, a: EntityId, b: EntityId) Fx {
            const ta = self.state.world.get(a, c.Transform) orelse return std.math.maxInt(i32);
            const tb = self.state.world.get(b, c.Transform) orelse return std.math.maxInt(i32);
            return fx.length(ta.x - tb.x, ta.y - tb.y);
        }

        fn speedOfId(self: *Self, id: EntityId) Fx {
            const v = self.state.world.get(id, c.Velocity) orelse return 0;
            return Self.speedOf(v);
        }

        /// A model for a crew kind: the first loaded model with that role
        /// (`tuning/career.zig`, filled by the host from the player's data),
        /// else a police model, else model 0 (ours).
        pub fn modelFor(kind: u8) u8 {
            const want: TC.ModelRole = switch (@as(ids.Occupation, @enumFromInt(kind))) {
                .swat => .swat,
                .fbi => .fbi,
                .army => .tank,
                else => .police,
            };
            var fallback: ?u8 = null;
            var m: u8 = 0;
            while (m < T.car_model_count and m < TC.model_roles.len) : (m += 1) {
                if (TC.model_roles[m] == want) return m;
                if (fallback == null and TC.model_roles[m] == .police) fallback = m;
            }
            return fallback orelse 0;
        }

        /// Is `car` one of the crews' cars?
        pub fn crewOfCar(self: *Self, car: EntityId) ?*Crew {
            if (car.isNone()) return null;
            for (crews(self)) |*cr| if (cr.phase != @intFromEnum(Phase.free) and eql(cr.car, car)) return cr;
            return null;
        }

        /// Is `ped` an officer of a crew?
        pub fn crewOfPed(self: *Self, ped: EntityId) ?*Crew {
            if (ped.isNone()) return null;
            for (crews(self)) |*cr| {
                if (cr.phase == @intFromEnum(Phase.free)) continue;
                for (cr.members) |m| if (eql(m, ped)) return cr;
            }
            return null;
        }

        /// Crews (any phase but free) on player `slot`'s pursuit, of `kind`
        /// or of any kind when `kind` is 0.
        pub fn count(self: *Self, slot: u8, kind: u8) u8 {
            var n: u8 = 0;
            for (crews(self)) |cr| {
                if (cr.phase == @intFromEnum(Phase.free) or cr.phase == @intFromEnum(Phase.escort)) continue;
                if (cr.slot == slot and (kind == 0 or cr.kind == kind)) n += 1;
            }
            return n;
        }

        /// Queue a crew of `kind` for player `slot`; it appears after
        /// `delay` ticks. False when every crew slot is taken.
        pub fn dispatch(self: *Self, slot: u8, kind: u8, delay: u16) bool {
            for (crews(self)) |*cr| {
                if (cr.phase != @intFromEnum(Phase.free)) continue;
                cr.* = .{ .phase = @intFromEnum(Phase.spawning), .slot = slot, .kind = kind, .timer = delay };
                return true;
            }
            return false;
        }

        pub fn siren(self: *Self, car: EntityId, on: bool) void {
            const t = self.state.world.get(car, c.Transform) orelse return;
            self.pushEvent(.{ .kind = .siren, .a = @intFromBool(on), .x = t.x, .y = t.y, .z = t.z });
        }

        /// Let a crew go: its car back to ordinary traffic, its officers to
        /// their default behaviour.
        pub fn release(self: *Self, cr: *Crew) void {
            if (carUsable(self, cr.car)) {
                Self.car_tasks.setCarTask(self, cr.car, .none, .none, 0, 0);
                siren(self, cr.car, false);
            }
            for (cr.members) |m| {
                if (alive(self, m)) Self.objectives.clearObjective(self, m);
            }
            cr.* = .{};
        }

        /// A ped for a crew, standing at the car.
        pub fn spawnOfficer(self: *Self, kind: u8, hp: i32, weapon: u8, ct: *const c.Transform) ?EntityId {
            const bx: i32 = fx.toInt(ct.x);
            const by: i32 = fx.toInt(ct.y);
            if (bx < 0 or by < 0 or bx > 255 or by > 255) return null;
            const id = self.spawnPed(c.Controller.no_player, @import("../sim.zig").spawnHint(@intCast(bx), @intCast(by))) orelse return null;
            self.state.world.applyPending();
            const w = &self.state.world;
            w.get(id, c.Transform).?.* = ct.*;
            w.get(id, c.Health).?.hp = hp;
            Self.objectives.setOccupation(self, id, @enumFromInt(kind));
            Self.objectives.armPed(self, id, weapon);
            return id;
        }

        /// Put `ped` in `car` as a passenger (the driver goes through
        /// `board`).
        fn seat(self: *Self, ped: EntityId, car: EntityId) void {
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle) orelse return;
            if (v.driver.isNone()) {
                self.board(ped, car);
                return;
            }
            w.get(ped, c.Riding).?.vehicle = car;
            w.get(ped, c.Collider).?.flags = c.Collider.flag_disabled;
            w.get(ped, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            w.get(ped, c.Transform).?.* = w.get(car, c.Transform).?.*;
        }

        /// Get `ped` out of the car it rides, beside it (left, else right,
        /// else where the car is).
        fn getOut(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const car = riding(self, ped);
            if (car.isNone()) return;
            const ct = (w.get(car, c.Transform) orelse return).*;
            const v = w.get(car, c.Vehicle).?;
            const was_driver = eql(v.driver, ped);
            if (was_driver) self.releaseCar(car);
            defer if (was_driver) {
                // The driver leaving empties the car: the crew's passengers
                // (alive or not) get out with him.
                if (crewOfCar(self, car)) |cr| for (cr.members) |m| {
                    if (!m.isNone() and !eql(m, ped) and eql(riding(self, m), car)) getOut(self, m);
                };
            };
            const m = T.carModel(v.model);
            const off = m.half_wid + T.ped_radius + fx.ratio(1, 10);
            var x = ct.x;
            var y = ct.y;
            var z = ct.z;
            for ([2]u16{ ct.heading -% 16384, ct.heading +% 16384 }) |side| {
                const sx = ct.x + fx.mul(fx.cos(side), off);
                const sy = ct.y + fx.mul(fx.sin(side), off);
                const sz = map.floorAt(self.grid, sx, sy, ct.z, T.ped_step);
                if (sz < ct.z - T.snap_down) continue;
                if (self.circleBlocked(sx, sy, sz, T.ped_radius, T.ped_step)) continue;
                x = sx;
                y = sy;
                z = sz;
                break;
            }
            w.get(ped, c.Transform).?.* = .{ .x = x, .y = y, .z = z, .heading = ct.heading };
            w.get(ped, c.Riding).?.vehicle = .none;
            w.get(ped, c.Collider).?.flags = c.Collider.flag_grounded;
            w.get(ped, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
        }

        /// A clear road spot between `min` and `radius` blocks of (ox, oy):
        /// the spawner's random search, else the nearest road to each of
        /// eight points on the ring (ours), else the nearest road at all.
        fn roadSpot(self: *Self, key: EntityId, clearance: Fx, ox: i32, oy: i32, radius: i32, min: i32) ?Self.Spot {
            if (self.findSpotNear(key, map.Ground.road, clearance, ox, oy, radius, min)) |sp| return sp;
            const r = @max(min, @divTrunc(radius + min, 2));
            const ring = [_][2]i32{ .{ r, 0 }, .{ -r, 0 }, .{ 0, r }, .{ 0, -r }, .{ r, r }, .{ -r, -r }, .{ r, -r }, .{ -r, r }, .{ 0, 0 } };
            for (ring) |d| {
                const n = Self.route.nearestRoadTo(self, ox + d[0], oy + d[1], 1) orelse continue;
                const f = self.columnFloor(n.x, n.y) orelse continue;
                const x = fx.fromInt(n.x) + fx.half;
                const y = fx.fromInt(n.y) + fx.half;
                const z = fx.fromInt(f.z);
                if (self.circleBlocked(x, y, z, clearance, T.ped_step)) continue;
                return .{ .x = x, .y = y, .z = z, .heading = Self.headingFromArrows(map.arrowsOf(f.cell), 0) };
            }
            return null;
        }

        /// Create the car and officers of a crew whose delay ran out, on a
        /// road near the last known position, out of the way. False if no
        /// spot was found (the crew is scrapped).
        fn spawnCrew(self: *Self, cr: *Crew) bool {
            const s = &self.state.sp.wanted[cr.slot];
            const w = &self.state.world;
            const car = w.spawn(Self.Car) orelse return false;
            const model = modelFor(cr.kind);
            const spot = roadSpot(self, car, T.carModel(model).radius, fx.toInt(s.last_x), fx.toInt(s.last_y), TP.spawn_radius, TP.spawn_min) orelse {
                w.despawn(car);
                return false;
            };
            self.initCar(car, spot, model);
            if (comptime Self.Car.has(c.CarTask)) w.get(car, c.CarTask).?.* = .{};
            w.applyPending();
            const ct = w.get(car, c.Transform).?.*;
            const swat = cr.kind == @intFromEnum(ids.Occupation.swat);
            const size: u8 = if (swat) TP.swat_crew_size else TP.police_crew_size;
            const hp: i32 = if (swat) TP.swat_hp else if (s.tier <= 1) TP.police_hp_low else TP.police_hp;
            const weapon: u8 = if (swat or s.tier >= 3) T.weapon_smg else T.weapon_pistol;
            cr.car = car;
            for (0..size) |i| {
                const m = spawnOfficer(self, cr.kind, hp, weapon, &ct) orelse break;
                cr.members[i] = m;
                seat(self, m, car);
            }
            if (cr.members[0].isNone()) {
                w.despawn(car);
                return false;
            }
            w.get(car, c.Vehicle).?.ai_flags |= c.Vehicle.ai_emergency;
            Self.car_tasks.setCarTaskOpts(self, car, .{ .fast_snap = true });
            driveTo(self, cr, s.last_x, s.last_y);
            siren(self, car, true);
            return true;
        }

        /// Car task toward (x, y), re-set only when the goal moves by a
        /// quarter block or more (a new task plans a new route).
        fn goTo(self: *Self, car: EntityId, x: Fx, y: Fx) void {
            const ct = self.state.world.get(car, c.CarTask) orelse return;
            if (ct.task == @intFromEnum(Task.go_to) and @abs(ct.x - x) < fx.one / 4 and @abs(ct.y - y) < fx.one / 4) return;
            Self.car_tasks.setCarTask(self, car, .go_to, .none, x, y);
        }

        fn driveTo(self: *Self, cr: *Crew, x: Fx, y: Fx) void {
            goTo(self, cr.car, x, y);
            cr.phase = @intFromEnum(Phase.driving);
        }

        fn chaseTask(self: *Self, cr: *Crew, target: EntityId, speed: Fx) void {
            const ct = self.state.world.get(cr.car, c.CarTask) orelse return;
            if (ct.task != @intFromEnum(Task.chase) or !eql(ct.target, target))
                Self.car_tasks.setCarTask(self, cr.car, .chase, target, 0, 0);
            Self.car_tasks.setCarTaskOpts(self, cr.car, .{ .fast_snap = true, .speed = speed });
        }

        fn startChase(cr: *Crew) void {
            cr.phase = @intFromEnum(Phase.chasing);
            cr.step = @intFromEnum(Step.follow);
            cr.side = 0;
            cr.wait = 0;
        }

        /// Everyone out; each officer goes for the target (D1's kill
        /// objective: a target in a car is pulled out, a knock-down by law
        /// enforcement is an arrest).
        fn outAndAttack(self: *Self, cr: *Crew, target: EntityId) void {
            if (carUsable(self, cr.car)) Self.car_tasks.setCarTask(self, cr.car, .stop, .none, 0, 0);
            for (cr.members) |m| {
                if (!alive(self, m)) continue;
                getOut(self, m);
                Self.objectives.attack(self, m, target);
            }
            cr.phase = @intFromEnum(Phase.on_foot);
        }

        fn sideTaken(self: *Self, me: *const Crew, side: u8) bool {
            for (crews(self)) |*cr| {
                if (cr == me or cr.phase != @intFromEnum(Phase.chasing)) continue;
                if (cr.slot == me.slot and cr.side == side) return true;
            }
            return false;
        }

        /// The box-in point for a step, from the target car.
        fn boxPoint(t: *const c.Transform, side: u8, step: Step) struct { x: Fx, y: Fx } {
            const fwd_x = fx.cos(t.heading);
            const fwd_y = fx.sin(t.heading);
            const lat: u16 = if (side == 2) t.heading +% 16384 else t.heading -% 16384;
            const lx = fx.cos(lat);
            const ly = fx.sin(lat);
            const along: Fx, const across: Fx = switch (step) {
                .approach => .{ -TP.behind_off, TP.side_off },
                .alongside => .{ 0, TP.side_off },
                .ahead => .{ TP.ahead_off, TP.side_off / 3 },
                else => .{ TP.block_off, 0 },
            };
            return .{ .x = t.x + fx.mul(fwd_x, along) + fx.mul(lx, across), .y = t.y + fx.mul(fwd_y, along) + fx.mul(ly, across) };
        }

        /// The car chase against a target in car `tcar` (police-ai.md 3.2).
        fn boxIn(self: *Self, cr: *Crew, tcar: EntityId) void {
            const s = &self.state.sp.wanted[cr.slot];
            const w = &self.state.world;
            const tt = w.get(tcar, c.Transform) orelse return;
            const tspeed = speedOfId(self, tcar);
            const step: Step = @enumFromInt(cr.step);
            switch (step) {
                .follow => {
                    chaseTask(self, cr, tcar, 0);
                    const arrived = Self.car_tasks.carArrived(self, cr.car);
                    if (!arrived) {
                        cr.wait +|= 1;
                        if (cr.wait > TP.too_fast_ticks) cr.step = @intFromEnum(Step.ram);
                        return;
                    }
                    var side: u8 = 1;
                    while (side <= 2 and sideTaken(self, cr, side)) side += 1;
                    if (side <= 2) {
                        cr.side = side;
                        cr.step = @intFromEnum(Step.approach);
                        cr.wait = 0;
                        return;
                    }
                    // Both sides taken: wait, then ram. Less patience with
                    // several pursuers or high heat; FBI more.
                    cr.wait +|= 1;
                    var patience: u16 = if (s.tier >= 3 or count(self, cr.slot, 0) >= 3) TP.ram_patience_high else TP.ram_patience_low;
                    if (cr.kind == @intFromEnum(ids.Occupation.fbi)) patience *= TP.fbi_patience_mul;
                    if (cr.wait > patience) cr.step = @intFromEnum(Step.ram);
                },
                .approach, .alongside, .ahead, .block => {
                    if (dist(self, cr.car, tcar) > TP.back_to_car_dist) {
                        // Lost touch: back to following.
                        cr.step = @intFromEnum(Step.follow);
                        cr.side = 0;
                        cr.wait = 0;
                        return;
                    }
                    const p = boxPoint(tt, cr.side, step);
                    const ct = w.get(cr.car, c.Transform).?;
                    goTo(self, cr.car, p.x, p.y);
                    const extra: Fx = switch (step) {
                        .alongside => 0,
                        .block => -fx.ratio(5, 100),
                        else => fx.ratio(5, 100),
                    };
                    Self.car_tasks.setCarTaskOpts(self, cr.car, .{ .fast_snap = true, .speed = @max(fx.ratio(5, 100), tspeed + extra) });
                    if (w.get(cr.car, c.Vehicle)) |v| v.flags |= c.Vehicle.flag_horn;
                    if (step == .block) {
                        if (tspeed < TP.stopped_speed) {
                            Self.car_tasks.setCarTask(self, cr.car, .stop, .none, 0, 0);
                            cr.step = @intFromEnum(Step.parked);
                        }
                        return;
                    }
                    if (fx.length(ct.x - p.x, ct.y - p.y) < TP.step_dist) cr.step += 1;
                },
                .parked => {
                    if (tspeed >= TP.stopped_speed * 4) {
                        cr.step = @intFromEnum(Step.follow);
                        cr.side = 0;
                        cr.wait = 0;
                    }
                },
                .ram => {
                    chaseTask(self, cr, tcar, TF.traffic_speed_max);
                },
                _ => cr.step = @intFromEnum(Step.follow),
            }
        }

        /// A crew car hit `hit` (`wanted.onCarImpact`): a deliberate ram on
        /// the target's car adds the flat ram damage (police-ai.md 3.2).
        pub fn onImpact(self: *Self, hit: EntityId, by_car: EntityId) void {
            const cr = crewOfCar(self, by_car) orelse return;
            if (cr.phase != @intFromEnum(Phase.chasing) or cr.step != @intFromEnum(Step.ram) or cr.ram_cool > 0) return;
            if (!eql(self.state.players[cr.slot].car, hit)) return;
            const h = self.state.world.get(hit, c.Health) orelse return;
            h.hp = @max(0, h.hp - TP.ram_damage);
            h.last_hit_by = by_car;
            cr.ram_cool = TP.ram_cooldown;
        }

        /// Officers see the player (police-ai.md 3.3, 4.4): any officer
        /// within view of him checks him (`wanted.copSees`).
        fn look(self: *Self, cr: *Crew, target: EntityId) void {
            const tt = self.state.world.get(target, c.Transform) orelse return;
            for (cr.members) |m| {
                if (!alive(self, m)) continue;
                const mt = self.state.world.get(m, c.Transform) orelse continue;
                if (@abs(mt.x - tt.x) > TP.cop_view_x or @abs(mt.y - tt.y) > TP.cop_view_y or @abs(mt.z - tt.z) > TP.cop_view_z) continue;
                if (Self.wanted.copSees(self, m, cr.slot)) return;
            }
        }

        /// One crew, once a tick.
        pub fn update(self: *Self, cr: *Crew) void {
            if (cr.ram_cool > 0) cr.ram_cool -= 1;
            const phase: Phase = @enumFromInt(cr.phase);
            if (phase == .free) return;
            if (phase == .spawning) {
                if (cr.timer > 0) cr.timer -= 1;
                if (cr.timer == 0 and !spawnCrew(self, cr)) cr.* = .{};
                return;
            }
            if (phase == .escort) return escort(self, cr);
            // Drop the dead and a wrecked car.
            var any = false;
            for (&cr.members) |*m| {
                if (!alive(self, m.*)) {
                    // A dead officer still in the car is taken out first,
                    // so nobody rides a car the crew no longer tracks.
                    if (!cr.car.isNone() and eql(riding(self, m.*), cr.car)) getOut(self, m.*);
                    m.* = .none;
                } else any = true;
            }
            if (!carUsable(self, cr.car)) cr.car = .none;
            if (!any) {
                release(self, cr);
                return;
            }
            const s = &self.state.sp.wanted[cr.slot];
            const pursuit: Pursuit = @enumFromInt(s.pursuit);
            const target = self.state.players[cr.slot].ped;
            if (!alive(self, target)) return;
            const tcar = riding(self, target);
            const out_ = !tcar.isNone();
            look(self, cr, target);
            switch (phase) {
                .driving => {
                    if (pursuit == .active) return startChase(cr);
                    if (cr.car.isNone()) return outAndSearch(self, cr);
                    driveTo(self, cr, s.last_x, s.last_y);
                    if (pursuit == .searching and Self.car_tasks.carArrived(self, cr.car)) outAndSearch(self, cr);
                },
                .chasing => {
                    if (pursuit != .active) {
                        if (cr.car.isNone()) return outAndSearch(self, cr);
                        return driveTo(self, cr, s.last_x, s.last_y);
                    }
                    if (cr.car.isNone()) return outAndAttack(self, cr, target);
                    const d = dist(self, cr.car, target);
                    if (!out_) {
                        // Target on foot: close in by car, then get out.
                        if (d < TP.foot_dist) return outAndAttack(self, cr, target);
                        chaseTask(self, cr, target, 0);
                        cr.side = 0;
                        cr.step = @intFromEnum(Step.follow);
                        return;
                    }
                    if (speedOfId(self, tcar) < TP.stopped_speed and d < TP.pull_out_dist) return outAndAttack(self, cr, target);
                    boxIn(self, cr, tcar);
                },
                .on_foot => {
                    if (pursuit != .active) {
                        if (cr.car.isNone()) return outAndSearch(self, cr);
                        cr.phase = @intFromEnum(Phase.boarding);
                        return;
                    }
                    if (!cr.car.isNone() and dist(self, cr.car, target) > TP.back_to_car_dist) {
                        cr.phase = @intFromEnum(Phase.boarding);
                        return;
                    }
                    for (cr.members) |m| {
                        if (m.isNone()) continue;
                        if (!riding(self, m).isNone()) getOut(self, m);
                        const io = Self.objectives.internalOf(self, m);
                        if (io.kind == .none or !eql(io.target, target)) Self.objectives.attack(self, m, target);
                    }
                },
                .boarding => {
                    if (cr.car.isNone()) return outAndSearch(self, cr);
                    if (pursuit == .active and dist(self, cr.car, target) < TP.foot_dist) return outAndAttack(self, cr, target);
                    var all_in = true;
                    const ctr = self.state.world.get(cr.car, c.Transform).?;
                    for (cr.members) |m| {
                        if (m.isNone() or !riding(self, m).isNone()) continue;
                        if (dist(self, m, cr.car) < TP.board_dist) {
                            Self.objectives.clearObjective(self, m);
                            seat(self, m, cr.car);
                            continue;
                        }
                        all_in = false;
                        const o = Self.objectives.objectiveOf(self, m);
                        if (o.kind != .go_to or fx.toInt(o.x) != fx.toInt(ctr.x) or fx.toInt(o.y) != fx.toInt(ctr.y)) {
                            Self.objectives.clearInternal(self, m);
                            Self.objectives.setObjective(self, m, .{ .kind = .go_to, .x = ctr.x, .y = ctr.y });
                        }
                    }
                    if (!all_in) return;
                    // The first officer in is the driver.
                    if (self.state.world.get(cr.car, c.Vehicle).?.driver.isNone()) {
                        for (cr.members) |m| if (!m.isNone()) {
                            self.state.world.get(m, c.Riding).?.vehicle = .none;
                            self.board(m, cr.car);
                            break;
                        };
                    }
                    Self.car_tasks.setCarTaskOpts(self, cr.car, .{ .fast_snap = true });
                    if (pursuit == .active) startChase(cr) else {
                        Self.car_tasks.setCarTask(self, cr.car, .go_to, .none, s.last_x, s.last_y);
                        cr.phase = @intFromEnum(Phase.driving);
                    }
                },
                .search_foot => {
                    if (pursuit == .active) {
                        if (cr.car.isNone() or dist(self, cr.car, target) < TP.back_to_car_dist) return outAndAttack(self, cr, target);
                        cr.phase = @intFromEnum(Phase.boarding);
                        return;
                    }
                    if (cr.timer > 0) cr.timer -= 1;
                    for (cr.members) |m| {
                        if (m.isNone()) continue;
                        const mt = self.state.world.get(m, c.Transform).?;
                        if (fx.length(mt.x - s.last_x, mt.y - s.last_y) > TP.search_leash and cr.timer < TP.search_wait - 1) {
                            release(self, cr);
                            return;
                        }
                    }
                    if (cr.timer == 0) release(self, cr);
                },
                else => {},
            }
        }

        /// Officers out at the last known position, searching on foot.
        fn outAndSearch(self: *Self, cr: *Crew) void {
            const s = &self.state.sp.wanted[cr.slot];
            if (carUsable(self, cr.car)) Self.car_tasks.setCarTask(self, cr.car, .stop, .none, 0, 0);
            for (cr.members) |m| {
                if (!alive(self, m)) continue;
                getOut(self, m);
                Self.objectives.clearInternal(self, m);
                Self.objectives.setObjective(self, m, .{ .kind = .go_to, .x = s.last_x, .y = s.last_y, .timeout = TP.search_wait });
            }
            cr.phase = @intFromEnum(Phase.search_foot);
            cr.timer = TP.search_wait;
        }

        // ==================================================================
        // The arrested player's body double (power-ups-death-and-arrest.md
        // 3.3 step 3): a police car comes, takes it in and drives off.

        /// Send a car for `double` (an arrested player's body double).
        pub fn callForDouble(self: *Self, double: EntityId) void {
            if (!self.state.world.isAlive(double)) return;
            for (crews(self)) |cr| {
                if (cr.phase == @intFromEnum(Phase.escort) and eql(cr.members[1], double)) return;
            }
            const w = &self.state.world;
            const dt = (w.get(double, c.Transform) orelse return).*;
            const cr = for (crews(self)) |*cr| {
                if (cr.phase == @intFromEnum(Phase.free)) break cr;
            } else return;
            const kind: u8 = @intFromEnum(ids.Occupation.police);
            const car = w.spawn(Self.Car) orelse return;
            const model = modelFor(kind);
            const spot = roadSpot(self, car, T.carModel(model).radius, fx.toInt(dt.x), fx.toInt(dt.y), 4, 0) orelse {
                w.despawn(car);
                return;
            };
            self.initCar(car, spot, model);
            if (comptime Self.Car.has(c.CarTask)) w.get(car, c.CarTask).?.* = .{};
            w.applyPending();
            const ct = w.get(car, c.Transform).?.*;
            const driver = spawnOfficer(self, kind, TP.police_hp, T.weapon_pistol, &ct) orelse {
                w.despawn(car);
                return;
            };
            self.board(driver, car);
            seat(self, double, car);
            w.get(car, c.Vehicle).?.ai_flags |= c.Vehicle.ai_emergency;
            // Off it goes with the traffic.
            Self.car_tasks.setCarTask(self, car, .none, .none, 0, 0);
            w.get(car, c.Vehicle).?.flags |= c.Vehicle.flag_ai;
            cr.* = .{ .phase = @intFromEnum(Phase.escort), .car = car, .kind = kind, .timer = TP.escort_ticks };
            cr.members[0] = driver;
            cr.members[1] = double;
            siren(self, car, true);
        }

        fn escort(self: *Self, cr: *Crew) void {
            if (cr.timer > 0) cr.timer -= 1;
            if (cr.timer > 0 and carUsable(self, cr.car)) return;
            // Gone: the double goes with it.
            const w = &self.state.world;
            if (w.isAlive(cr.members[1]) and eql(riding(self, cr.members[1]), cr.car)) w.despawn(cr.members[1]);
            cr.* = .{};
        }
    };
}
