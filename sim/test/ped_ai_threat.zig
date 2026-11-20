//! Ped AI (D1): the threat rule as a table (ped-ai.md 3.3), the search,
//! reacting to being hit (3.6) and the passive panic (3.5).

const std = @import("std");
const u = @import("ped_ai_util.zig");
const fx = u.fx;
const c = u.c;
const T = u.T;
const Obj = u.Obj;
const ids = u.ids;
const blk = u.blk;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn setGang(wd: *u.World, id: u.EntityId, gang: u8) void {
    wd.sim.state.world.get(id, c.Group).?.gang = gang;
}

fn arm(wd: *u.World, id: u.EntityId) void {
    Obj.armPed(wd.sim, id, T.weapon_pistol);
}

test "ped ai threat rule: the table" {
    var wd = try u.World.init();
    defer wd.deinit();
    const pl = wd.player(10, 10);
    const civ = wd.ped(11, 10, .civilian);
    const civ2 = wd.ped(12, 10, .civilian);
    const cop = wd.ped(11, 11, .police);
    const mug = wd.ped(12, 11, .mugger);
    const g1 = wd.ped(13, 10, .gang_member);
    const g1b = wd.ped(13, 11, .gang_member);
    const g2 = wd.ped(14, 10, .gang_member);
    const crim = wd.ped(15, 10, .criminal);
    const crim2 = wd.ped(15, 11, .criminal);
    setGang(&wd, g1, 0);
    setGang(&wd, g1b, 0);
    setGang(&wd, g2, 1);
    const S = wd.sim;
    const isT = Obj.isThreat;

    // 7. Undecided: the player yes, an AI ped no.
    try expect(isT(S, civ, pl));
    try expect(!isT(S, civ, civ2));
    // 4. A mugger: everyone.
    try expect(isT(S, mug, civ) and isT(S, mug, pl));
    // 5. Gangs: same gang no, rival yes, the player yes by default
    // (respect 0 is not negative, so only by the fallback? no: rule 5 says
    // a non-attacking player is a threat only on negative respect).
    try expect(!isT(S, g1, g1b));
    try expect(isT(S, g1, g2));
    try expect(!isT(S, g1, pl));
    try expect(!isT(S, g1, civ));
    // 6. Same background criminal occupation: never.
    try expect(!isT(S, crim, crim2));
    // Law: an unarmed, unwanted, peaceful player is ignored; armed is not;
    // mid-jump hides him.
    try expect(!isT(S, cop, pl));
    arm(&wd, pl);
    try expect(isT(S, cop, pl));
    wd.sim.state.world.get(pl, c.Pedestrian).?.jump = 4;
    try expect(!isT(S, cop, pl));
    wd.sim.state.world.get(pl, c.Pedestrian).?.jump = 0;
    // Law against AI: only someone attacking.
    try expect(!isT(S, cop, civ));
    Obj.attack(S, civ, civ2);
    try expect(isT(S, cop, civ));
    Obj.clearInternal(S, civ);
    // 1. Invisible on foot: never, to anyone.
    Obj.setInvisible(S, pl, true);
    try expect(!isT(S, cop, pl) and !isT(S, mug, pl) and !isT(S, civ, pl));
    Obj.setInvisible(S, pl, false);
    // 3. Same follower group: never.
    wd.sim.state.world.get(civ2, c.Group).?.leader = mug;
    try expect(!isT(S, mug, civ2));
    wd.sim.state.world.get(civ2, c.Group).?.leader = .none;
    // 2. Player-only search ignores everyone else.
    Obj.setThreatSearch(S, mug, .player_wide);
    try expect(!isT(S, mug, civ));
    try expect(isT(S, mug, pl));
}

test "ped ai threat rule: the crowd cap on a rival target" {
    var wd = try u.World.init();
    defer wd.deinit();
    const victim = wd.ped(10, 10, .gang_member);
    setGang(&wd, victim, 1);
    const asker = wd.ped(12, 10, .civilian);
    setGang(&wd, asker, 0); // a scripted gang member that is not a plain one
    try expect(Obj.isThreat(wd.sim, asker, victim));
    wd.o(victim).attackers_ever = 4;
    try expect(!Obj.isThreat(wd.sim, asker, victim));
    // A plain gang member ignores the cap.
    Obj.setOccupation(wd.sim, asker, .gang_member);
    try expect(Obj.isThreat(wd.sim, asker, victim));
}

test "ped ai: a police ped finds an armed player in sight and attacks" {
    var wd = try u.World.init();
    defer wd.deinit();
    const pl = wd.player(10, 10);
    const cop = wd.ped(13, 10, .police);
    Obj.armPed(wd.sim, cop, T.weapon_pistol);
    wd.run(10);
    try expectEqual(u.Kind.none, Obj.internalOf(wd.sim, cop).kind);
    arm(&wd, pl);
    wd.run(10);
    const io = Obj.internalOf(wd.sim, cop);
    try expectEqual(u.Kind.kill_ped, io.kind);
    try expect(u.eql(io.target, pl));
    try expect(Obj.hasSpottedPlayer(wd.sim, cop));
}

test "ped ai: hit a fighter and it fights back; hit a fleer and it runs" {
    var wd = try u.World.init();
    defer wd.deinit();
    const pl = wd.player(10, 10);
    const f = wd.ped(12, 10, .civilian);
    Obj.setThreatReaction(wd.sim, f, .fight);
    const r = wd.ped(10, 12, .civilian);
    Obj.setThreatReaction(wd.sim, r, .flee);
    wd.run(1);
    wd.sim.hurt(f, 10, pl);
    wd.sim.hurt(r, 10, pl);
    wd.run(1);
    try expectEqual(u.Kind.kill_ped, Obj.internalOf(wd.sim, f).kind);
    try expect(u.eql(Obj.internalOf(wd.sim, f).target, pl));
    try expectEqual(u.Kind.flee_ped, Obj.internalOf(wd.sim, r).kind);
    // A paramedic never retaliates; a same-gang hit is forgiven.
    const med = wd.ped(14, 14, .emergency);
    Obj.setThreatReaction(wd.sim, med, .fight);
    const g = wd.ped(16, 14, .gang_member);
    const g2 = wd.ped(17, 14, .gang_member);
    setGang(&wd, g, 2);
    setGang(&wd, g2, 2);
    wd.run(1);
    wd.sim.hurt(med, 10, pl);
    wd.sim.hurt(g, 10, g2);
    wd.run(1);
    try expectEqual(u.Kind.none, Obj.internalOf(wd.sim, med).kind);
    try expect(!u.eql(Obj.internalOf(wd.sim, g).target, g2));
}

test "ped ai: a civilian panics and flees an armed player within 4 blocks" {
    var wd = try u.World.init();
    defer wd.deinit();
    const pl = wd.player(10, 10);
    const civ = wd.ped(13, 10, .civilian);
    Obj.setThreatReaction(wd.sim, civ, .flee);
    wd.run(5);
    try expectEqual(u.Kind.none, Obj.internalOf(wd.sim, civ).kind);
    arm(&wd, pl);
    wd.run(2);
    try expectEqual(u.Kind.flee_ped, Obj.internalOf(wd.sim, civ).kind);
    wd.run(100);
    try expect(wd.dist(civ, pl) > fx.fromInt(5));
    // Too far: no panic.
    const far = wd.ped(28, 28, .civilian);
    Obj.setThreatReaction(wd.sim, far, .flee);
    wd.run(5);
    try expectEqual(u.Kind.none, Obj.internalOf(wd.sim, far).kind);
}

test "ped ai: invisibility stops new threats and calls off a chase" {
    var wd = try u.World.init();
    defer wd.deinit();
    const pl = wd.player(10, 10);
    arm(&wd, pl);
    const g = wd.ped(13, 10, .mugger);
    wd.run(10);
    try expectEqual(u.Kind.punch_ped, Obj.internalOf(wd.sim, g).kind);
    Obj.setInvisible(wd.sim, pl, true);
    wd.run(2);
    try expectEqual(u.Kind.none, Obj.internalOf(wd.sim, g).kind);
    wd.run(30);
    try expectEqual(u.Kind.none, Obj.internalOf(wd.sim, g).kind);
}

test "ped ai: electro-fingers shocks everyone within half a block for 3 a tick" {
    var wd = try u.World.init();
    defer wd.deinit();
    const pl = wd.player(10, 10);
    const near = wd.ped(10, 10, .dummy);
    Obj.setObjective(wd.sim, near, .{ .kind = .wait });
    wd.t(near).x = wd.t(pl).x + fx.ratio(3, 10);
    wd.t(near).y = wd.t(pl).y;
    const far = wd.ped(12, 10, .dummy);
    Obj.setObjective(wd.sim, far, .{ .kind = .wait });
    Obj.setElectroFingers(wd.sim, pl, true);
    wd.run(1);
    try expect(wd.hp(near) < T.ped_hp);
    try expectEqual(T.ped_hp, wd.hp(far));
    try expectEqual(T.ped_hp, wd.hp(pl));
    const credited = wd.sim.state.world.get(near, c.Health).?.last_hit_by;
    try expect(u.eql(credited, pl));
}
