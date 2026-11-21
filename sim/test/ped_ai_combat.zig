//! Ped AI (D1): fighting. Range keeping (3.7), police fire rationing
//! (3.8), test shots (weapons.md 3.8), the mugger (3.9), and a soak.

const std = @import("std");
const u = @import("ped_ai_util.zig");
const fx = u.fx;
const c = u.c;
const T = u.T;
const map = u.map;
const Obj = u.Obj;
const ids = u.ids;
const blk = u.blk;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn still(wd: *u.World, x: u8, y: u8) u.EntityId {
    const id = wd.ped(x, y, .dummy);
    Obj.setObjective(wd.sim, id, .{ .kind = .wait });
    Obj.setThreatReaction(wd.sim, id, .fight);
    return id;
}

test "ped ai: a flamethrower backs off inside 1 block; a shotgun closes inside 1" {
    var wd = try u.World.init();
    defer wd.deinit();
    const target = still(&wd, 12, 10);
    const a = wd.ped(12, 10, .criminal);
    wd.t(a).x = wd.t(target).x - fx.ratio(1, 2);
    Obj.armPed(wd.sim, a, T.weapon_flamethrower);
    Obj.setObjective(wd.sim, a, .{ .kind = .kill_ped, .target = target });
    wd.run(15);
    try expect(wd.dist(a, target) >= fx.one - fx.ratio(1, 10));

    var wd2 = try u.World.init();
    defer wd2.deinit();
    const t2 = still(&wd2, 14, 10);
    const b = wd2.ped(11, 10, .criminal);
    Obj.armPed(wd2.sim, b, T.weapon_shotgun);
    Obj.setObjective(wd2.sim, b, .{ .kind = .kill_ped, .target = t2 });
    var n: u32 = 0;
    while (n < 100 and wd2.dist(b, t2) > fx.ratio(1, 2) + fx.ratio(1, 20)) : (n += 1) wd2.run(1);
    try expect(wd2.dist(b, t2) <= fx.ratio(11, 20));
}

test "ped ai: a pistol shooter fires from up to 5 blocks while closing, and stops closing at 4" {
    var wd = try u.World.init();
    defer wd.deinit();
    const target = still(&wd, 20, 10);
    const a = wd.ped(10, 10, .criminal);
    Obj.armPed(wd.sim, a, T.weapon_pistol);
    Obj.setObjective(wd.sim, a, .{ .kind = .kill_ped, .target = target });
    var n: u32 = 0;
    while (n < 400 and wd.sim.state.world.count(u.S.Shot) == 0) : (n += 1) wd.run(1);
    try expect(wd.sim.state.world.count(u.S.Shot) > 0);
    const d = wd.dist(a, target);
    try expect(d <= fx.fromInt(5) and d > fx.fromInt(4));
    // Make the target bulletproof so it neither moves nor reacts.
    wd.sim.state.world.get(target, c.Pedestrian).?.invulnerable = 5000;
    wd.run(60);
    const d2 = wd.dist(a, target);
    try expect(d2 <= fx.fromInt(4) + fx.ratio(1, 16) and d2 > fx.fromInt(3));
}

fn shooting(wd: *u.World, id: u.EntityId) bool {
    return wd.sim.state.world.get(id, c.Controller).?.in.buttons & u.Button.fire != 0;
}

test "ped ai: police hold fire alone, and take turns once two are on screen" {
    var wd = try u.World.init();
    defer wd.deinit();
    const pl = wd.player(10, 10);
    const cop1 = wd.ped(13, 10, .police);
    Obj.armPed(wd.sim, cop1, T.weapon_pistol);
    Obj.setObjective(wd.sim, cop1, .{ .kind = .kill_ped, .target = pl });
    var fired = false;
    for (0..60) |_| {
        wd.run(1);
        fired = fired or shooting(&wd, cop1);
        // Keep the player standing in place for a clean count.
        wd.place(pl, 10, 10);
    }
    try expect(!fired);
    const cop2 = wd.ped(10, 13, .police);
    Obj.armPed(wd.sim, cop2, T.weapon_pistol);
    Obj.setObjective(wd.sim, cop2, .{ .kind = .kill_ped, .target = pl });
    var any = false;
    for (0..120) |_| {
        wd.run(1);
        wd.place(pl, 10, 10);
        wd.sim.state.world.get(pl, c.Health).?.hp = T.ped_hp;
        const a = shooting(&wd, cop1);
        const b = shooting(&wd, cop2);
        try expect(!(a and b));
        any = any or a or b;
    }
    try expect(any);
}

test "ped ai: a shot that hits a bystander switches the shooter to test shots until the line is clear" {
    var wd = try u.World.init();
    defer wd.deinit();
    const target = still(&wd, 14, 10);
    const a = wd.ped(11, 10, .criminal);
    Obj.armPed(wd.sim, a, T.weapon_pistol);
    Obj.setAccurate(wd.sim, a, true);
    const by = still(&wd, 12, 10);
    Obj.setThreatReaction(wd.sim, by, .flee);
    Obj.setObjective(wd.sim, a, .{ .kind = .kill_ped, .target = target });
    var n: u32 = 0;
    while (n < 200 and wd.hp(by) == T.ped_hp) : (n += 1) wd.run(1);
    try expect(wd.hp(by) < T.ped_hp);
    wd.run(2);
    try expect(wd.o(a).flags & c.Objective.flag_test_shots != 0);
    const shots = wd.sim.scratch.stats.shots;
    // The bystander walks off: a test passes and real fire resumes.
    wd.place(by, 12, 20);
    n = 0;
    while (n < 200 and wd.o(a).flags & c.Objective.flag_test_shots != 0) : (n += 1) wd.run(1);
    try expect(wd.o(a).flags & c.Objective.flag_test_shots == 0);
    wd.run(60);
    try expect(wd.sim.scratch.stats.shots > shots);
}

test "ped ai: a mugger punches the player for no damage, counts a mug, and retires after ten" {
    var wd = try u.World.init();
    defer wd.deinit();
    const pl = wd.player(10, 10);
    const m = wd.ped(12, 10, .mugger);
    var n: u32 = 0;
    while (n < 300 and wd.o(m).mugs == 0) : (n += 1) {
        wd.run(1);
        wd.place(pl, 10, 10);
    }
    try expectEqual(@as(u8, 1), wd.o(m).mugs);
    try expectEqual(T.ped_hp, wd.hp(pl));
    wd.o(m).mugs = 9;
    wd.o(m).think = 0;
    n = 0;
    while (n < 300 and wd.o(m).mugs == 9) : (n += 1) {
        wd.run(1);
        wd.place(pl, 10, 10);
    }
    try expectEqual(@as(u8, 10), wd.o(m).mugs);
    try expectEqual(ids.Occupation.civilian, Obj.occupationOf(wd.sim, m));
}

const soak_cfg: u.abi.Config = .{ .name = "sp_soak", .max_players = 1, .car_capacity = 16, .ped_capacity = 256, .projectile_capacity = 256, .pickup_capacity = 4, .map_object_capacity = 4 };
const Soak = u.simmod.Sim(soak_cfg);

fn soakRun(g: *map.Grid, seed: u64) !struct { hash: u64, sim: *Soak } {
    const s = try std.testing.allocator.create(Soak);
    s.init(g, .{ .seed = seed, .mode = .authoritative });
    var frames = [_]u.Frame{u.Frame.neutral(0)};
    s.step(&frames, &.{.{ .op = .join, .slot = 0, .arg = u.simmod.spawnHint(70, 70) }});
    const occs = [_]ids.Occupation{ .civilian, .civilian, .civilian, .mugger, .gang_member, .gang_member, .police, .criminal };
    var i: u32 = 0;
    var placed: u32 = 0;
    while (placed < 200 and i < 2000) : (i += 1) {
        const bx: u8 = @intCast(38 + (i * 7) % 60);
        const by: u8 = @intCast(38 + (i * 13) % 60);
        const id = s.spawnPed(c.Controller.no_player, u.simmod.spawnHint(bx, by)) orelse continue;
        s.state.world.applyPending();
        const occ = occs[placed % occs.len];
        Soak.objectives.setOccupation(s, id, occ);
        if (occ == .gang_member) s.state.world.get(id, c.Group).?.gang = @intCast(placed % 3);
        if (placed % 3 == 0) Soak.objectives.armPed(s, id, @intCast(placed % 10));
        placed += 1;
    }
    try expect(placed >= 150);
    // The player wanders the middle with a gun.
    const w = s.state.world.get(s.pedOf(0).?, c.Weapon).?;
    w.kind = T.weapon_pistol;
    // A single-player career starts unarmed (G), so hand him the pistol.
    w.rounds()[T.weapon_pistol] = T.infinite_ammo;
    for (0..3000) |k| {
        frames[0] = .{ .steer = 0, .throttle = if (k % 200 < 120) 127 else 0, .buttons = u.Button.direct | (if (k % 50 < 5) u.Button.fire else 0), .aim = @truncate(k * 97), .seq = 0 };
        s.step(&frames, &.{});
    }
    return .{ .hash = s.hash(), .sim = s };
}

test "ped ai soak: 200 armed and unarmed peds for 3000 ticks: none in a wall, every reaction ends, deterministic" {
    const gpa = std.testing.allocator;
    const g = try gpa.create(map.Grid);
    defer gpa.destroy(g);
    u.testmap.build(g);
    const a = try soakRun(g, 5);
    defer gpa.destroy(a.sim);
    const b = try soakRun(g, 5);
    defer gpa.destroy(b.sim);
    try expectEqual(a.hash, b.hash);
    const s = a.sim;
    const tb = s.state.world.table(Soak.Ped);
    var i: u32 = 0;
    var alive: u32 = 0;
    while (i < tb.len) : (i += 1) {
        if (tb.slot[i] != u.simmod.ecs.Slot.alive) continue;
        if (!tb.col(c.Riding)[i].vehicle.isNone()) continue;
        alive += 1;
        const t = tb.col(c.Transform)[i];
        try expect(!s.circleBlocked(t.x, t.y, t.z, T.ped_radius - fx.ratio(1, 50), T.ped_step));
        const o = tb.col(c.Objective)[i];
        // Every internal objective has a timeout, so none can hang.
        if (o.internal != 0) try expect(o.internal_timeout > 0);
    }
    try expect(alive > 50);
}
