//! Tests: Cars: entering, handling, ramps, height, collisions.

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

test "enter a car, drive it, get out" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // Horizontal road along y = 32..35; eastbound lane is y 34..35.
    h.join(0, 60, 35);
    const car = h.sim.spawnCarAt(blk(61), fx.fromInt(35), 0, 0).?;
    // Too far? Ped at 60.5, car at 61.5: within reach.
    h.tap(0, Button.enter_exit);
    const ped_id = h.sim.pedOf(0).?;
    const w = &h.sim.state.world;
    try std.testing.expect(simmod.ecs.eql(w.get(ped_id, c.Riding).?.vehicle, car));
    try std.testing.expect(simmod.ecs.eql(h.sim.playerRow(0).car, car));
    try std.testing.expect(simmod.ecs.eql(w.get(car, c.Vehicle).?.driver, ped_id));

    // Full throttle: the pedal ramps up, the car speeds up toward top speed.
    const ct = h.sim.transformOf(car).?;
    const x0 = ct.x;
    h.frames[0].throttle = 127;
    h.run(1);
    try std.testing.expectEqual(@as(i8, 1), w.get(car, c.Vehicle).?.pedal);
    h.run(59);
    const v = w.get(car, c.Velocity).?;
    try std.testing.expect(v.vx > fx.ratio(2, 10));
    try std.testing.expect(v.vx <= T.carModel(0).max_speed);
    try std.testing.expect(ct.x > x0 + fx.fromInt(6));
    // The rider follows the car.
    try std.testing.expectEqual(ct.x, h.ped(0).x);

    // Brake to a stop.
    h.frames[0].throttle = -127;
    h.run(40);
    try std.testing.expect(v.vx <= 0);
    h.frames[0].throttle = 0;
    h.run(60);
    try std.testing.expectEqual(@as(fx.Fx, 0), v.vx);

    // Get out on the driver's side (left of travel = north, smaller y).
    h.tap(0, Button.enter_exit);
    try std.testing.expect(w.get(ped_id, c.Riding).?.vehicle.isNone());
    try std.testing.expect(w.get(car, c.Vehicle).?.driver.isNone());
    try std.testing.expect(h.ped(0).y < ct.y);
    try std.testing.expect(h.sim.playerRow(0).car.isNone());
    // The car no longer takes the player's input.
    h.frames[0].throttle = 127;
    h.run(10);
    try std.testing.expectEqual(@as(fx.Fx, 0), v.vx);
}

test "cars steer, slide with the handbrake, and stop at walls" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 34);
    const car = h.sim.spawnCarAt(blk(61), fx.fromInt(35), 0, 0).?;
    h.tap(0, Button.enter_exit);
    const w = &h.sim.state.world;
    const ct = h.sim.transformOf(car).?;
    const v = w.get(car, c.Velocity).?;
    h.frames[0].throttle = 127;
    h.run(40);
    // Steer right (clockwise on screen, toward +y).
    h.frames[0].steer = 127;
    h.run(8);
    try std.testing.expect(ct.heading > 0 and ct.heading < 32768);
    // Handbrake: lateral speed builds (the car slides).
    h.frames[0].buttons = Button.handbrake_jump;
    h.run(6);
    const fwd_x = fx.cos(ct.heading);
    const fwd_y = fx.sin(ct.heading);
    const lat = fx.mul(v.vx, -fwd_y) + fx.mul(v.vy, fwd_x);
    try std.testing.expect(fx.abs(lat) > fx.ratio(3, 100));
    h.frames[0] = Frame.neutral(0);
    // Aim it off the lane (beyond the arrow snap's 25 degrees) into the
    // city block: it must stop at a building with no corner in a wall.
    ct.heading = 16384 + 6000;
    h.frames[0].throttle = 127;
    h.run(150);
    const m = T.carModel(0);
    const cx = fx.cos(ct.heading);
    const sy = fx.sin(ct.heading);
    for ([_][2]fx.Fx{ .{ m.half_len, m.half_wid }, .{ m.half_len, -m.half_wid }, .{ -m.half_len, m.half_wid }, .{ -m.half_len, -m.half_wid } }) |p| {
        const px = ct.x + fx.mul(p[0], cx) - fx.mul(p[1], sy);
        const py = ct.y + fx.mul(p[0], sy) + fx.mul(p[1], cx);
        try std.testing.expect(!map.blocks(h.grid, px, py, ct.z, T.car_step));
    }
    try std.testing.expect(h.sim.scratch.stats.wall_hits > 0);
}

test "drive up the long 7 degree ramp onto the platform" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // The ramp runs south from y = yard_y - 5 (in the road) to the platform.
    const rx: i32 = testmap.yard_x + 4;
    h.join(0, @intCast(rx - 1), @intCast(testmap.yard_y - 6));
    const car = h.sim.spawnCarAt(blk(rx), fx.fromInt(testmap.yard_y - 6), 16384, 0).?;
    h.tap(0, Button.enter_exit);
    const ct = h.sim.transformOf(car).?;
    h.frames[0].throttle = 80;
    var top: fx.Fx = 0;
    for (0..150) |_| {
        h.run(1);
        top = @max(top, ct.z);
        if (ct.y > fx.fromInt(testmap.yard_y + 4)) break;
    }
    try std.testing.expectEqual(fx.fromInt(2), top);
}

test "a car driven off the top of a ramp flies, and a car over a ledge tips off" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // A two-block ramp at x 49-50 rising toward +x from height 1 to 2,
    // ending in a drop back to 1 (car-height.md 3.3).
    for ([_]u32{ 39, 40, 41 }) |yy| {
        map.set(h.grid, 49, yy, 1, map.makeCell(map.Shape.slope, map.Code.ramp26(3, false), map.Ground.road, 0));
        map.set(h.grid, 50, yy, 1, map.makeCell(map.Shape.slope, map.Code.ramp26(3, true), map.Ground.road, 0));
    }
    const car = h.sim.spawnCarAt(blk(46), blk(40), 0, 0).?;
    const t = h.sim.transformOf(car).?;
    const vel = h.sim.state.world.get(car, c.Velocity).?;
    var top: fx.Fx = 0;
    var airborne_past_ramp = false;
    for (0..40) |_| {
        if (t.x < fx.fromInt(51)) vel.vx = fx.ratio(25, 100);
        h.run(1);
        top = @max(top, t.z);
        if (t.x > fx.fromInt(51) + fx.half and t.z > fx.fromInt(1) + fx.ratio(1, 10)) airborne_past_ramp = true;
    }
    try std.testing.expect(top > fx.fromInt(2));
    try std.testing.expect(airborne_past_ramp);
    try std.testing.expectEqual(fx.one, t.z);
    // A parked car hanging half over the edge of a raised block is tipped
    // off it (car-height.md 3.1).
    for ([_]u32{ 48, 49 }) |xx| for ([_]u32{ 70, 71, 72 }) |yy| map.set(h.grid, xx, yy, 1, map.makeCell(map.Shape.solid, 0, map.Ground.pavement, 0));
    const c2 = h.sim.spawnCarAt(fx.fromInt(50) + fx.ratio(1, 10), blk(71), 0, 0).?;
    const t2 = h.sim.transformOf(c2).?;
    t2.z = fx.fromInt(2);
    h.run(60);
    try std.testing.expectEqual(fx.one, t2.z);
    try std.testing.expect(t2.x > fx.fromInt(50) + fx.half);
}

test "an off-centre car hit spins the car struck; a glancing wall hit spins the car" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    const a = h.sim.spawnCarAt(fx.fromInt(60), fx.fromInt(49) + fx.half, 0, 0).?;
    const b = h.sim.spawnCarAt(fx.fromInt(63), fx.fromInt(50) + fx.ratio(1, 10), 16384, 0).?;
    const w = &h.sim.state.world;
    w.get(a, c.Velocity).?.vx = fx.ratio(3, 10);
    var spun = false;
    for (0..20) |_| {
        h.run(1);
        if (w.get(b, c.Velocity).?.spin != 0) spun = true;
    }
    try std.testing.expect(spun);
    try std.testing.expect(h.sim.scratch.stats.impacts > 0);
    // A car driven at a building wall at an angle comes away turning.
    const d = h.sim.spawnCarAt(fx.fromInt(50), fx.fromInt(60) + fx.half, 16384 + 3000, 0).?;
    const dv = w.get(d, c.Velocity).?;
    dv.vx = fx.ratio(5, 100);
    dv.vy = fx.ratio(3, 10);
    var turned = false;
    for (0..20) |_| {
        h.run(1);
        if (dv.spin != 0) turned = true;
    }
    try std.testing.expect(turned);
}
