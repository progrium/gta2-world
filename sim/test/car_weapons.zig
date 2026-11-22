//! Tests: vehicle weapons outside single player (sys/car_weapons.zig):
//! pickups, oil, mines and the car bomb in a plain deathmatch
//! configuration, where the weapon lives on the car (`c.Vehicle`). The
//! single-player tests are in career.zig; weapon shops are in shops.zig.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const fx = h_.fx;
const c = h_.c;
const T = h_.T;
const Button = h_.Button;
const EntityId = h_.EntityId;
const blk = h_.blk;
const TC = @import("../tuning/career.zig");
const OT = @import("../tuning/objects.zig");

const S = h_.S;
const CW = S.car_weapons;

comptime {
    // The harness config is a plain deathmatch one: no city.
    std.debug.assert(!S.city);
}

fn drivingCar(h: *h_.Harness) EntityId {
    h.join(0, 30, 40);
    h.run(2);
    const car = h.sim.spawnCarAt(blk(44), blk(34), 0, 0).?;
    h.run(1);
    h.sim.board(h.sim.pedOf(0).?, car);
    h.run(1);
    return car;
}

fn dropPickup(h: *h_.Harness, kind: u8, x: fx.Fx, y: fx.Fx, z: fx.Fx) void {
    const id = h.sim.state.world.spawn(S.Pickup).?;
    h.sim.initPickup(id, x, y, z, kind);
    h.sim.state.world.applyPending();
}

test "car weapons in deathmatch: a car gun pickup arms the car, which fires two shots" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    const car = drivingCar(&h);
    const t = h.sim.transformOf(car).?.*;
    // On foot it would not be taken; driving over it fits the guns.
    dropPickup(&h, T.pickup_car_guns, t.x, t.y, t.z);
    h.run(1);
    try std.testing.expectEqual(TC.CarWeapon.car_guns, CW.weaponOf(h.sim, car));
    try std.testing.expectEqual(T.car_pickup_rounds[3] * 10, CW.ammoOf(h.sim, car));
    try std.testing.expectEqual(@as(u32, 0), h.sim.state.world.count(S.Pickup));
    h.frames[0].buttons = Button.fire;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 2), h.sim.state.world.count(S.Shot));
    h.frames[0].buttons = 0;
    try std.testing.expectEqual(T.car_pickup_rounds[3] * 10 - 1, CW.ammoOf(h.sim, car));
}

test "car weapons in deathmatch: a car pickup is left alone on foot" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 30, 40);
    h.run(2);
    const t = h.ped(0).*;
    dropPickup(&h, T.pickup_car_mines, t.x, t.y, t.z);
    h.run(2);
    try std.testing.expectEqual(@as(u32, 1), h.sim.state.world.count(S.Pickup));
}

test "car weapons in deathmatch: oil sends another car spinning, not the one that dropped it" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    const car = drivingCar(&h);
    try std.testing.expect(CW.arm(h.sim, car, .oil, 2));
    h.frames[0].buttons = Button.fire;
    h.run(4);
    h.frames[0].buttons = 0;
    try std.testing.expect(h.sim.state.world.count(S.MapObject) >= 1);
    try std.testing.expectEqual(@as(u8, 0), h.sim.state.world.get(car, c.Vehicle).?.oil);
    // Another car parked on the oil spins and takes damage.
    const t = h.sim.transformOf(car).?.*;
    const m = T.carModel(0);
    const other = h.sim.spawnCarAt(t.x - m.half_len - TC.drop_behind, t.y, 0, 0).?;
    h.sim.state.world.applyPending();
    const hp0 = h.sim.state.world.get(other, c.Health).?.hp;
    h.run(1);
    try std.testing.expect(h.sim.state.world.get(other, c.Vehicle).?.oil > 0);
    try std.testing.expect(h.sim.state.world.get(other, c.Health).?.hp < hp0);
}

test "car weapons in deathmatch: a dropped mine blows up the next car over it" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    const car = drivingCar(&h);
    try std.testing.expect(CW.arm(h.sim, car, .mines, 2));
    h.frames[0].buttons = Button.fire;
    h.run(1);
    h.frames[0].buttons = 0;
    try std.testing.expectEqual(@as(u32, 1), h.sim.state.world.count(S.MapObject));
    try std.testing.expectEqual(@as(u16, 10), CW.ammoOf(h.sim, car));
    const t = h.sim.transformOf(car).?.*;
    const m = T.carModel(0);
    const other = h.sim.spawnCarAt(t.x - m.half_len - TC.drop_behind, t.y, 0, 0).?;
    h.run(1);
    const hp0 = h.sim.state.world.get(other, c.Health).?.hp;
    h.run(OT.mine_arm_ticks + 2);
    try std.testing.expectEqual(@as(u32, 0), h.sim.state.world.count(S.MapObject));
    try std.testing.expect(h.sim.state.world.get(other, c.Health).?.hp < hp0);
}

test "car weapons in deathmatch: the car bomb arms on a fresh press and wrecks the car later" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    const car = drivingCar(&h);
    try std.testing.expect(CW.arm(h.sim, car, .car_bomb, 1));
    h.frames[0].buttons = Button.fire;
    h.run(1);
    try std.testing.expect(CW.bombArmed(h.sim, car));
    try std.testing.expect(h_.hasEvent(h.sim.events(), .car_weapon));
    h.frames[0].buttons = 0;
    // Can't refit while it ticks.
    try std.testing.expect(!CW.arm(h.sim, car, .car_guns, 5));
    h.run(TC.car_bomb_fuse + 2);
    try std.testing.expect(h.sim.state.world.get(car, c.Vehicle).?.flags & c.Vehicle.flag_wrecked != 0);
    try std.testing.expectEqual(TC.CarWeapon.none, CW.fittedOf(h.sim, car));
}

test "car weapons: the fitted weapon is part of the saved state" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    const car = drivingCar(&h);
    try std.testing.expect(CW.arm(h.sim, car, .mines, 3));
    const buf = try std.testing.allocator.alloc(u8, S.state_size);
    defer std.testing.allocator.free(buf);
    _ = h.sim.save(buf);
    var g = try h_.Harness.init(.authoritative);
    defer g.deinit();
    try g.sim.load(buf);
    try std.testing.expectEqual(TC.CarWeapon.mines, CW.weaponOf(g.sim, car));
    try std.testing.expectEqual(@as(u16, 30), CW.ammoOf(g.sim, car));
}
