//! Ped objectives (single player): the two-layer objective system
//! (ped-ai.md 3.1-3.2, 4). Owner: workstream D1; A2, D2 and E call this
//! API and never write `c.Objective` themselves.
//!
//! Each AI ped has a main objective (its job, usually set by a script) and
//! an internal one (a reaction the AI sets itself: fight, flee). The
//! internal one, while set, runs instead of the main one without
//! cancelling it. A handler never moves a ped directly: it writes the
//! ped's controls (`ai/move.zig`), and the on-foot control system moves it
//! like a player. Threats and fleeing are in `ai/threat.zig`, fighting in
//! `ai/combat.zig`, following in `ai/follow.zig`.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const map = prelude.map;
const ecs = prelude.ecs;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const A = @import("../tuning/ped_ai.zig");
const O = c.Objective;
const move_mod = @import("move.zig");
const P = move_mod.P;
pub const threat_mod = @import("threat.zig");
pub const Search = threat_mod.Search;
pub const Reaction = threat_mod.Reaction;

/// D1 salts (0x1300-0x13FF): combat.zig uses 0x1300-0x1303.
const salt_civilian_reaction: u32 = 0x1310;

/// Objective kinds. D1 owns the numbering; append only once others use it.
pub const Kind = enum(u8) {
    none = 0,
    /// Stand still; passes when its timeout runs out.
    wait = 1,
    /// Walk to the point (x, y).
    go_to = 2,
    /// Wander the pavements (the ambient walker).
    wander = 3,
    /// Follow the target ped (3.10).
    follow = 4,
    /// Chase and kill the target ped, by weapon or fist (3.7-3.9).
    kill_ped = 5,
    /// Attack the target car until it is wrecked.
    kill_car = 6,
    /// Flee the target ped until safe (3.5).
    flee_ped = 7,
    /// Flee from the point (x, y) until safe.
    flee_till_safe = 8,
    /// Get into the target car (D2's door sequence when present).
    enter_car = 9,
    /// Get out of the car it is in.
    leave_car = 10,
    /// Guard the point (x, y): fight threats near it, return to it.
    guard = 11,
    /// As kill_car.
    destroy_car = 12,
    /// Patrol on foot (no route data yet: wanders).
    patrol = 13,
    /// Drive the car it is in to (x, y) (F's car task).
    drive_to = 14,
    /// Take the target car (D2 pulls out a driver).
    steal_car = 15,
    /// Punch the target ped, never shoot it (3.9).
    punch_ped = 16,
    /// Flee the target ped until it dies, however far (3.5).
    flee_ped_always = 17,
    /// In a car: wait for it to stop, get out, then flee the target ped
    /// always (3.5).
    flee_on_car_stop = 18,
    _,
};

pub const Status = enum(u8) { none = 0, active = 1, passed = 2, failed = 3 };

pub const Objective = struct {
    kind: Kind = .none,
    target: EntityId = .none,
    x: Fx = 0,
    y: Fx = 0,
    z: Fx = 0,
    /// Give up after this many ticks (0 = never).
    timeout: u16 = 0,
};

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.Ped.has(c.Objective);
        const move = move_mod.Sys(Self);
        const threat = threat_mod.Sys(Self);
        const combat = @import("combat.zig").Sys(Self);
        const follow_ = @import("follow.zig").Sys(Self);
        const Progress = threat.Progress;
        pub const CensusT = threat.CensusT;
        const api = @This();

        fn obj(self: *Self, ped: EntityId) ?*O {
            if (comptime !sp) return null;
            return self.state.world.get(ped, c.Objective);
        }

        // ==================================================================
        // The API (plan-notes.md 5)

        /// Set a ped's main objective (resets its status to active).
        pub fn setObjective(self: *Self, ped: EntityId, o: Objective) void {
            const ob = obj(self, ped) orelse return;
            ensureInit(self, ped, ob);
            ob.main = @backingInt(o.kind);
            ob.main_target = o.target;
            ob.x = o.x;
            ob.y = o.y;
            ob.z = o.z;
            ob.timeout = o.timeout;
            ob.status = @backingInt(if (o.kind == .none) Status.none else Status.active);
            ob.wait = 0;
        }

        /// Set a ped's internal (reactive) objective. A point is stored as
        /// where a flee started.
        pub fn setInternalObjective(self: *Self, ped: EntityId, o: Objective) void {
            const ob = obj(self, ped) orelse return;
            ensureInit(self, ped, ob);
            ob.internal = @backingInt(o.kind);
            ob.internal_target = o.target;
            ob.ix = o.x;
            ob.iy = o.y;
            ob.internal_timeout = o.timeout;
            ob.wait = 0;
            ob.flags &= ~O.flag_assigned_target;
            if (o.kind == .none) ob.flags &= ~(O.flag_attacking | O.flag_panic);
        }

        /// Clear both objectives; the ped goes back to its default
        /// behaviour.
        pub fn clearObjective(self: *Self, ped: EntityId) void {
            const ob = obj(self, ped) orelse return;
            ob.main = 0;
            ob.main_target = .none;
            ob.status = 0;
            ob.timeout = 0;
            clearInternal(self, ped);
        }

        pub fn clearInternal(self: *Self, ped: EntityId) void {
            const ob = obj(self, ped) orelse return;
            ob.internal = 0;
            ob.internal_target = .none;
            ob.internal_timeout = 0;
            ob.flags &= ~(O.flag_attacking | O.flag_panic | O.flag_assigned_target);
        }

        pub fn objectiveOf(self: *const Self, ped: EntityId) Objective {
            const ob = obj(@constCast(self), ped) orelse return .{};
            return .{ .kind = @enumFromInt(ob.main), .target = ob.main_target, .x = ob.x, .y = ob.y, .z = ob.z, .timeout = ob.timeout };
        }

        pub fn internalOf(self: *const Self, ped: EntityId) Objective {
            const ob = obj(@constCast(self), ped) orelse return .{};
            return .{ .kind = @enumFromInt(ob.internal), .target = ob.internal_target, .x = ob.ix, .y = ob.iy, .timeout = ob.internal_timeout };
        }

        pub fn objectiveStatus(self: *const Self, ped: EntityId) Status {
            const ob = obj(@constCast(self), ped) orelse return .none;
            return @enumFromInt(ob.status);
        }

        /// Change a ped's occupation; its search mode and threat reaction
        /// follow unless a script set them.
        pub fn setOccupation(self: *Self, ped: EntityId, o: ids.Occupation) void {
            const ob = obj(self, ped) orelse return;
            ensureInit(self, ped, ob);
            ob.occupation = @backingInt(o);
            applyDefaults(self, ped, ob);
        }

        pub fn occupationOf(self: *const Self, ped: EntityId) ids.Occupation {
            const ob = obj(@constCast(self), ped) orelse return .civilian;
            return @enumFromInt(ob.occupation);
        }

        /// Script 151: how the ped looks for danger.
        pub fn setThreatSearch(self: *Self, ped: EntityId, s: Search) void {
            const ob = obj(self, ped) orelse return;
            ensureInit(self, ped, ob);
            ob.search = @backingInt(s);
        }

        /// Script 152: flee or fight when threatened or attacked.
        pub fn setThreatReaction(self: *Self, ped: EntityId, r: Reaction) void {
            const ob = obj(self, ped) orelse return;
            ensureInit(self, ped, ob);
            ob.reaction = @backingInt(r);
            ob.flags |= O.flag_reaction_set;
        }

        /// Give `ped` the threat search and reaction of `from` (a recruit
        /// copies its recruiter's, ped-ai.md 3.11).
        pub fn copyThreatSettings(self: *Self, ped: EntityId, from: EntityId) void {
            const ob = obj(self, ped) orelse return;
            const src = obj(self, from) orelse return;
            ensureInit(self, ped, ob);
            ensureInit(self, from, src);
            ob.search = src.search;
            ob.reaction = src.reaction;
            ob.flags |= O.flag_reaction_set;
        }

        /// Make `ped` attack `target` now (an internal kill objective).
        pub fn attack(self: *Self, ped: EntityId, target: EntityId) void {
            const ob = obj(self, ped) orelse return;
            const kind: Kind = if (ob.occupation == @backingInt(ids.Occupation.mugger)) .punch_ped else .kill_ped;
            setInternalObjective(self, ped, .{ .kind = kind, .target = target, .timeout = A.attack_timeout });
            ob.flags |= O.flag_attacking;
            if (ob.main_target.raw == target.raw and (ob.main == @backingInt(Kind.kill_ped) or ob.main == @backingInt(Kind.punch_ped)))
                ob.flags |= O.flag_assigned_target;
        }

        /// Make `p` flee `danger` until safe (an internal objective).
        pub fn startFlee(self: *Self, p: P, danger: EntityId) void {
            setInternalObjective(self, p.id, .{ .kind = .flee_ped, .target = danger, .x = p.t.x, .y = p.t.y, .timeout = A.flee_timeout });
            p.o.flags |= O.flag_panic;
        }

        /// Is `b` a threat to `a` (the threat rule, 3.3)?
        pub fn isThreat(self: *Self, a: EntityId, b: EntityId) bool {
            if (comptime !sp) return false;
            var cs: CensusT = .{};
            threat.census(self, &cs);
            return threat.isThreat(self, &cs, a, b);
        }

        /// The best target for `ped` by its search mode (3.4), if any.
        pub fn findTarget(self: *Self, ped: EntityId) ?EntityId {
            if (comptime !sp) return null;
            var cs: CensusT = .{};
            threat.census(self, &cs);
            return threat.findTarget(self, &cs, ped);
        }

        /// Attacking (fire held or swinging) this tick (script 165, 176).
        pub fn isAttacking(self: *const Self, ped: EntityId) bool {
            const ob = obj(@constCast(self), ped) orelse return false;
            return ob.flags & O.flag_attacking != 0;
        }

        /// Has spotted the player (script 251).
        pub fn hasSpottedPlayer(self: *const Self, ped: EntityId) bool {
            const ob = obj(@constCast(self), ped) orelse return false;
            return ob.flags & O.flag_spotted_player != 0;
        }

        /// Whom `ped` last punched, or none (script 255, 264).
        pub fn lastPunched(self: *const Self, ped: EntityId) EntityId {
            const ob = obj(@constCast(self), ped) orelse return .none;
            return ob.punched;
        }

        /// Read and forget whom `ped` last punched (script 252).
        pub fn takePunched(self: *Self, ped: EntityId) EntityId {
            const ob = obj(self, ped) orelse return .none;
            const who = ob.punched;
            ob.punched = .none;
            return who;
        }

        /// Script 360: drop everything and stand idle.
        pub fn forceIdle(self: *Self, ped: EntityId) void {
            setObjective(self, ped, .{ .kind = .wait });
            clearInternal(self, ped);
            const ob = obj(self, ped) orelse return;
            ob.attacker = .none;
        }

        /// Hand a non-player ped one weapon with endless rounds, dropping
        /// what it held (script-characters.md 2.3).
        pub fn armPed(self: *Self, ped: EntityId, weapon: u8) void {
            const w = self.state.world.get(ped, c.Weapon) orelse return;
            for (w.rounds()) |*r| r.* = 0;
            if (weapon >= T.weapon_count) return;
            w.rounds()[weapon] = T.infinite_ammo;
            w.kind = weapon;
        }

        /// Always accurate (no aim jitter) or not.
        pub fn setAccurate(self: *Self, ped: EntityId, on: bool) void {
            const ob = obj(self, ped) orelse return;
            if (on) ob.flags |= O.flag_accurate else ob.flags &= ~O.flag_accurate;
        }

        /// Retreat after landing a hit (3.7, per ped).
        pub fn setHitAndRun(self: *Self, ped: EntityId, on: bool) void {
            const ob = obj(self, ped) orelse return;
            if (on) ob.flags |= O.flag_hit_and_run else ob.flags &= ~O.flag_hit_and_run;
        }

        /// The invisibility power-up's effect (3.15), set and cleared by
        /// G's timer.
        pub fn setInvisible(self: *Self, ped: EntityId, on: bool) void {
            const ob = obj(self, ped) orelse return;
            if (on) ob.flags |= O.flag_invisible else ob.flags &= ~O.flag_invisible;
        }

        /// The electro-fingers power-up's effect (3.14), set and cleared
        /// by G's timer.
        pub fn setElectroFingers(self: *Self, ped: EntityId, on: bool) void {
            const ob = obj(self, ped) orelse return;
            if (on) ob.flags |= O.flag_electro_fingers else ob.flags &= ~O.flag_electro_fingers;
        }

        /// Called by D2 after `victim` was pulled out of its car by
        /// `jacker`: it flees (from where it stands) or fights back.
        pub fn onCarjacked(self: *Self, victim: EntityId, jacker: EntityId) void {
            const ob = obj(self, victim) orelse return;
            if (threat.playerSlot(self, victim) != null) return;
            ensureInit(self, victim, ob);
            const t = self.state.world.get(victim, c.Transform) orelse return;
            if (@as(Reaction, @enumFromInt(ob.reaction)) == .flee or ob.occupation == @backingInt(ids.Occupation.emergency)) {
                setInternalObjective(self, victim, .{ .kind = .flee_till_safe, .x = t.x, .y = t.y, .timeout = A.flee_timeout });
                ob.flags |= O.flag_panic;
            } else attack(self, victim, jacker);
            ob.attacker = jacker;
        }

        // ==================================================================
        // Defaults per occupation (3.2)

        fn ensureInit(self: *Self, ped: EntityId, ob: *O) void {
            if (ob.flags & O.flag_init != 0) return;
            ob.flags |= O.flag_init;
            if (self.state.world.get(ped, c.Health)) |h| ob.prev_hp = h.hp;
            applyDefaults(self, ped, ob);
        }

        fn applyDefaults(self: *Self, ped: EntityId, ob: *O) void {
            const occ: ids.Occupation = @enumFromInt(ob.occupation);
            const fighter = switch (occ) {
                .mugger, .gang_member, .police, .swat, .fbi, .army, .guard => true,
                else => false,
            };
            ob.search = @backingInt(if (fighter) Search.full else Search.none);
            if (ob.flags & O.flag_reaction_set != 0) return;
            const reaction: Reaction = switch (occ) {
                .mugger, .gang_member, .police, .swat, .fbi, .army, .guard, .criminal => .fight,
                // Some ordinary people fight back, most run. Ours: 1 in 4.
                .civilian => if (self.randBelow(ped, salt_civilian_reaction, 4) == 0) .fight else .flee,
                else => .flee,
            };
            ob.reaction = @backingInt(reaction);
        }

        // ==================================================================
        // The system (ped-ai.md 4)

        /// Every AI ped's objectives, once a tick, then electro-fingers.
        pub fn sysObjectives(self: *Self) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            var cs: CensusT = .{};
            threat.census(self, &cs);
            const w = &self.state.world;
            const tb = w.table(Self.Ped);
            var i: u32 = 0;
            while (i < tb.len) : (i += 1) {
                if (tb.slot[i] != ecs.Slot.alive) continue;
                const id = EntityId.make(.ped, i, tb.gen[i]);
                const p = move.ref(self, id) orelse continue;
                p.o.flags &= ~O.flag_steered;
                ensureInit(self, id, p.o);
                if (p.ctl.player != c.Controller.no_player) {
                    p.o.prev_hp = p.h.hp;
                    continue;
                }
                if (p.h.hp <= 0) continue;
                think(self, &cs, p);
            }
            electroFingers(self);
        }

        fn think(self: *Self, cs: *CensusT, p: P) void {
            const o = p.o;
            threat.noticeHits(self, p);
            // Knocked down, falling, in a door sequence: no control.
            if (p.ped.state != c.Pedestrian.state_up) return;
            if (comptime @hasDecl(Self, "enterPhase")) {
                if (self.enterPhase(p.id) != .none) return;
            }
            // Timeouts: the generic give-up (3.1).
            if (o.main != 0 and o.status == @backingInt(Status.active) and o.timeout > 0) {
                o.timeout -= 1;
                if (o.timeout == 0) o.status = @backingInt(if (o.main == @backingInt(Kind.wait)) Status.passed else Status.failed);
            }
            if (o.internal != 0 and o.internal_timeout > 0) {
                o.internal_timeout -= 1;
                if (o.internal_timeout == 0) endInternal(self, p);
            }
            // Reactions: being hit, then the passive panic, then looking
            // for trouble. Each may set the internal objective.
            if (!threat.reactToAttacker(self, cs, p, api) and o.internal == 0) {
                if (!threat.passivePanic(self, cs, p, api) and huntsByDefault(o)) _ = threat.lookForTrouble(self, cs, p, api);
            }
            if (o.internal != 0) {
                const prog = runInternal(self, cs, p);
                if (prog != .running) endInternal(self, p);
                if (o.flags & O.flag_steered != 0) return;
            }
            o.flags &= ~O.flag_attacking;
            if (o.main != 0) runMain(self, cs, p);
        }

        /// Peds that hunt on their own when idle: fighters with a search
        /// mode and no main objective that pins them.
        fn huntsByDefault(o: *const O) bool {
            if (@as(Search, @enumFromInt(o.search)) == .none) return false;
            const k: Kind = @enumFromInt(o.main);
            return switch (k) {
                .none, .wander, .patrol, .wait, .guard => true,
                else => o.status != @backingInt(Status.active),
            };
        }

        fn endInternal(self: *Self, p: P) void {
            if (eql(p.o.internal_target, p.o.attacker)) p.o.attacker = .none;
            clearInternal(self, p.id);
            p.o.wait = 0;
        }

        fn runInternal(self: *Self, cs: *CensusT, p: P) Progress {
            const o = p.o;
            const k: Kind = @enumFromInt(o.internal);
            const assigned = o.flags & O.flag_assigned_target != 0;
            return switch (k) {
                .kill_ped => combat.attackTarget(self, cs, p, o.internal_target, false, assigned),
                .punch_ped => combat.punch(self, p, o.internal_target, assigned),
                .flee_ped => threat.fleePed(self, p, o.internal_target, o.ix, o.iy, false),
                .flee_ped_always => threat.fleePed(self, p, o.internal_target, o.ix, o.iy, true),
                .flee_till_safe => threat.fleePoint(self, p, o.ix, o.iy),
                .follow => switch (follow_.follow(self, p, o.internal_target)) {
                    .failed => .failed,
                    else => .running,
                },
                .flee_on_car_stop => fleeOnCarStop(self, p, true),
                else => .passed,
            };
        }

        fn runMain(self: *Self, cs: *CensusT, p: P) void {
            const o = p.o;
            const k: Kind = @enumFromInt(o.main);
            const active = o.status == @backingInt(Status.active);
            // A finished objective leaves the ped standing, except the
            // ones that keep going (wander, patrol, follow).
            if (!active and k != .follow and k != .wander and k != .patrol) {
                if (k != .none and p.ride.vehicle.isNone()) move.halt(p);
                return;
            }
            const prog: Progress = switch (k) {
                .none, .wander, .patrol => .running,
                .wait => blk: {
                    if (p.ride.vehicle.isNone()) move.halt(p);
                    break :blk .running;
                },
                .go_to => goTo(self, p, o.x, o.y),
                .follow => blk: {
                    const r = follow_.follow(self, p, o.main_target);
                    // Following passes while close, and goes on.
                    if (r == .passed) o.status = @backingInt(Status.passed) else if (r == .running) o.status = @backingInt(Status.active);
                    break :blk if (r == .failed) .failed else .running;
                },
                .kill_ped => combat.attackTarget(self, cs, p, o.main_target, false, true),
                .punch_ped => combat.punch(self, p, o.main_target, true),
                .kill_car, .destroy_car => combat.attackTarget(self, cs, p, o.main_target, true, true),
                .flee_ped => threat.fleePed(self, p, o.main_target, o.x, o.y, false),
                .flee_ped_always => threat.fleePed(self, p, o.main_target, o.x, o.y, true),
                .flee_till_safe => threat.fleePoint(self, p, o.x, o.y),
                .flee_on_car_stop => fleeOnCarStop(self, p, false),
                .enter_car, .steal_car => enterCar(self, p, o.main_target),
                .leave_car => leaveCar(self, p),
                .guard => guard(self, cs, p),
                .drive_to => driveTo(self, p),
                _ => .failed,
            };
            switch (prog) {
                .running => {},
                .passed => o.status = @backingInt(Status.passed),
                .failed => o.status = @backingInt(Status.failed),
            }
            // Finished this tick: stand, rather than hand the tick to the
            // wanderer.
            if (prog != .running and o.flags & O.flag_steered == 0 and p.ride.vehicle.isNone() and k != .wander and k != .patrol) move.halt(p);
        }

        // ------------------------------------------------------------------
        // Main-objective handlers

        fn goTo(self: *Self, p: P, x: Fx, y: Fx) Progress {
            if (!p.ride.vehicle.isNone()) return .failed;
            const d = fx.length(x - p.t.x, y - p.t.y);
            if (d <= A.arrive) {
                move.halt(p);
                return .passed;
            }
            move.goToward(self, p, x, y, 127, false);
            return .running;
        }

        fn enterCar(self: *Self, p: P, car: EntityId) Progress {
            const w = &self.state.world;
            if (eql(p.ride.vehicle, car)) return .passed;
            if (!p.ride.vehicle.isNone()) return .failed;
            const v = w.get(car, c.Vehicle) orelse return .failed;
            if (v.flags & c.Vehicle.flag_wrecked != 0) return .failed;
            const ct = w.get(car, c.Transform).?;
            const d = fx.length(ct.x - p.t.x, ct.y - p.t.y);
            if (d > T.enter_reach) {
                move.goToward(self, p, ct.x, ct.y, 127, d > fx.fromInt(2));
                return .running;
            }
            if (comptime @hasDecl(Self, "startEnter")) {
                self.startEnter(p.id, car);
                return .running;
            }
            // Until D2's door sequence lands: board an empty, still car.
            const vel = w.get(car, c.Velocity).?;
            if (!v.driver.isNone() or Self.speedOf(vel) >= T.enter_max_speed) {
                move.halt(p);
                return .running;
            }
            self.board(p.id, car);
            return .passed;
        }

        fn leaveCar(self: *Self, p: P) Progress {
            if (p.ride.vehicle.isNone()) return .passed;
            self.tryExit(p.id);
            return if (p.ride.vehicle.isNone()) .passed else .running;
        }

        fn driveTo(self: *Self, p: P) Progress {
            const w = &self.state.world;
            const car = p.ride.vehicle;
            const v = w.get(car, c.Vehicle) orelse return .failed;
            if (!eql(v.driver, p.id)) return .failed;
            if (Self.car_tasks.carTaskOf(self, car) != .go_to) Self.car_tasks.setCarTask(self, car, .go_to, .none, p.o.x, p.o.y);
            return if (Self.car_tasks.carArrived(self, car)) .passed else .running;
        }

        fn guard(self: *Self, cs: *CensusT, p: P) Progress {
            _ = cs;
            const d = fx.length(p.o.x - p.t.x, p.o.y - p.t.y);
            if (d > A.arrive) {
                move.goToward(self, p, p.o.x, p.o.y, 127, d > A.guard_range);
            } else move.halt(p);
            return .running;
        }

        /// 3.5: wait for the car to stop, get out, then flee the
        /// remembered danger always (or, with none, the car's spot).
        fn fleeOnCarStop(self: *Self, p: P, internal: bool) Progress {
            const o = p.o;
            const target = if (internal) o.internal_target else o.main_target;
            if (!p.ride.vehicle.isNone()) {
                const cv = self.state.world.get(p.ride.vehicle, c.Velocity) orelse return .failed;
                if (Self.speedOf(cv) <= A.car_still_speed) self.tryExit(p.id);
                return .running;
            }
            const kind: Kind = if (threat.eligible(self, target)) .flee_ped_always else .flee_till_safe;
            const next: Objective = .{ .kind = kind, .target = target, .x = p.t.x, .y = p.t.y, .timeout = A.flee_timeout };
            if (internal) setInternalObjective(self, p.id, next) else setObjective(self, p.id, next);
            o.flags |= O.flag_panic;
            return .running;
        }

        // ------------------------------------------------------------------
        // Electro-fingers (3.14)

        fn electroFingers(self: *Self) void {
            const w = &self.state.world;
            const tb = w.table(Self.Ped);
            var i: u32 = 0;
            while (i < tb.len) : (i += 1) {
                if (tb.slot[i] != ecs.Slot.alive) continue;
                if (tb.col(O)[i].flags & O.flag_electro_fingers == 0) continue;
                if (!tb.col(c.Riding)[i].vehicle.isNone() or tb.col(c.Health)[i].hp <= 0) continue;
                const src = EntityId.make(.ped, i, tb.gen[i]);
                const st = tb.col(c.Transform)[i];
                var j: u32 = 0;
                while (j < tb.len) : (j += 1) {
                    if (j == i or tb.slot[j] != ecs.Slot.alive) continue;
                    if (!tb.col(c.Riding)[j].vehicle.isNone() or tb.col(c.Health)[j].hp <= 0) continue;
                    const tt = tb.col(c.Transform)[j];
                    if (fx.abs(tt.z - st.z) > A.same_height) continue;
                    if (fx.length(tt.x - st.x, tt.y - st.y) > A.electro_fingers_radius) continue;
                    if (!threat.inSight(self, &st, &tt)) continue;
                    const id = EntityId.make(.ped, j, tb.gen[j]);
                    self.hurt(id, A.electro_fingers_damage, src);
                    self.spark(tt.x, tt.y, tt.z, src);
                }
            }
        }
    };
}
