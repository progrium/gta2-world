//! Ped AI (D1): one scenario per objective handler: set it, step, check
//! the outcome, and check the timeout fails it (ped-ai.md 3.1-3.10).

const std = @import("std");
const u = @import("ped_ai_util.zig");
const fx = u.fx;
const c = u.c;
const T = u.T;
const Obj = u.Obj;
const blk = u.blk;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "ped ai: go_to walks to the point and passes; a timeout fails it" {
    var wd = try u.World.init();
    defer wd.deinit();
    const a = wd.ped(10, 10, .dummy);
    Obj.setObjective(wd.sim, a, .{ .kind = .go_to, .x = blk(14), .y = blk(12) });
    try expectEqual(u.Status.active, Obj.objectiveStatus(wd.sim, a));
    wd.run(200);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));
    try expect(fx.length(wd.t(a).x - blk(14), wd.t(a).y - blk(12)) <= fx.ratio(1, 4));
    // Standing at the point once there.
    const x = wd.t(a).x;
    wd.run(20);
    try expectEqual(x, wd.t(a).x);

    Obj.setObjective(wd.sim, a, .{ .kind = .go_to, .x = blk(28), .y = blk(28), .timeout = 20 });
    wd.run(19);
    try expectEqual(u.Status.active, Obj.objectiveStatus(wd.sim, a));
    wd.run(1);
    try expectEqual(u.Status.failed, Obj.objectiveStatus(wd.sim, a));
}

test "ped ai: wait stands still and passes when its time is up" {
    var wd = try u.World.init();
    defer wd.deinit();
    const a = wd.ped(10, 10, .dummy);
    Obj.setObjective(wd.sim, a, .{ .kind = .wait, .timeout = 30 });
    const x = wd.t(a).x;
    const y = wd.t(a).y;
    wd.run(29);
    try expectEqual(u.Status.active, Obj.objectiveStatus(wd.sim, a));
    try expect(wd.t(a).x == x and wd.t(a).y == y);
    wd.run(1);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));
}

test "ped ai: follow closes to 3/16 block, passes, and follows again when the leader moves" {
    var wd = try u.World.init();
    defer wd.deinit();
    const leader = wd.ped(14, 10, .dummy);
    Obj.setObjective(wd.sim, leader, .{ .kind = .wait });
    const a = wd.ped(10, 10, .dummy);
    Obj.setObjective(wd.sim, a, .{ .kind = .follow, .target = leader });
    wd.run(150);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));
    // Contact pushes keep them a body apart at most.
    try expect(wd.dist(a, leader) <= fx.ratio(4, 10));
    Obj.setObjective(wd.sim, leader, .{ .kind = .go_to, .x = blk(20), .y = blk(10) });
    wd.run(5);
    try expectEqual(u.Status.active, Obj.objectiveStatus(wd.sim, a));
    wd.run(200);
    try expect(wd.dist(a, leader) <= fx.ratio(4, 10));
    // The leader dies: the follow fails.
    wd.sim.state.world.get(leader, c.Health).?.hp = 0;
    wd.run(3);
    try expectEqual(u.Status.failed, Obj.objectiveStatus(wd.sim, a));
}

test "ped ai: kill_ped with a pistol shoots the target dead and passes" {
    var wd = try u.World.init();
    defer wd.deinit();
    const target = wd.ped(13, 10, .dummy);
    Obj.forceIdle(wd.sim, target);
    Obj.setThreatReaction(wd.sim, target, .flee);
    Obj.setObjective(wd.sim, target, .{ .kind = .wait });
    const a = wd.ped(10, 10, .criminal);
    Obj.armPed(wd.sim, a, T.weapon_pistol);
    Obj.setAccurate(wd.sim, a, true);
    Obj.setObjective(wd.sim, a, .{ .kind = .kill_ped, .target = target, .timeout = 2000 });
    var n: u32 = 0;
    while (n < 1500 and Obj.objectiveStatus(wd.sim, a) == .active) : (n += 1) wd.run(1);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));
    try expect(!wd.alive(target));
}

test "ped ai: kill_ped times out when the target cannot be reached" {
    var wd = try u.World.init();
    defer wd.deinit();
    const target = wd.ped(20, 10, .dummy);
    Obj.setObjective(wd.sim, target, .{ .kind = .wait });
    Obj.setInvisible(wd.sim, target, true);
    const a = wd.ped(10, 10, .criminal);
    Obj.setObjective(wd.sim, a, .{ .kind = .kill_ped, .target = target, .timeout = 50 });
    wd.run(5);
    // Invisible on foot: the chase is called off at once (3.15).
    try expectEqual(u.Status.failed, Obj.objectiveStatus(wd.sim, a));
    Obj.setInvisible(wd.sim, target, false);
    wd.place(target, 28, 28);
    Obj.setObjective(wd.sim, a, .{ .kind = .kill_ped, .target = target, .timeout = 50 });
    wd.run(50);
    try expectEqual(u.Status.failed, Obj.objectiveStatus(wd.sim, a));
}

test "ped ai: punch_ped closes in and lands 10 damage; below 20 health it knocks down" {
    var wd = try u.World.init();
    defer wd.deinit();
    const target = wd.ped(12, 10, .dummy);
    Obj.setObjective(wd.sim, target, .{ .kind = .wait });
    Obj.setThreatReaction(wd.sim, target, .fight);
    // Freeze the target's own reaction: it has no weapon and fights back
    // with fists, which is fine; we only look at the first punch.
    const a = wd.ped(10, 10, .criminal);
    Obj.setObjective(wd.sim, a, .{ .kind = .punch_ped, .target = target });
    var n: u32 = 0;
    while (n < 200 and wd.hp(target) == T.ped_hp) : (n += 1) wd.run(1);
    try expectEqual(T.ped_hp - 10, wd.hp(target));
    try expect(u.eql(Obj.lastPunched(wd.sim, a), target));
    // Below 20: knocked down, no damage.
    wd.sim.state.world.get(target, c.Health).?.hp = 15;
    wd.o(target).prev_hp = 15;
    n = 0;
    const ped = wd.sim.state.world.get(target, c.Pedestrian).?;
    while (n < 200 and ped.state == c.Pedestrian.state_up) : (n += 1) wd.run(1);
    try expectEqual(c.Pedestrian.state_down, ped.state);
    try expectEqual(@as(i32, 15), wd.hp(target));
}

test "ped ai: flee_ped runs until 6 blocks from the start on safe ground, then passes" {
    var wd = try u.World.init();
    defer wd.deinit();
    const danger = wd.ped(12, 16, .dummy);
    Obj.setObjective(wd.sim, danger, .{ .kind = .wait });
    const a = wd.ped(13, 16, .dummy);
    Obj.setObjective(wd.sim, a, .{ .kind = .flee_ped, .target = danger, .x = wd.t(a).x, .y = wd.t(a).y });
    wd.run(80);
    try expectEqual(u.Status.active, Obj.objectiveStatus(wd.sim, a));
    try expect(wd.t(a).x > wd.t(danger).x);
    var n: u32 = 0;
    while (n < 400 and Obj.objectiveStatus(wd.sim, a) == .active) : (n += 1) wd.run(1);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));
    try expect(wd.dist(a, danger) > fx.fromInt(6));
}

test "ped ai: flee_ped_always keeps running until the danger dies; flee_till_safe flees a point" {
    var wd = try u.World.init();
    defer wd.deinit();
    const danger = wd.ped(8, 16, .dummy);
    Obj.setObjective(wd.sim, danger, .{ .kind = .wait });
    const a = wd.ped(9, 16, .dummy);
    Obj.setObjective(wd.sim, a, .{ .kind = .flee_ped_always, .target = danger });
    wd.run(250);
    try expectEqual(u.Status.active, Obj.objectiveStatus(wd.sim, a));
    wd.sim.state.world.get(danger, c.Health).?.hp = 0;
    wd.run(2);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));

    const b = wd.ped(10, 20, .dummy);
    Obj.setObjective(wd.sim, b, .{ .kind = .flee_till_safe, .x = blk(9), .y = blk(20) });
    var n: u32 = 0;
    while (n < 400 and Obj.objectiveStatus(wd.sim, b) == .active) : (n += 1) wd.run(1);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, b));
    try expect(fx.length(wd.t(b).x - blk(9), wd.t(b).y - blk(20)) > fx.fromInt(6));
}

test "ped ai: enter_car walks to an empty car and gets in; leave_car gets out" {
    var wd = try u.World.init();
    defer wd.deinit();
    const car = wd.sim.spawnCarAt(blk(16), blk(10), 0, 0).?;
    const a = wd.ped(10, 10, .dummy);
    Obj.setObjective(wd.sim, a, .{ .kind = .enter_car, .target = car, .timeout = 400 });
    var n: u32 = 0;
    while (n < 400 and Obj.objectiveStatus(wd.sim, a) == .active) : (n += 1) wd.run(1);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));
    try expect(u.eql(wd.sim.state.world.get(a, c.Riding).?.vehicle, car));
    Obj.setObjective(wd.sim, a, .{ .kind = .leave_car });
    wd.run(3);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));
    try expect(wd.sim.state.world.get(a, c.Riding).?.vehicle.isNone());
}

test "ped ai: flee_on_car_stop gets out of a still car and flees the danger always" {
    var wd = try u.World.init();
    defer wd.deinit();
    const car = wd.sim.spawnCarAt(blk(16), blk(10), 0, 0).?;
    const danger = wd.ped(14, 10, .dummy);
    Obj.setObjective(wd.sim, danger, .{ .kind = .wait });
    const a = wd.ped(16, 12, .dummy);
    wd.sim.board(a, car);
    Obj.setObjective(wd.sim, a, .{ .kind = .flee_on_car_stop, .target = danger });
    wd.run(3);
    try expect(wd.sim.state.world.get(a, c.Riding).?.vehicle.isNone());
    try expectEqual(u.Kind.flee_ped_always, Obj.objectiveOf(wd.sim, a).kind);
    wd.run(60);
    try expect(wd.dist(a, danger) > fx.fromInt(2));
}

test "ped ai: guard returns to its post; kill_car shoots a car to a wreck" {
    var wd = try u.World.init();
    defer wd.deinit();
    const g = wd.ped(10, 10, .dummy);
    Obj.setObjective(wd.sim, g, .{ .kind = .guard, .x = blk(13), .y = blk(10) });
    wd.run(100);
    try expect(fx.length(wd.t(g).x - blk(13), wd.t(g).y - blk(10)) <= fx.ratio(1, 4));

    const car = wd.sim.spawnCarAt(blk(20), blk(20), 0, 0).?;
    const a = wd.ped(17, 20, .criminal);
    Obj.armPed(wd.sim, a, T.weapon_rocket);
    Obj.setObjective(wd.sim, a, .{ .kind = .kill_car, .target = car, .timeout = 1000 });
    var n: u32 = 0;
    while (n < 1000 and Obj.objectiveStatus(wd.sim, a) == .active) : (n += 1) wd.run(1);
    try expectEqual(u.Status.passed, Obj.objectiveStatus(wd.sim, a));
}

test "ped ai: clearObjective hands the ped back to the wanderer" {
    var wd = try u.World.init();
    defer wd.deinit();
    const a = wd.ped(10, 10, .dummy);
    Obj.setObjective(wd.sim, a, .{ .kind = .wait });
    wd.run(2);
    try expect(wd.o(a).flags & c.Objective.flag_steered != 0);
    Obj.clearObjective(wd.sim, a);
    wd.run(2);
    try expect(wd.o(a).flags & c.Objective.flag_steered == 0);
    try expectEqual(u.Kind.none, Obj.objectiveOf(wd.sim, a).kind);
}
