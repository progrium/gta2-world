//! Tests: the single-player configuration and the W0 interfaces (level,
//! surfaces, reserved ids, API stubs). Each API stub is called once so it
//! is compiled in both configurations.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const testmap = h_.testmap;
const Frame = h_.Frame;
const EntityId = abi.EntityId;

const Sp = simmod.Sim(simmod.config_sp);

fn exerciseApis(comptime S: type, s: *S) void {
    const none = EntityId.none;
    S.objectives.setObjective(s, none, .{ .kind = .go_to, .timeout = 10 });
    S.objectives.setInternalObjective(s, none, .{});
    S.objectives.clearObjective(s, none);
    _ = S.objectives.objectiveOf(s, none);
    _ = S.objectives.objectiveStatus(s, none);
    S.objectives.setOccupation(s, none, .mugger);
    S.car_tasks.setCarTask(s, none, .chase, none, 0, 0);
    _ = S.car_tasks.carTaskOf(s, none);
    _ = S.car_tasks.carArrived(s, none);
    _ = S.route.nextRoadDir(s, 0, 0, 1, 10, 10);
    S.career.addScore(s, 0, 100, .with_multiplier);
    _ = S.career.score(s, 0);
    _ = S.career.lives(s, 0);
    S.career.addLives(s, 0, 1);
    _ = S.career.multiplier(s, 0);
    S.career.setMultiplier(s, 0, 2);
    S.career.addJailCard(s, 0);
    _ = S.career.isOut(s, 0);
    S.career.bust(s, 0, none);
    S.career.givePowerUp(s, 0, 0, 30);
    S.wanted.addPoints(s, 0, 100);
    S.wanted.atLeastOneStar(s, 0);
    S.wanted.clear(s, 0);
    S.wanted.setCap(s, 0, 4);
    _ = S.wanted.stars(s, 0);
    S.wanted.reportCrime(s, .shot_fired, none, 0, 0, 0);
    _ = S.gangs.respect(s, 0);
    S.gangs.changeRespect(s, 0, 1);
    S.gangs.onKill(s, 0, none);
    _ = S.gangs.weaponForPlayer(s, 0);
    _ = S.gangs.gangOfArea(s, 0, 0);
    _ = S.objects.spawnObject(s, .phone, 0, 0, 0, 0, 0);
    S.objects.removeObject(s, none);
    S.objects.setDoor(s, none, .auto);
    S.objects.ringPhone(s, none, true);
    _ = S.objects.phoneAnswered(s, none);
    S.objects.setGenerator(s, none, true);
    S.objects.runCrusher(s, none);
    _ = S.lights.lightState(s, 0, 0, 0);
    S.hooks.phoneTouched(s, none, none);
    S.hooks.carEntered(s, none, none);
    S.hooks.entityHit(s, none, 0, none);
    S.hooks.carModelDestroyed(s, 0, none);
    S.hooks.areaEntered(s, none, 0, 0, 0);
    S.hud.postBanner(s, 0, 1, 60);
    S.hud.queueBrief(s, 0, 1);
    S.hud.setTimer(s, 0, 300);
    S.hud.setCounter(s, 0, 0, 5);
    S.hud.setArrow(s, 0, none, 0, 0);
}

test "sp: one player in a city with a level attached runs and stays deterministic" {
    try std.testing.expect(Sp.single_player);
    try std.testing.expect(!h_.S.single_player);
    try std.testing.expect(Sp.Ped.has(c.Objective) and Sp.Car.has(c.CarTask) and Sp.MapObject.has(c.Object));
    try std.testing.expect(!simmod.Sim16.Ped.has(c.Objective));
    try std.testing.expect(@hasField(Sp.State, "sp") and !@hasField(simmod.Sim16.State, "sp"));

    const gpa = std.testing.allocator;
    const g = try gpa.create(map.Grid);
    defer gpa.destroy(g);
    testmap.build(g);
    const zones = [_]simmod.level.Zone{.{ .kind = .restart, .x = 40, .y = 40, .w = 4, .h = 4, .name = "r1" }};
    const lvl: simmod.Level = .{ .zones = &zones };

    var a = try gpa.create(Sp);
    defer gpa.destroy(a);
    var b = try gpa.create(Sp);
    defer gpa.destroy(b);
    a.init(g, .{ .seed = 3, .mode = .authoritative });
    b.init(g, .{ .seed = 3, .mode = .authoritative });
    try std.testing.expect(a.level == null);
    a.attachLevel(&lvl);
    b.attachLevel(&lvl);
    try std.testing.expect(a.level.?.zoneAt(.restart, 41, 42) != null);
    const join = [_]abi.Command{.{ .op = .join, .slot = 0, .arg = 0 }};
    var frames = [_]Frame{Frame.neutral(0)};
    a.step(&frames, &join);
    b.step(&frames, &join);
    for (0..300) |i| {
        frames[0].throttle = if (i % 50 < 30) 127 else 0;
        a.step(&frames, &.{});
        b.step(&frames, &.{});
    }
    try std.testing.expectEqual(a.hash(), b.hash());
    try std.testing.expect(a.pedOf(0) != null);
    // The APIs that are no longer stubs change the state (E: wanted), so
    // both sims take the same calls and must still agree.
    exerciseApis(Sp, a);
    exerciseApis(Sp, b);
    try std.testing.expectEqual(a.hash(), b.hash());
}

test "sp: the API stubs compile and do nothing in dm16 too" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    const before = h.sim.hash();
    exerciseApis(h_.S, h.sim);
    try std.testing.expectEqual(before, h.sim.hash());
}

test "surface bits: red arrows and electrified read back; an empty table keeps the grid hash" {
    const gpa = std.testing.allocator;
    const g = try gpa.create(map.Grid);
    defer gpa.destroy(g);
    testmap.build(g);
    const h0 = map.gridHash(g);
    g.surface[1][40][40] = map.Surface.red_pos_x | map.Surface.electrified;
    try std.testing.expectEqual(map.Arrow.pos_x, map.redArrowsOf(map.surfaceAt(g, 40, 40, 1)));
    try std.testing.expect(map.surfaceAt(g, 40, 40, 1) & map.Surface.electrified != 0);
    try std.testing.expectEqual(@as(u8, 0), map.surfaceAt(g, -1, 0, 0));
    try std.testing.expect(map.gridHash(g) != h0);
    g.surface[1][40][40] = 0;
    try std.testing.expectEqual(h0, map.gridHash(g));
}

test "reserved numbers line up with the wire and the abi" {
    const wire = @import("interfaces").wire;
    const E = h_.S.Event.Kind;
    const info = @typeInfo(E).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        try std.testing.expectEqual(value, @intFromEnum(@field(wire.EventKind, name)));
    }
    try std.testing.expectEqual(@as(u8, 14), @backingInt(c.Objective.id));
    try std.testing.expectEqual(@as(u8, 13), @backingInt(c.Object.id));
    try std.testing.expectEqual(@as(u16, 4), simmod.anim.frameAt(9, 2));
}
