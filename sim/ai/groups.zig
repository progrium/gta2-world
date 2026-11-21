//! Groups: leaders and followers, formations, recruiting and group-wide
//! attacks (ped-ai.md 3.11, 3.12). Single player. Owner: workstream D2.
//!
//! A follower's `Group` names its leader and its slot (1-8); the leader's
//! own `Group.flags` holds the layout (`flag_chain`). Followers move by
//! the objectives API (D1): `follow` toward their formation target, and
//! `kill_ped` in a fight. `sysGroups` runs once a tick from
//! `gangs.sysGangs`, before `sysObjectives`.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");

/// Numbers from ped-ai.md 3.11-3.12.
/// A group holds at most 9 peds: the leader and 8 followers.
pub const max_followers: u8 = 8;
/// The instant-gang power-up asks for 4 recruits from a box about 4 blocks
/// out on each side.
pub const instant_gang_recruits: u8 = 4;
pub const recruit_box = fx.fromInt(4);
/// The tight-follow check: within 8 blocks of an on-foot leader.
pub const tight_follow = fx.fromInt(8);
/// Mid-fight, a follower more than 4 blocks from the leader goes back.
pub const fight_leash = fx.fromInt(4);
/// The leader counts as moving above this speed (ours).
pub const moving_speed = fx.ratio(1, 100);
/// Who each second-rank slot (4-8) trails in the normal layout: the note
/// says "specific front-rank followers" without naming them; ours, a
/// wedge with the outer slots on the flanks.
pub const wedge_parent = [_]u8{ 0, 0, 0, 0, 1, 1, 2, 3, 3 };
/// Ammo for a recruit's dual pistols (ours: unlimited).
pub const recruit_ammo = T.infinite_ammo;

/// Salt for picking a random extra target in a gang fight (D2 range).
const salt_fight_pick: u32 = ids.salts.gangs[0] + 0x10;

pub fn Sys(comptime Self: type) type {
    return struct {
        const Me = @This();
        const sp = Self.city;
        const World = Self.World;
        const Obj = Self.objectives;

        // ------------------------------------------------------------
        // Membership

        fn grp(self: *Self, id: EntityId) ?*c.Group {
            if (comptime !sp) return null;
            return self.state.world.get(id, c.Group);
        }

        pub fn leaderOf(self: *Self, ped: EntityId) EntityId {
            const g = grp(self, ped) orelse return .none;
            return g.leader;
        }

        /// The follower of `leader` in `slot`, or none.
        pub fn memberInSlot(self: *Self, leader: EntityId, slot: u8) EntityId {
            if (comptime !sp) return .none;
            var found: EntityId = .none;
            const Ctx = struct { found: *EntityId, leader: EntityId, slot: u8 };
            self.state.world.each(.{c.Group}, Ctx{ .found = &found, .leader = leader, .slot = slot }, struct {
                fn f(cx: Ctx, id: EntityId, g: *c.Group) void {
                    if (eql(g.leader, cx.leader) and g.slot == cx.slot) cx.found.* = id;
                }
            }.f);
            return found;
        }

        /// Followers `leader` has.
        pub fn size(self: *Self, leader: EntityId) u8 {
            if (comptime !sp) return 0;
            var n: u8 = 0;
            const Ctx = struct { n: *u8, leader: EntityId };
            self.state.world.each(.{c.Group}, Ctx{ .n = &n, .leader = leader }, struct {
                fn f(cx: Ctx, _: EntityId, g: *c.Group) void {
                    if (eql(g.leader, cx.leader)) cx.n.* += 1;
                }
            }.f);
            return n;
        }

        /// Add `ped` to `leader`'s group in the first free slot, leaving any
        /// group it was in. False when the group is full.
        pub fn join(self: *Self, ped: EntityId, leader: EntityId) bool {
            if (comptime !sp) return false;
            if (eql(ped, leader)) return false;
            const g = grp(self, ped) orelse return false;
            if (grp(self, leader) == null) return false;
            if (eql(g.leader, leader)) return true;
            var slot: u8 = 1;
            while (slot <= max_followers) : (slot += 1) {
                if (memberInSlot(self, leader, slot).isNone()) break;
            }
            if (slot > max_followers) return false;
            leave(self, ped);
            g.leader = leader;
            g.slot = slot;
            return true;
        }

        /// Take `ped` out of its group; its follow order goes too.
        pub fn leave(self: *Self, ped: EntityId) void {
            const g = grp(self, ped) orelse return;
            if (g.leader.isNone()) return;
            const o = Obj.objectiveOf(self, ped);
            if (o.kind == .follow) Obj.clearObjective(self, ped);
            g.leader = .none;
            g.slot = 0;
            g.flags &= ~c.Group.flag_fighting;
        }

        /// Dissolve `leader`'s group.
        pub fn disband(self: *Self, leader: EntityId) void {
            if (comptime !sp) return;
            var slot: u8 = 1;
            while (slot <= max_followers) : (slot += 1) {
                const m = memberInSlot(self, leader, slot);
                if (!m.isNone()) leave(self, m);
            }
        }

        pub fn setChain(self: *Self, leader: EntityId, on: bool) void {
            const g = grp(self, leader) orelse return;
            if (on) g.flags |= c.Group.flag_chain else g.flags &= ~c.Group.flag_chain;
        }

        // ------------------------------------------------------------
        // Formation (3.11)

        /// Whom follower `ped` trails now: the leader, or the follower ahead
        /// of it in the layout. A stationary leader pulls everyone to
        /// himself.
        pub fn formationTarget(self: *Self, ped: EntityId) EntityId {
            const g = grp(self, ped) orelse return .none;
            const leader = g.leader;
            if (leader.isNone()) return .none;
            const lg = grp(self, leader) orelse return leader;
            const w = &self.state.world;
            const lv = w.get(leader, c.Velocity) orelse return leader;
            if (Self.speedOf(lv) <= moving_speed) return leader;
            const parent: u8 = if (lg.flags & c.Group.flag_chain != 0)
                g.slot -| 1
            else if (g.slot < wedge_parent.len) wedge_parent[g.slot] else 0;
            if (parent == 0) return leader;
            const p = memberInSlot(self, leader, parent);
            return if (p.isNone()) leader else p;
        }

        fn onFoot(self: *Self, id: EntityId) bool {
            const r = self.state.world.get(id, c.Riding) orelse return false;
            return r.vehicle.isNone();
        }

        fn dist(self: *Self, a: EntityId, b: EntityId) Fx {
            const w = &self.state.world;
            const ta = w.get(a, c.Transform) orelse return std.math.maxInt(Fx);
            const tb = w.get(b, c.Transform) orelse return std.math.maxInt(Fx);
            return fx.length(ta.x - tb.x, ta.y - tb.y);
        }

        fn isFighting(self: *Self, id: EntityId) bool {
            if (comptime @hasDecl(Obj, "isAttacking")) return Obj.isAttacking(self, id);
            const k = Obj.objectiveOf(self, id).kind;
            return k == .kill_ped or k == .kill_car;
        }

        fn isPanicking(self: *Self, id: EntityId) bool {
            const k = Obj.objectiveOf(self, id).kind;
            return k == .flee_ped or k == .flee_till_safe;
        }

        /// Is the leader about to board a getaway car (3.12)?
        fn leaderBoarding(self: *Self, leader: EntityId) bool {
            return Self.enterPhase(self, leader) != .none;
        }

        fn orderFollow(self: *Self, ped: EntityId, target: EntityId) void {
            const o = Obj.objectiveOf(self, ped);
            if (o.kind == .follow and eql(o.target, target)) return;
            Obj.setObjective(self, ped, .{ .kind = .follow, .target = target });
        }

        fn orderAttack(self: *Self, ped: EntityId, target: EntityId) void {
            if (comptime @hasDecl(Obj, "attack")) return Obj.attack(self, ped, target);
            Obj.setObjective(self, ped, .{ .kind = .kill_ped, .target = target });
        }

        /// The tight-follow check and the mid-fight leash, every tick.
        pub fn sysGroups(self: *Self) void {
            if (comptime !sp) return;
            self.state.world.eachFiltered(.{c.Group}, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, g: *c.Group) void {
                    if (g.leader.isNone()) return;
                    const w = &sim.state.world;
                    if (!w.isAlive(g.leader)) {
                        g.leader = .none;
                        g.slot = 0;
                        g.flags &= ~c.Group.flag_fighting;
                        return;
                    }
                    if (!Me.onFoot(sim, id)) return;
                    const leader = g.leader;
                    const d = Me.dist(sim, id, leader);
                    if (g.flags & c.Group.flag_fighting != 0 and Me.isFighting(sim, id)) {
                        // Too far from the leader mid-fight: back to him,
                        // unless he is getting into a getaway car.
                        if (d > fight_leash and !Me.leaderBoarding(sim, leader)) {
                            g.flags &= ~c.Group.flag_fighting;
                            Me.orderFollow(sim, id, leader);
                        }
                        return;
                    }
                    g.flags &= ~c.Group.flag_fighting;
                    if (Me.isFighting(sim, id) or Me.isPanicking(sim, id)) return;
                    if (!Me.onFoot(sim, leader)) return;
                    if (d <= tight_follow) {
                        Me.orderFollow(sim, id, Me.formationTarget(sim, id));
                    } else if (Obj.objectiveOf(sim, id).kind == .follow) {
                        // Too far: free to fight or flee on its own.
                        Obj.clearObjective(sim, id);
                    }
                }
            }.f);
        }

        // ------------------------------------------------------------
        // Recruiting (3.11)

        /// Is `ped` one `leader` may recruit: a background ped (no player,
        /// on foot, on its feet, alive), or someone else's follower.
        fn eligible(self: *Self, leader: EntityId, ped: EntityId) bool {
            const w = &self.state.world;
            if (eql(ped, leader)) return false;
            const ctl = w.get(ped, c.Controller) orelse return false;
            if (ctl.player != c.Controller.no_player) return false;
            if (!onFoot(self, ped)) return false;
            const h = w.get(ped, c.Health) orelse return false;
            if (h.hp <= 0) return false;
            const p = w.get(ped, c.Pedestrian) orelse return false;
            if (p.state != c.Pedestrian.state_up or p.car_phase != 0) return false;
            const g = grp(self, ped) orelse return false;
            if (eql(g.leader, leader)) return false;
            if (!g.leader.isNone()) return true; // poached from another group
            // Only ordinary background peds: no gang members, no leaders,
            // nobody the script holds, no law.
            if (g.gang != ids.gang_none and g.flags & c.Group.flag_turf == 0) return false;
            if (size(self, ped) > 0) return false;
            if (w.get(ped, c.ScriptTag)) |tag| if (tag.handle != 0) return false;
            if (w.get(ped, c.Objective)) |o| {
                const occ: ids.Occupation = @enumFromInt(o.occupation);
                switch (occ) {
                    .civilian, .dummy, .customer => {},
                    else => return false,
                }
            }
            return true;
        }

        /// Recruit up to `n` peds near `leader` into its group (the
        /// instant-gang power-up asks for 4). Returns how many joined.
        pub fn recruit(self: *Self, leader: EntityId, n: u8) u8 {
            if (comptime !sp) return 0;
            if (grp(self, leader) == null) return 0;
            var got: u8 = 0;
            while (got < n) : (got += 1) {
                const ped = nearestEligible(self, leader) orelse break;
                if (!join(self, ped, leader)) break;
                makeRecruit(self, ped, leader);
            }
            return got;
        }

        fn nearestEligible(self: *Self, leader: EntityId) ?EntityId {
            const w = &self.state.world;
            const lt = w.get(leader, c.Transform) orelse return null;
            const Best = struct { id: EntityId = .none, d: Fx = std.math.maxInt(Fx) };
            var best: Best = .{};
            const Ctx = struct { sim: *Self, best: *Best, leader: EntityId, x: Fx, y: Fx };
            w.each(.{ c.Group, c.Transform }, Ctx{ .sim = self, .best = &best, .leader = leader, .x = lt.x, .y = lt.y }, struct {
                fn f(cx: Ctx, id: EntityId, _: *c.Group, t: *c.Transform) void {
                    const dx = t.x - cx.x;
                    const dy = t.y - cx.y;
                    if (fx.abs(dx) > recruit_box or fx.abs(dy) > recruit_box) return;
                    if (!Me.eligible(cx.sim, cx.leader, id)) return;
                    const d = fx.length(dx, dy);
                    if (d < cx.best.d) cx.best.* = .{ .id = id, .d = d };
                }
            }.f);
            return if (best.id.isNone()) null else best.id;
        }

        /// Reskinned like the recruiter, dual pistols, the recruiter's
        /// threat settings and gang, no jumping, the follower type (3.11).
        fn makeRecruit(self: *Self, ped: EntityId, leader: EntityId) void {
            const w = &self.state.world;
            if (w.get(leader, c.Appearance)) |la| {
                if (w.get(ped, c.Appearance)) |pa| pa.remap = la.remap;
            }
            if (w.get(ped, c.Weapon)) |wp| {
                wp.rounds()[T.weapon_dual_pistol] = recruit_ammo;
                wp.kind = T.weapon_dual_pistol;
            }
            const g = grp(self, ped).?;
            g.gang = grp(self, leader).?.gang;
            g.flags = (g.flags & ~c.Group.flag_turf) | c.Group.flag_follower | c.Group.flag_no_jump;
            if (comptime @hasDecl(Obj, "copyThreatSettings")) Obj.copyThreatSettings(self, ped, leader);
            orderFollow(self, ped, formationTarget(self, ped));
        }

        // ------------------------------------------------------------
        // Group attack (3.12)

        /// Send `leader`'s group after `target`. Against a lone target every
        /// eligible member attacks it; against a rival group members pair
        /// off one-for-one with the rival's calmest members, each told to
        /// fight back, extras taking a random rival; leaders not yet
        /// fighting take each other.
        pub fn attack(self: *Self, leader: EntityId, target: EntityId) void {
            if (comptime !sp) return;
            const w = &self.state.world;
            if (!w.isAlive(target)) return;
            const rival = rivalLeader(self, target);
            const boarding = leaderBoarding(self, leader);
            var slot: u8 = 1;
            var pick: u32 = 0;
            while (slot <= max_followers) : (slot += 1) {
                const m = memberInSlot(self, leader, slot);
                if (m.isNone() or !onFoot(self, m) or isPanicking(self, m)) continue;
                const mh = w.get(m, c.Health) orelse continue;
                if (mh.hp <= 0) continue;
                const g = grp(self, m).?;
                if (rival.isNone()) {
                    if (dist(self, m, leader) > fight_leash and !boarding) {
                        orderFollow(self, m, leader);
                        continue;
                    }
                    g.flags |= c.Group.flag_fighting;
                    orderAttack(self, m, target);
                    continue;
                }
                const foe = calmestOf(self, rival) orelse randomOf(self, rival, m, &pick);
                g.flags |= c.Group.flag_fighting;
                orderAttack(self, m, foe);
                if (!isFighting(self, foe)) {
                    if (grp(self, foe)) |fg| fg.flags |= c.Group.flag_fighting;
                    orderAttack(self, foe, m);
                }
            }
            if (!rival.isNone() and !isFighting(self, leader) and !isFighting(self, rival)) {
                orderAttack(self, leader, rival);
                orderAttack(self, rival, leader);
            }
        }

        /// The leader of `target`'s group (itself if it leads one), or none.
        fn rivalLeader(self: *Self, target: EntityId) EntityId {
            const g = grp(self, target) orelse return .none;
            if (!g.leader.isNone()) return g.leader;
            return if (size(self, target) > 0) target else .none;
        }

        /// A member of `leader`'s group not yet fighting, or null.
        fn calmestOf(self: *Self, leader: EntityId) ?EntityId {
            var slot: u8 = 1;
            while (slot <= max_followers) : (slot += 1) {
                const m = memberInSlot(self, leader, slot);
                if (m.isNone()) continue;
                if (!isFighting(self, m)) return m;
            }
            return null;
        }

        /// A random member of `leader`'s group, or the leader.
        fn randomOf(self: *Self, leader: EntityId, for_ped: EntityId, pick: *u32) EntityId {
            const n = size(self, leader);
            pick.* += 1;
            const k = self.randBelow(for_ped, salt_fight_pick +% pick.*, @as(u32, n) + 1);
            if (k == 0) return leader;
            var seen: u32 = 0;
            var slot: u8 = 1;
            while (slot <= max_followers) : (slot += 1) {
                const m = memberInSlot(self, leader, slot);
                if (m.isNone()) continue;
                seen += 1;
                if (seen == k) return m;
            }
            return leader;
        }
    };
}
