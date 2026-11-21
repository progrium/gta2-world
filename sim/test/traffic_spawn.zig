//! Tests: spawning by zone (workstream F; script-declarations.md 2.5). The
//! spawning note is not written, so these check our own rules: the zone
//! lookup and that the population near the player follows the density of
//! the zone the player is in.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const testmap = h_.testmap;
const Frame = h_.Frame;
const EntityId = h_.EntityId;
const spawn = @import("../sys/spawn.zig");

const cfg: abi.Config = .{ .name = "sp_zone", .max_players = 1, .car_capacity = 64, .ped_capacity = 96, .projectile_capacity = 8, .pickup_capacity = 4, .map_object_capacity = 8, .ambient_cars = 24, .ambient_peds = 40 };
const S = simmod.Sim(cfg);

const zones = [_]simmod.level.Zone{
    .{ .kind = .navigation, .x = 32, .y = 32, .w = 96, .h = 96, .name = "downtown" },
    .{ .kind = .navigation, .x = 128, .y = 32, .w = 96, .h = 96, .name = "quiet" },
};
const lvl: simmod.Level = .{ .zones = &zones };

const Fixture = struct {
    grid: *map.Grid,
    sim: *S,
    frames: [1]Frame = @splat(Frame.neutral(0)),

    fn init(bx: u8, by: u8) !Fixture {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(S);
        s.init(g, .{ .seed = 3, .mode = .authoritative });
        s.attachLevel(&lvl);
        var f: Fixture = .{ .grid = g, .sim = s };
        f.sim.step(&f.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(bx, by) }});
        return f;
    }
    fn deinit(f: *Fixture) void {
        std.testing.allocator.destroy(f.sim);
        std.testing.allocator.destroy(f.grid);
    }
    fn run(f: *Fixture, n: u32) void {
        for (0..n) |_| f.sim.step(&f.frames, &.{});
    }
    /// Ambient cars and peds within `T.ambient_far` of the player.
    fn near(f: *Fixture) struct { cars: u32, peds: u32 } {
        const pt = f.sim.transformOf(f.sim.pedOf(0).?).?.*;
        const Ctx = struct { x: i32, y: i32, cars: u32 = 0, peds: u32 = 0 };
        var ctx = Ctx{ .x = fx.toInt(pt.x), .y = fx.toInt(pt.y) };
        const w = &f.sim.state.world;
        w.each(.{ c.Vehicle, c.Transform }, &ctx, struct {
            fn g(cx: *Ctx, _: EntityId, v: *c.Vehicle, t: *c.Transform) void {
                if (!v.driver.isNone() or v.flags & c.Vehicle.flag_wrecked != 0) return;
                if (@max(@abs(fx.toInt(t.x) - cx.x), @abs(fx.toInt(t.y) - cx.y)) < T.ambient_far) cx.cars += 1;
            }
        }.g);
        w.each(.{ c.Pedestrian, c.Controller, c.Transform }, &ctx, struct {
            fn g(cx: *Ctx, _: EntityId, _: *c.Pedestrian, ctl: *c.Controller, t: *c.Transform) void {
                if (ctl.player != c.Controller.no_player) return;
                if (@max(@abs(fx.toInt(t.x) - cx.x), @abs(fx.toInt(t.y) - cx.y)) < T.ambient_far) cx.peds += 1;
            }
        }.g);
        return .{ .cars = ctx.cars, .peds = ctx.peds };
    }
};

test "zone settings: set by name, looked up by block, kept in the saved state" {
    var f = try Fixture.init(69, 69);
    defer f.deinit();
    try std.testing.expect(!S.spawn.setZoneDensity(f.sim, "nowhere", .{}));
    try std.testing.expect(S.spawn.setZoneDensity(f.sim, "quiet", .{ .car_density = 100 }));
    try std.testing.expect(S.spawn.setZoneDensity(f.sim, "quiet", .{ .car_density = 200 })); // replaces
    try std.testing.expectEqual(@as(u16, 1), f.sim.state.sp.traffic.count);
    try std.testing.expectEqual(@as(u16, 200), S.spawn.zoneDensityAt(f.sim, 150, 50).?.car_density);
    try std.testing.expect(S.spawn.zoneDensityAt(f.sim, 50, 50) == null);
    // Through save and load.
    var buf: [S.state_size]u8 = undefined;
    _ = f.sim.save(&buf);
    f.sim.state.sp.traffic.count = 0;
    try f.sim.load(&buf);
    try std.testing.expectEqual(@as(u16, 200), S.spawn.zoneDensityAt(f.sim, 150, 50).?.car_density);
}

test "zone spawning: a busy zone fills up near the player, an empty one drains" {
    var f = try Fixture.init(69, 69);
    defer f.deinit();
    try std.testing.expect(S.spawn.setZoneDensity(f.sim, "downtown", .{ .car_density = 2000, .car_ratio = .{ 1, 0, 1, 0 }, .ped_density = 0 }));
    f.run(2400);
    const n = f.near();
    // Target 48 cars (twice the ambient count, capped at three quarters
    // of the capacity); the ambient 24 come near and the spawner adds the
    // rest, one per look.
    try std.testing.expect(n.cars >= 40);
    // No peds wanted: those near are only the ones on screen (the drain
    // removes out-of-sight ones only).
    try std.testing.expect(n.peds <= 4 + 12);
    // Some spawned police-kind cars are marked emergency.
    var emergency: u32 = 0;
    const w = &f.sim.state.world;
    w.each(.{c.Vehicle}, &emergency, struct {
        fn g(k: *u32, _: EntityId, v: *c.Vehicle) void {
            if (v.ai_flags & c.Vehicle.ai_emergency != 0) k.* += 1;
        }
    }.g);
    try std.testing.expect(emergency > 0);
}

test "zone spawning: no settings leaves the population as before" {
    var f = try Fixture.init(69, 69);
    defer f.deinit();
    const before = f.sim.state.world.count(S.Car);
    f.run(400);
    try std.testing.expectEqual(before, f.sim.state.world.count(S.Car));
}

test "recycling: a car with a passenger aboard and no driver is never despawned" {
    var f = try Fixture.init(69, 69);
    defer f.deinit();
    // The zone wants no cars, so the drain looks for spares; one car sits
    // in the drain's reach (out of sight, under `ambient_far`) and one
    // beyond it, where the ambient recycler moves cars.
    try std.testing.expect(S.spawn.setZoneDensity(f.sim, "downtown", .{ .car_density = 0, .ped_density = 0 }));
    const w = &f.sim.state.world;
    var cars: [2]EntityId = undefined;
    var peds: [2]EntityId = undefined;
    for ([2][2]i32{ .{ 69 + 20, 66 }, .{ 69 + 60, 66 } }, 0..) |p, i| {
        cars[i] = f.sim.spawnCarAt(h_.blk(p[0]), h_.blk(p[1]), 0, 0).?;
        peds[i] = S.spawn.spawnPed(f.sim, c.Controller.no_player, 0).?;
    }
    f.run(1);
    for (cars, peds) |car, ped| w.get(ped, c.Riding).?.vehicle = car;
    f.run(2000);
    for (cars, peds) |car, ped| {
        try std.testing.expect(w.isAlive(car));
        try std.testing.expect(w.isAlive(ped));
        try std.testing.expectEqual(car.raw, w.get(ped, c.Riding).?.vehicle.raw);
    }
}
