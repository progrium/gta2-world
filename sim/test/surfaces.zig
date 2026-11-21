//! Tests: Deep water.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const input = h_.input;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const testmap = h_.testmap;
const Button = h_.Button;
const Frame = h_.Frame;
const EntityId = h_.EntityId;
const eql = h_.eql;
const cfg_small = h_.cfg_small;
const S = h_.S;
const Harness = h_.Harness;
const blk = h_.blk;
const hasEvent = h_.hasEvent;
const flood = h_.flood;
const arm = h_.arm;
const shotCount = h_.shotCount;

test "deep water drowns a ped, credited to a recent attacker" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    h.join(1, 36, 44);
    const w = &h.sim.state.world;
    const z = h.ped(1).z;
    flood(&h, 40, 44, 41, 44, z);
    // Hurt by player 0 just now, then walked into the water.
    const vh = w.get(h.sim.pedOf(1).?, c.Health).?;
    vh.last_hit_by = h.sim.pedOf(0).?;
    h.ped(1).x = blk(40);
    h.ped(1).y = blk(44);
    h.run(3);
    try std.testing.expect(h.sim.pedOf(1) == null);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[0].kills);
    try std.testing.expectEqual(T.points_player_electro, h.sim.state.players[0].score);
}

test "a car fully in deep water loses drive and sinks with its driver; one half in is pulled in" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    const w = &h.sim.state.world;
    const z = h.ped(0).z;
    flood(&h, 38, 33, 46, 35, z);
    // Half on the water: drawn in.
    const half = h.sim.spawnCarAt(fx.fromInt(38), blk(34), 0, 0).?;
    const x0 = h.sim.transformOf(half).?.x;
    h.run(10);
    try std.testing.expect(h.sim.transformOf(half).?.x > x0);
    // Fully on it, driven by the player: no drive, then it sinks.
    const car = h.sim.spawnCarAt(blk(43), blk(34), 0, 0).?;
    h.run(1);
    const me = h.sim.pedOf(0).?;
    // Seated directly: walking to the door over deep water would drown him.
    h.sim.board(me, car);
    if (!eql(w.get(me, c.Riding).?.vehicle, car)) return error.TestNotBoarded;
    h.frames[0].throttle = 127;
    h.run(2);
    try std.testing.expect(w.get(car, c.Vehicle).?.flags & c.Vehicle.flag_in_water != 0);
    try std.testing.expect(fx.length(w.get(car, c.Velocity).?.vx, w.get(car, c.Velocity).?.vy) == 0);
    h.run(40);
    try std.testing.expect(!w.isAlive(car));
    try std.testing.expect(h.sim.pedOf(0) == null);
}

test "a passenger riding a sinking car drowns with it" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    h.join(1, 36, 41);
    const w = &h.sim.state.world;
    const z = h.ped(0).z;
    flood(&h, 38, 33, 46, 35, z);
    const car = h.sim.spawnCarAt(blk(43), blk(34), 0, 0).?;
    const rider = h.sim.pedOf(1).?;
    w.get(rider, c.Riding).?.vehicle = car;
    var n: u32 = 0;
    while (w.isAlive(car) and n < 60) : (n += 1) h.run(1);
    try std.testing.expect(!w.isAlive(car));
    // Gone in the same tick as the car, drowned.
    try std.testing.expect(h.sim.pedOf(1) == null or w.get(rider, c.Health).?.hp <= 0);
}

test "an electrified floor shocks a ped standing on it until he dies" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 20, 20);
    const id = h.sim.pedOf(0).?;
    const t = h.ped(0);
    const w = &h.sim.state.world;
    // The ground slab under (20, 20) is layer 0.
    h.grid.surface[0][20][20] |= map.Surface.electrified;
    h.run(1);
    const p = w.get(id, c.Pedestrian).?;
    // +3, -1 decay: net +2 a tick.
    try std.testing.expectEqual(@as(u8, 2), p.shock);
    var n: u32 = 0;
    while (h.sim.pedOf(0) != null and w.get(id, c.Health).?.hp > 0 and n < 200) : (n += 1) h.run(1);
    try std.testing.expect(n < 60);
    // Off the tile: no shock builds.
    var h2 = try Harness.init(.authoritative);
    defer h2.deinit();
    h2.join(0, 20, 20);
    h2.grid.surface[0][21][21] |= map.Surface.electrified;
    h2.run(10);
    try std.testing.expectEqual(@as(u8, 0), h2.sim.state.world.get(h2.sim.pedOf(0).?, c.Pedestrian).?.shock);
    _ = t;
}

test "oil: a car on a slick spins for 30 ticks, takes damage and its brakes do nothing" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    const w = &h.sim.state.world;
    const car = h.sim.spawnCarAt(blk(20), blk(20), 0, 0).?;
    const v = w.get(car, c.Vehicle).?;
    const hp0 = w.get(car, c.Health).?.hp;
    S.surfaces.oilCar(h.sim, car, .none);
    try std.testing.expectEqual(T.oil_ticks, v.oil);
    try std.testing.expect(w.get(car, c.Health).?.hp < hp0);
    // A second slick while spinning does nothing more.
    const hp1 = w.get(car, c.Health).?.hp;
    S.surfaces.oilCar(h.sim, car, .none);
    try std.testing.expectEqual(hp1, w.get(car, c.Health).?.hp);
    // Coasting on oil with no engine force: neither axle grips, so a
    // sideways slide is not stopped by the tyres (only damping).
    const vel = w.get(car, c.Velocity).?;
    vel.vy = fx.ratio(2, 10);
    h.run(1);
    const oily = vel.vy;
    var h2 = try Harness.init(.authoritative);
    defer h2.deinit();
    const car2 = h2.sim.spawnCarAt(blk(20), blk(20), 0, 0).?;
    const vel2 = h2.sim.state.world.get(car2, c.Velocity).?;
    vel2.vy = fx.ratio(2, 10);
    h2.run(1);
    try std.testing.expect(oily > vel2.vy);
    h.run(T.oil_ticks);
    try std.testing.expectEqual(@as(u8, 0), v.oil);
}

test "a car left on a 45 degree ramp rolls back down it" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // 45 degree ramps at (20..22, 20) rising toward +x, level 1.
    for (18..23) |y| map.set(h.grid, 21, @intCast(y), 1, map.makeCell(map.Shape.slope, map.Code.ramp45(3), map.Ground.road, 0));
    const car = h.sim.spawnCarAt(fx.fromInt(21) + fx.half, blk(20), 0, 0).?;
    const t = h.sim.transformOf(car).?;
    h.run(1);
    const x0 = t.x;
    h.run(20);
    try std.testing.expect(t.x < x0);
}
