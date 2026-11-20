//! Tests: gangs and respect (gangs-and-respect.md), in a small
//! single-player configuration. Workstream D2.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const Button = h_.Button;
const Frame = h_.Frame;
const testmap = h_.testmap;
const EntityId = abi.EntityId;
const blk = h_.blk;
const eql = h_.eql;
const ids = simmod.ids;
const gangs_mod = @import("../sp/gangs.zig");

/// Single player, no ambient population.
const cfg_sp_small: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 8, .ped_capacity = 16, .projectile_capacity = 16, .pickup_capacity = 4, .map_object_capacity = 4 };
const Sp = simmod.Sim(cfg_sp_small);
const G = Sp.gangs;

const zones = [_]simmod.level.Zone{
    .{ .kind = .gang, .x = 40, .y = 40, .w = 8, .h = 8, .name = "zaibatsu" },
    .{ .kind = .gang, .x = 60, .y = 30, .w = 8, .h = 8, .name = "loonies" },
};
const level: simmod.Level = .{ .zones = &zones };

const H = struct {
    grid: *map.Grid,
    sim: *Sp,
    frames: [1]Frame = .{Frame.neutral(0)},

    fn init() !H {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(Sp);
        s.init(g, .{ .seed = 11, .mode = .authoritative });
        s.attachLevel(&level);
        var h: H = .{ .grid = g, .sim = s };
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(60, 31) }});
        h.sim.state.world.get(h.me(), c.Group).?.gang = ids.gang_none;
        // Three gangs: killing a Zaibatsu pleases the Loonies (+2) and
        // annoys the Rednecks (-1).
        G.defineGang(s, 0, .{ .name = "zaibatsu", .kill_change = 1, .basic = 1, .angry = 2, .hate = 3, .car_model = 1 });
        G.defineGang(s, 1, .{ .name = "loonies", .kill_change = 2, .basic = 4, .angry = 5, .hate = 6, .car_model = 2 });
        G.defineGang(s, 2, .{ .name = "rednecks", .kill_change = 1, .basic = 7, .angry = 8, .hate = 9 });
        G.setKillReaction(s, 0, 1, 2);
        G.setKillReaction(s, 0, 2, -1);
        return h;
    }
    fn deinit(h: *H) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    fn run(h: *H, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
    fn me(h: *H) EntityId {
        return h.sim.pedOf(0).?;
    }
    fn r(h: *H, g: u8) i32 {
        return G.respect(h.sim, g);
    }
    fn member(h: *H, g: u8) EntityId {
        const id = h.sim.spawnPed(c.Controller.no_player, 0).?;
        h.sim.state.world.applyPending();
        h.sim.state.world.get(id, c.Group).?.* = .{ .gang = g };
        return id;
    }
    /// Ped `id` dies, last hit by `by`, through the health system.
    fn die(h: *H, id: EntityId, by: EntityId) void {
        const hp = h.sim.state.world.get(id, c.Health).?;
        hp.hp = 0;
        hp.last_hit_by = by;
        h.run(1);
    }
};

test "respect: arithmetic holds to -100..100 whatever the sizes" {
    try std.testing.expectEqual(@as(i8, 100), gangs_mod.clampAdd(90, 50));
    try std.testing.expectEqual(@as(i8, -100), gangs_mod.clampAdd(-90, -50));
    try std.testing.expectEqual(@as(i8, 100), gangs_mod.clampAdd(100, std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(i8, -100), gangs_mod.clampAdd(-100, std.math.minInt(i32)));
    try std.testing.expectEqual(@as(i8, 7), gangs_mod.clampAdd(2, 5));
}

test "respect: a weapon kill is -5 x kill change, rivals +5 x their reaction" {
    var h = try H.init();
    defer h.deinit();
    h.die(h.member(0), h.me());
    try std.testing.expectEqual(@as(i32, -5), h.r(0));
    try std.testing.expectEqual(@as(i32, 10), h.r(1));
    try std.testing.expectEqual(@as(i32, -5), h.r(2));
    // A Loonie (kill change 2, no reactions): -10, nobody else moves.
    h.die(h.member(1), h.me());
    try std.testing.expectEqual(@as(i32, 0), h.r(1));
    try std.testing.expectEqual(@as(i32, -5), h.r(0));
}

test "respect: running over weighs 1, not 5; kills not by the player count for nothing" {
    var h = try H.init();
    defer h.deinit();
    const car = h.sim.spawnCarAt(blk(62), blk(33), 0, 0).?;
    h.sim.board(h.me(), car);
    h.die(h.member(0), car);
    try std.testing.expectEqual(@as(i32, -1), h.r(0));
    try std.testing.expectEqual(@as(i32, 2), h.r(1));
    try std.testing.expectEqual(@as(i32, -1), h.r(2));
    // Another ped's kill, or nobody's.
    const other = h.member(2);
    h.die(h.member(0), other);
    h.die(h.member(0), EntityId.none);
    try std.testing.expectEqual(@as(i32, -1), h.r(0));
}

test "respect: a gang that ignores kills, and the 100 cap" {
    var h = try H.init();
    defer h.deinit();
    G.setKillsCount(h.sim, 0, false);
    h.die(h.member(0), h.me());
    try std.testing.expectEqual(@as(i32, 0), h.r(0));
    try std.testing.expectEqual(@as(i32, 0), h.r(1));
    G.setKillsCount(h.sim, 0, true);
    for (0..12) |_| h.die(h.member(0), h.me());
    try std.testing.expectEqual(@as(i32, -60), h.r(0));
    try std.testing.expectEqual(@as(i32, 100), h.r(1)); // capped
    try std.testing.expectEqual(@as(i32, -60), h.r(2));
    try std.testing.expect(G.isHighRespect(h.sim, 1));
}

test "respect: hijacking or destroying a gang car is a 1-point kill" {
    var h = try H.init();
    defer h.deinit();
    // A Zaibatsu car (model 1) with a driver: carjacked.
    const car = h.sim.spawnCarAt(blk(62), blk(33), 0, 1).?;
    const d = h.member(0);
    h.sim.board(d, car);
    const dp = h.sim.state.world.get(d, c.Pedestrian).?;
    dp.car_phase = 0;
    h.sim.transformOf(h.me()).?.* = .{ .x = blk(62), .y = blk(31), .z = h.sim.transformOf(h.me()).?.z, .heading = 16384 };
    h.sim.startEnter(h.me(), car);
    for (0..300) |_| {
        h.run(1);
        if (eql(h.sim.state.world.get(h.me(), c.Riding).?.vehicle, car)) break;
    }
    try std.testing.expect(eql(h.sim.state.world.get(h.me(), c.Riding).?.vehicle, car));
    try std.testing.expectEqual(@as(i32, -1), h.r(0));
    try std.testing.expectEqual(@as(i32, 2), h.r(1));
    // A Loonie car (model 2) blown up by the player.
    const lc = h.sim.spawnCarAt(blk(80), blk(33), 0, 2).?;
    const lh = h.sim.state.world.get(lc, c.Health).?;
    lh.hp = 0;
    lh.last_hit_by = h.me();
    h.run(1);
    try std.testing.expectEqual(@as(i32, 0), h.r(1));
    // A car of no gang's model: nothing.
    const plain = h.sim.spawnCarAt(blk(95), blk(33), 0, 0).?;
    const ph = h.sim.state.world.get(plain, c.Health).?;
    ph.hp = 0;
    ph.last_hit_by = h.me();
    h.run(1);
    try std.testing.expectEqual(@as(i32, -1), h.r(0));
    try std.testing.expectEqual(@as(i32, -1), h.r(2));
}

test "respect: mission steps move 20 each, rivals with a reaction the other way" {
    var h = try H.init();
    defer h.deinit();
    G.changeRespect(h.sim, 0, 2);
    try std.testing.expectEqual(@as(i32, 40), h.r(0));
    // Loonies and Rednecks both react to Zaibatsu kills: both drop.
    try std.testing.expectEqual(@as(i32, -40), h.r(1));
    try std.testing.expectEqual(@as(i32, -40), h.r(2));
    G.changeRespect(h.sim, 1, -1);
    try std.testing.expectEqual(@as(i32, -60), h.r(1));
    try std.testing.expectEqual(@as(i32, 40), h.r(0)); // no reactions on gang 1
    G.changeRespect(h.sim, 0, 10);
    try std.testing.expectEqual(@as(i32, 100), h.r(0));
    try std.testing.expectEqual(@as(i32, -100), h.r(1));
    // An undeclared gang: nothing.
    G.changeRespect(h.sim, 5, 1);
    try std.testing.expectEqual(@as(i32, 0), h.r(5));
}

test "weapon: basic above -60, angry down to -99, hate only at exactly -100" {
    var h = try H.init();
    defer h.deinit();
    const s = h.sim;
    const cases = [_]struct { r: i8, w: u8 }{
        .{ .r = 100, .w = 1 }, .{ .r = 0, .w = 1 },   .{ .r = -59, .w = 1 },
        .{ .r = -60, .w = 2 }, .{ .r = -99, .w = 2 }, .{ .r = -100, .w = 3 },
    };
    for (cases) |k| {
        G.setRespect(s, 0, k.r);
        try std.testing.expectEqual(k.w, G.weaponForPlayer(s, 0));
    }
    G.setAlwaysBasic(s, 0, true);
    try std.testing.expectEqual(@as(u8, 1), G.weaponForPlayer(s, 0));
}

test "areas: gang zones by name; the respect power-up is +20 with the local gang" {
    var h = try H.init();
    defer h.deinit();
    try std.testing.expectEqual(@as(u8, 0), G.gangOfArea(h.sim, 41, 47));
    try std.testing.expectEqual(@as(u8, 1), G.gangOfArea(h.sim, 61, 31));
    try std.testing.expectEqual(ids.gang_none, G.gangOfArea(h.sim, 10, 10));
    G.respectPowerUp(h.sim, 0); // the player is at (60, 31): Loonies
    try std.testing.expectEqual(@as(i32, 20), h.r(1));
    try std.testing.expectEqual(@as(i32, 0), h.r(0));
}

test "gangs: deathmatch builds do nothing" {
    const S16 = simmod.Sim16;
    try std.testing.expect(!@hasField(S16.State, "sp"));
    try std.testing.expectEqual(ids.gang_none, S16.gangs.gangOfCarModel(undefined, 0));
}
