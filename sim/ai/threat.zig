//! Threats (ped-ai.md 3.3-3.6, 3.13, 3.15): the per-tick census, the
//! threat rule, the best-target search, the dangerous list and the
//! passive panic, remembering an attacker and reacting to it, and the
//! flee objectives. Owner: workstream D1.

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
const P = @import("move.zig").P;

/// How a ped looks for danger (ped-ai.md 2, "search mode"; script 151).
pub const Search = enum(u8) {
    /// Does not look; only reacts to being hit or to the dangerous list.
    none = 0,
    /// Short plain-radius check, the player only.
    player_radius = 1,
    /// Narrow line-of-sight cone, the player only.
    player_narrow = 2,
    /// Wide line-of-sight cone, the player only.
    player_wide = 3,
    /// Full check: anyone, on screen, same level, in sight.
    full = 4,
    _,
};

/// Threat reaction (ped-ai.md 2; script 152).
pub const Reaction = enum(u8) { fight = 0, flee = 1, _ };

pub const max_danger = 32;

/// Derived once a tick before any ped thinks; never saved.
pub fn Census(comptime max_players: usize) type {
    return struct {
        pub const Player = struct { id: EntityId = .none, x: Fx = 0, y: Fx = 0, z: Fx = 0, on_foot: bool = false };
        pub const Danger = struct { ped: EntityId, x: Fx, y: Fx, z: Fx };
        players: [max_players]Player = @splat(.{}),
        /// Law-enforcement peds on each player's screen.
        law_on_screen: [max_players]u8 = @splat(0),
        /// The cop holding the "one firing at a time" turn per player.
        firing: [max_players]EntityId = @splat(EntityId.none),
        danger: [max_danger]Danger = undefined,
        n_danger: usize = 0,
    };
}

pub fn isLaw(occ: u8) bool {
    return switch (@as(ids.Occupation, @enumFromInt(occ))) {
        .police, .swat, .fbi, .army, .guard => true,
        else => false,
    };
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const move = @import("move.zig").Sys(Self);
        const max_players = Self.config.max_players;
        pub const CensusT = Census(max_players);

        // ------------------------------------------------------------------
        // Small queries

        pub fn objOf(self: *Self, id: EntityId) ?*O {
            if (comptime !Self.Ped.has(c.Objective)) return null;
            return self.state.world.get(id, c.Objective);
        }

        pub fn playerSlot(self: *Self, id: EntityId) ?u8 {
            const ctl = self.state.world.get(id, c.Controller) orelse return null;
            if (id.kind() != @backingInt(abi.Kind.ped) or ctl.player == c.Controller.no_player) return null;
            return @intCast(ctl.player);
        }

        pub fn onFoot(self: *Self, id: EntityId) bool {
            const r = self.state.world.get(id, c.Riding) orelse return false;
            return r.vehicle.isNone();
        }

        pub fn gangOf(self: *Self, id: EntityId) u8 {
            if (comptime !Self.Ped.has(c.Group)) return ids.gang_none;
            const g = self.state.world.get(id, c.Group) orelse return ids.gang_none;
            return g.gang;
        }

        /// The leader of `id`'s follower group, if it follows someone.
        pub fn leaderOf(self: *Self, id: EntityId) ?EntityId {
            if (comptime !Self.Ped.has(c.Group)) return null;
            const g = self.state.world.get(id, c.Group) orelse return null;
            if (g.leader.kind() != @backingInt(abi.Kind.ped) or !self.state.world.isAlive(g.leader)) return null;
            return g.leader;
        }

        /// A group is named by its leader: a follower's leader, else itself.
        fn groupKey(self: *Self, id: EntityId) EntityId {
            return leaderOf(self, id) orelse id;
        }

        pub fn sameGroup(self: *Self, a: EntityId, b: EntityId) bool {
            if (leaderOf(self, a) == null and leaderOf(self, b) == null) return false;
            return eql(groupKey(self, a), groupKey(self, b));
        }

        pub fn occupationOf(self: *Self, id: EntityId) ids.Occupation {
            if (playerSlot(self, id) != null) return .player;
            const o = objOf(self, id) orelse return .civilian;
            return @enumFromInt(o.occupation);
        }

        pub fn hostile(self: *Self, a: u8, b: u8) bool {
            if (comptime @hasDecl(Self.gangs, "hostile")) return Self.gangs.hostile(self, a, b);
            return a != b;
        }

        /// Holding a weapon with rounds in it.
        pub fn armed(self: *Self, id: EntityId) bool {
            const w = self.state.world.get(id, c.Weapon) orelse return false;
            if (w.kind >= T.weapon_count) return false;
            return w.roundsConst()[w.kind] != 0;
        }

        pub fn isAttacking(self: *Self, id: EntityId) bool {
            const o = objOf(self, id) orelse return false;
            return o.flags & O.flag_attacking != 0;
        }

        /// The ped `id` is hunting (internal or main kill or punch), if any.
        pub fn huntTarget(self: *Self, id: EntityId) ?EntityId {
            const o = objOf(self, id) orelse return null;
            if (isHunt(o.internal)) return o.internal_target;
            if (isHunt(o.main) and o.status == 1) return o.main_target;
            return null;
        }

        pub fn isHunt(k: u8) bool {
            return k == 5 or k == 16; // kill_ped, punch_ped
        }

        pub fn invisibleOnFoot(self: *Self, id: EntityId) bool {
            const o = objOf(self, id) orelse return false;
            return o.flags & O.flag_invisible != 0 and onFoot(self, id);
        }

        /// Alive, standing or at least not out of it, and still in play.
        pub fn eligible(self: *Self, id: EntityId) bool {
            const w = &self.state.world;
            if (!w.isAlive(id)) return false;
            const h = w.get(id, c.Health) orelse return false;
            if (h.hp <= 0) return false;
            const p = w.get(id, c.Pedestrian) orelse return false;
            return switch (p.state) {
                c.Pedestrian.state_fatal, c.Pedestrian.state_arrested, c.Pedestrian.state_electrocuted, c.Pedestrian.state_drowning => false,
                else => true,
            };
        }

        /// Position of an entity (the car's, for a ped riding one).
        pub fn posOf(self: *Self, id: EntityId) ?c.Transform {
            const w = &self.state.world;
            if (w.get(id, c.Riding)) |r| {
                if (!r.vehicle.isNone()) {
                    if (w.get(r.vehicle, c.Transform)) |ct| return ct.*;
                }
            }
            const t = w.get(id, c.Transform) orelse return null;
            return t.*;
        }

        pub fn onScreenOf(cs: *const CensusT, slot: usize, x: Fx, y: Fx) bool {
            const pl = cs.players[slot];
            if (pl.id.isNone()) return false;
            return fx.abs(x - pl.x) <= A.screen_half_w and fx.abs(y - pl.y) <= A.screen_half_h;
        }

        fn anyPlayerScreen(cs: *const CensusT, x: Fx, y: Fx) ?usize {
            for (0..max_players) |s| if (onScreenOf(cs, s, x, y)) return s;
            return null;
        }

        pub fn inSight(self: *Self, a: *const c.Transform, b: *const c.Transform) bool {
            return !map.moveHitsWall(self.grid, a.x, a.y, b.x, b.y, a.z + T.shot_height, map.bullet);
        }

        // ------------------------------------------------------------------
        // Census

        pub fn census(self: *Self, cs: *CensusT) void {
            const w = &self.state.world;
            for (0..max_players) |s| {
                const row = self.state.players[s];
                if (!w.isAlive(row.ped)) continue;
                const pos = posOf(self, row.ped) orelse continue;
                cs.players[s] = .{ .id = row.ped, .x = pos.x, .y = pos.y, .z = pos.z, .on_foot = onFoot(self, row.ped) };
            }
            const tb = w.table(Self.Ped);
            // Attackers per ped are recounted every tick.
            var i: u32 = 0;
            while (i < tb.len) : (i += 1) {
                if (tb.slot[i] != ecs.Slot.alive) continue;
                tb.col(O)[i].attackers = 0;
            }
            i = 0;
            while (i < tb.len) : (i += 1) {
                if (tb.slot[i] != ecs.Slot.alive) continue;
                const id = EntityId.make(.ped, i, tb.gen[i]);
                const o = &tb.col(O)[i];
                const t = &tb.col(c.Transform)[i];
                if (tb.col(c.Health)[i].hp <= 0) continue;
                if (huntTarget(self, id)) |tg| {
                    if (objOf(self, tg)) |to| to.attackers +|= 1;
                }
                if (isLaw(o.occupation) and tb.col(c.Controller)[i].player == c.Controller.no_player) {
                    for (0..max_players) |s| {
                        if (onScreenOf(cs, s, t.x, t.y)) cs.law_on_screen[s] +|= 1;
                        if (o.flags & O.flag_firing_turn != 0) {
                            if (huntTarget(self, id)) |tg| {
                                if (eql(tg, cs.players[s].id)) cs.firing[s] = id;
                            }
                        }
                    }
                }
                // The dangerous list (3.5): armed players on foot, armed
                // peds on the attack, and drivers of cars moving fast.
                if (cs.n_danger >= max_danger) continue;
                const ride = tb.col(c.Riding)[i];
                const is_player = tb.col(c.Controller)[i].player != c.Controller.no_player;
                if (ride.vehicle.isNone()) {
                    if (armed(self, id) and (is_player or o.flags & O.flag_attacking != 0)) {
                        cs.danger[cs.n_danger] = .{ .ped = id, .x = t.x, .y = t.y, .z = t.z };
                        cs.n_danger += 1;
                    }
                } else if (w.get(ride.vehicle, c.Vehicle)) |v| {
                    if (!eql(v.driver, id)) continue;
                    const vel = w.get(ride.vehicle, c.Velocity) orelse continue;
                    const ct = w.get(ride.vehicle, c.Transform) orelse continue;
                    if (Self.speedOf(vel) > A.dangerous_car_speed and (is_player or o.flags & O.flag_attacking != 0)) {
                        cs.danger[cs.n_danger] = .{ .ped = id, .x = ct.x, .y = ct.y, .z = ct.z };
                        cs.n_danger += 1;
                    }
                }
            }
        }

        // ------------------------------------------------------------------
        // The threat rule (3.3): is `b` a threat to `a`?

        pub fn isThreat(self: *Self, cs: *const CensusT, a: EntityId, b: EntityId) bool {
            if (eql(a, b) or !eligible(self, b)) return false;
            const oa = objOf(self, a) orelse return false;
            const b_slot = playerSlot(self, b);
            const b_player = b_slot != null;
            // 1. Invisible on foot: never.
            if (invisibleOnFoot(self, b)) return false;
            // 2. Player-only searchers ignore everyone else.
            const search: Search = @enumFromInt(oa.search);
            if (search != .none and search != .full and !b_player) return false;
            // 3. Same follower group: never.
            if (sameGroup(self, a, b)) return false;
            const occ_a: ids.Occupation = @enumFromInt(oa.occupation);
            // 4. A mugger: everyone.
            if (occ_a == .mugger) return true;
            const ga = gangOf(self, a);
            const occ_b = occupationOf(self, b);
            if (ga != ids.gang_none) {
                // 5. Gang members.
                const gb = gangOf(self, b);
                const respect: i8 = Self.gangs.respect(self, ga);
                if (gb == ga and !b_player) return false;
                if (gb != ga and gb != ids.gang_none) {
                    if (!hostile(self, ga, gb)) return false;
                    const ob = objOf(self, b).?;
                    const crowded = ob.attackers >= A.crowd_cap or ob.attackers_ever >= A.crowd_cap;
                    if (crowded and occ_a != .gang_member) return false;
                    return true;
                }
                if (respect >= A.high_respect and isLaw(@backingInt(occ_b))) return true;
                if (huntTarget(self, b)) |victim| {
                    const ta = self.state.world.get(a, c.Transform).?;
                    const tb_ = posOf(self, b) orelse return false;
                    if (eql(victim, a) and fx.length(tb_.x - ta.x, tb_.y - ta.y) <= A.near_attack) return true;
                    if (armed(self, a)) return true;
                    if (b_player) return respect < 0 and !policeVisible(cs);
                    return false;
                }
                if (b_player) return respect < 0 and !policeVisible(cs);
            } else {
                // 6. No gang: civilians and law enforcement.
                if (occ_a == .criminal and occ_b == .criminal) return false;
                if (isLaw(oa.occupation)) {
                    if (b_player) {
                        const bp = self.state.world.get(b, c.Pedestrian).?;
                        if (bp.jump > 0) return false;
                        const stars = Self.wanted.stars(self, b_slot.?);
                        if (!armed(self, b) and stars == 0 and !isAttacking(self, b)) return false;
                        return true;
                    }
                    if (isLaw(@backingInt(occ_b)) or occ_b == .emergency) return false;
                    return isAttacking(self, b) or huntTarget(self, b) != null;
                }
                if (leaderOf(self, a)) |leader| {
                    if (huntTarget(self, b)) |victim| return eql(victim, leader);
                    return false;
                }
            }
            // 7. Undecided: the player is a threat, anyone else is not.
            return b_player;
        }

        fn policeVisible(cs: *const CensusT) bool {
            for (cs.law_on_screen) |n| if (n > 0) return true;
            return false;
        }

        // ------------------------------------------------------------------
        // Best-target search (3.4)

        /// The nearest threat to `a` by its search mode, or none.
        pub fn findTarget(self: *Self, cs: *const CensusT, a: EntityId) ?EntityId {
            const oa = objOf(self, a) orelse return null;
            const ta = (self.state.world.get(a, c.Transform) orelse return null).*;
            const search: Search = @enumFromInt(oa.search);
            switch (search) {
                .none => return null,
                .player_radius, .player_narrow, .player_wide => {
                    for (cs.players) |pl| {
                        if (pl.id.isNone()) continue;
                        const dx = pl.x - ta.x;
                        const dy = pl.y - ta.y;
                        const d = fx.length(dx, dy);
                        if (fx.abs(pl.z - ta.z) > A.same_level) continue;
                        if (search == .player_radius) {
                            if (d > A.search_short) continue;
                        } else {
                            if (d > A.search_range) continue;
                            const cone = if (search == .player_narrow) A.cone_narrow else A.cone_wide;
                            if (d > 0 and move.angleDiff(fx.atan2(dy, dx), ta.heading) > cone) continue;
                            const pt: c.Transform = .{ .x = pl.x, .y = pl.y, .z = pl.z, .heading = 0 };
                            if (!inSight(self, &ta, &pt)) continue;
                        }
                        if (isThreat(self, cs, a, pl.id)) return pl.id;
                    }
                    return null;
                },
                else => {},
            }
            // Full: the nearest ped (or car's driver) within range, same
            // level, in sight, passing the rule; a player only if `a` is on
            // that player's screen.
            const Best = struct { id: EntityId = .none, d: Fx = A.search_range + 1 };
            var best: Best = .{};
            const w = &self.state.world;
            const tb = w.table(Self.Ped);
            var i: u32 = 0;
            while (i < tb.len) : (i += 1) {
                if (tb.slot[i] != ecs.Slot.alive) continue;
                const id = EntityId.make(.ped, i, tb.gen[i]);
                if (eql(id, a)) continue;
                const pos = posOf(self, id) orelse continue;
                const d = fx.length(pos.x - ta.x, pos.y - ta.y);
                if (d >= best.d or fx.abs(pos.z - ta.z) > A.same_level) continue;
                const ctl = tb.col(c.Controller)[i];
                if (ctl.player != c.Controller.no_player) {
                    if (!onScreenOf(cs, ctl.player, ta.x, ta.y)) continue;
                }
                if (!inSight(self, &ta, &pos)) continue;
                if (!isThreat(self, cs, a, id)) continue;
                best = .{ .id = id, .d = d };
            }
            if (!best.id.isNone()) return best.id;
            // Fallback: the dangerous list.
            for (cs.danger[0..cs.n_danger]) |dg| {
                if (eql(dg.ped, a)) continue;
                const d = fx.length(dg.x - ta.x, dg.y - ta.y);
                if (d > A.search_range or d >= best.d or fx.abs(dg.z - ta.z) > A.same_level) continue;
                if (!isThreat(self, cs, a, dg.ped)) continue;
                best = .{ .id = dg.ped, .d = d };
            }
            return if (best.id.isNone()) null else best.id;
        }

        // ------------------------------------------------------------------
        // Being attacked (3.6) and the passive panic (3.5)

        /// Notice a fresh hit and remember the attacker; tell an AI shooter
        /// whose shot hit the wrong ped to switch to test shots.
        pub fn noticeHits(self: *Self, p: P) void {
            const o = p.o;
            defer o.prev_hp = p.h.hp;
            if (p.h.hp >= o.prev_hp) return;
            var by = p.h.last_hit_by;
            if (by.kind() == @backingInt(abi.Kind.car)) {
                const v = self.state.world.get(by, c.Vehicle) orelse return;
                by = v.driver;
            }
            if (by.kind() != @backingInt(abi.Kind.ped) or eql(by, p.id) or !self.state.world.isAlive(by)) return;
            if (!eql(o.attacker, by)) {
                o.attacker = by;
                o.attackers_ever +|= 1;
                o.unseen = 0;
            }
            // weapons.md 3.8 and ped-ai.md 3.7 hit-and-run, from the
            // shooter's side.
            const ob = objOf(self, by) orelse return;
            if (playerSlot(self, by) != null) return;
            if (huntTarget(self, by)) |tg| {
                if (!eql(tg, p.id) and armed(self, by)) ob.flags |= O.flag_test_shots;
                if (eql(tg, p.id) and ob.flags & O.flag_hit_and_run != 0) ob.retreat = A.hit_and_run_ticks;
            }
        }

        /// Act on the remembered attacker (3.6). Returns true if it set an
        /// internal objective.
        pub fn reactToAttacker(self: *Self, cs: *const CensusT, p: P, objectives: anytype) bool {
            const o = p.o;
            const by = o.attacker;
            if (by.isNone()) return false;
            if (!eligible(self, by)) {
                o.attacker = .none;
                o.flags &= ~O.flag_panic;
                return false;
            }
            const ga = gangOf(self, p.id);
            if ((ga != ids.gang_none and ga == gangOf(self, by)) or sameGroup(self, p.id, by) or invisibleOnFoot(self, by)) {
                o.attacker = .none;
                return false;
            }
            if (o.internal != 0 and eql(o.internal_target, by)) return false;
            if (o.occupation == @backingInt(ids.Occupation.emergency)) {
                o.attacker = .none;
                return false;
            }
            const reaction: Reaction = @enumFromInt(o.reaction);
            if (reaction == .flee) {
                objectives.startFlee(self, p, by);
                return true;
            }
            if (leaderOf(self, p.id)) |leader| {
                if (playerSlot(self, leader)) |slot| {
                    const at = posOf(self, by) orelse return false;
                    const seen = onScreenOf(cs, slot, at.x, at.y);
                    o.unseen = if (seen) 0 else o.unseen +| 1;
                    if (!seen or o.unseen >= A.unseen_drop) {
                        if (o.unseen >= A.unseen_drop) o.attacker = .none;
                        return false;
                    }
                    if (fx.abs(at.z - p.t.z) > A.same_height) return false;
                }
            }
            objectives.attack(self, p.id, by);
            return true;
        }

        /// The passive trigger (3.5): the nearest dangerous ped within 4
        /// blocks makes a fleer panic and run from it.
        pub fn passivePanic(self: *Self, cs: *const CensusT, p: P, objectives: anytype) bool {
            if (@as(Reaction, @enumFromInt(p.o.reaction)) != .flee) return false;
            var best: ?EntityId = null;
            var bd: Fx = A.panic_range + 1;
            for (cs.danger[0..cs.n_danger]) |dg| {
                if (eql(dg.ped, p.id) or sameGroup(self, p.id, dg.ped)) continue;
                if (fx.abs(dg.z - p.t.z) > A.same_level) continue;
                const d = fx.length(dg.x - p.t.x, dg.y - p.t.y);
                if (d < bd) {
                    bd = d;
                    best = dg.ped;
                }
            }
            if (best == null or bd > A.panic_range) return false;
            if (invisibleOnFoot(self, best.?)) return false;
            objectives.startFlee(self, p, best.?);
            return true;
        }

        /// A target search for a ped that hunts (fighters and muggers),
        /// staggered so each looks every `search_every` ticks.
        pub fn lookForTrouble(self: *Self, cs: *const CensusT, p: P, objectives: anytype) bool {
            const o = p.o;
            if (o.think > 0) {
                o.think -= 1;
                return false;
            }
            o.think = A.search_every - 1;
            if (@as(Search, @enumFromInt(o.search)) == .none) return false;
            const target = findTarget(self, cs, p.id) orelse return false;
            if (playerSlot(self, target)) |slot| {
                // A cop who engages the player: E's witness check decides,
                // moves the last known position and raises him to at least
                // one star (3.3, rule 6; wanted-level.md 3.3).
                if (isLaw(o.occupation)) {
                    if (comptime @hasDecl(Self.wanted, "copSees")) {
                        if (!Self.wanted.copSees(self, p.id, slot)) return false;
                    } else if (p.ride.vehicle.isNone()) Self.wanted.atLeastOneStar(self, slot);
                }
                o.flags |= O.flag_spotted_player;
            }
            objectives.attack(self, p.id, target);
            return true;
        }

        // ------------------------------------------------------------------
        // Flee handlers (3.5). Each returns the objective's progress.

        pub const Progress = enum { running, passed, failed };

        fn safeGround(self: *Self, t: *const c.Transform) bool {
            const cell = map.floorCell(self.grid, t.x, t.y, t.z, T.ped_step);
            return map.groundOf(cell) != map.Ground.road;
        }

        fn farAndSafe(self: *Self, p: P, sx: Fx, sy: Fx) bool {
            return fx.length(p.t.x - sx, p.t.y - sy) > A.flee_safe and safeGround(self, p.t);
        }

        /// Flee a ped until safe, or flee one always (`always`).
        pub fn fleePed(self: *Self, p: P, target: EntityId, sx: Fx, sy: Fx, always: bool) Progress {
            p.o.flags &= ~O.flag_attacking;
            if (!eligible(self, target)) return .passed;
            if (!always and farAndSafe(self, p, sx, sy)) return .passed;
            const at = posOf(self, target) orelse return .passed;
            move.runFrom(self, p, at.x, at.y);
            return .running;
        }

        /// Flee from a point until 6 blocks away on safe ground.
        pub fn fleePoint(self: *Self, p: P, sx: Fx, sy: Fx) Progress {
            p.o.flags &= ~O.flag_attacking;
            if (farAndSafe(self, p, sx, sy)) return .passed;
            if (p.t.x == sx and p.t.y == sy) {
                move.goToward(self, p, sx + fx.cos(p.t.heading), sy + fx.sin(p.t.heading), 127, true);
                return .running;
            }
            move.runFrom(self, p, sx, sy);
            return .running;
        }
    };
}
