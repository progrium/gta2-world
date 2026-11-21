//! Tests: getting in and out of cars and carjacking
//! (entering-and-exiting-cars.md). Workstream D2.

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
const EntityId = abi.EntityId;
const Harness = h_.Harness;
const S = h_.S;
const blk = h_.blk;
const eql = h_.eql;
const E = T.enter_exit;
const anim = simmod.anim;

/// Ticks from arriving at the door to being seated, without a hijack.
const door_ticks: u32 = @as(u32, anim.frames.enter_car) * anim.ticks_per_frame.enter_car;

fn pedc(h: *Harness, id: EntityId) *c.Pedestrian {
    return h.sim.state.world.get(id, c.Pedestrian).?;
}
fn riding(h: *Harness, id: EntityId) EntityId {
    return h.sim.state.world.get(id, c.Riding).?.vehicle;
}
fn press(h: *Harness, slot: u32) void {
    h.frames[slot].buttons |= Button.enter_exit;
    h.run(1);
    h.frames[slot].buttons &= ~Button.enter_exit;
    h.run(1);
}
/// Run until `id` has no car order (or `max` ticks); returns ticks run.
fn runUntilSettled(h: *Harness, id: EntityId, max: u32) u32 {
    var n: u32 = 0;
    while (n < max) : (n += 1) {
        const ph = pedc(h, id).car_phase;
        if (ph == 0 or ph == @intFromEnum(S.EnterPhase.thief)) return n;
        h.run(1);
    }
    return n;
}
/// An AI ped seated as `car`'s driver.
fn aiDriver(h: *Harness, car: EntityId) EntityId {
    const d = h.sim.spawnPed(c.Controller.no_player, 0).?;
    h.sim.state.world.applyPending();
    h.sim.board(d, car);
    // He is not a thief: he stays put.
    const p = pedc(h, d);
    p.car_phase = 0;
    p.car = .none;
    return d;
}

test "enter: run to the driver's door, open it, get in" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 37);
    const car = h.sim.spawnCarAt(blk(61), blk(34), 0, 0).?;
    const me = h.sim.pedOf(0).?;
    h.ped(0).heading = 16384 * 3; // facing north, toward the road
    press(&h, 0);
    // The order is set but he is still on foot, running.
    try std.testing.expect(riding(&h, me).isNone());
    try std.testing.expectEqual(@intFromEnum(S.EnterPhase.walk), pedc(&h, me).car_phase);
    h.run(1);
    try std.testing.expectEqual(c.Pedestrian.anim_run, pedc(&h, me).anim);
    // Reaches the door, then the door animation, then he is driving.
    var reached = false;
    for (0..200) |_| {
        h.run(1);
        if (pedc(&h, me).car_phase == @intFromEnum(S.EnterPhase.door)) {
            reached = true;
            break;
        }
    }
    try std.testing.expect(reached);
    try std.testing.expectEqual(c.Pedestrian.state_entering, pedc(&h, me).state);
    // At the driver's door: north side (left of an eastbound car).
    const ct = h.sim.transformOf(car).?;
    try std.testing.expect(h.ped(0).y < ct.y);
    h.run(door_ticks - 1);
    try std.testing.expect(riding(&h, me).isNone());
    h.run(1);
    try std.testing.expect(eql(riding(&h, me), car));
    try std.testing.expect(eql(h.sim.state.world.get(car, c.Vehicle).?.driver, me));
    try std.testing.expect(eql(h.sim.playerRow(0).car, car));
    try std.testing.expectEqual(c.Pedestrian.state_up, pedc(&h, me).state);
}

test "enter: the search point is half a block ahead; up to 3 rings out" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 35);
    const west = h.sim.spawnCarAt(blk(58), blk(34), 0, 0).?;
    const east = h.sim.spawnCarAt(blk(63), blk(34), 0, 0).?;
    const me = h.sim.pedOf(0).?;
    // West is nearer the ped, but he faces east: the east car is nearer
    // the search point? No: 2.5 vs 2.5 from the ped; the point decides.
    h.ped(0).* = .{ .x = blk(60), .y = blk(35), .z = h.ped(0).z, .heading = 0 };
    h.sim.transformOf(west).?.x = blk(57) + fx.ratio(3, 4);
    h.sim.transformOf(east).?.x = blk(62) + fx.ratio(1, 4);
    press(&h, 0);
    try std.testing.expect(eql(pedc(&h, me).car, east));
    h.sim.cancelEnter(me);
    h.ped(0).heading = 32768;
    press(&h, 0);
    try std.testing.expect(eql(pedc(&h, me).car, west));
    h.sim.cancelEnter(me);
    // Nothing within 3 rings: no order.
    h.sim.transformOf(west).?.x = blk(50);
    h.sim.transformOf(east).?.x = blk(70);
    press(&h, 0);
    try std.testing.expectEqual(@as(u8, 0), pedc(&h, me).car_phase);
}

test "enter: a movement key cancels; a car more than 4 blocks off is given up" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 37);
    const car = h.sim.spawnCarAt(blk(62), blk(34), 0, 0).?;
    const me = h.sim.pedOf(0).?;
    press(&h, 0);
    try std.testing.expect(pedc(&h, me).car_phase != 0);
    h.frames[0].steer = 50;
    h.run(1);
    h.frames[0].steer = 0;
    try std.testing.expectEqual(@as(u8, 0), pedc(&h, me).car_phase);
    // Too far: the car moves away (pushed, no driver) while he runs.
    press(&h, 0);
    try std.testing.expect(eql(pedc(&h, me).car, car));
    h.sim.transformOf(car).?.x = blk(70);
    h.run(1);
    try std.testing.expectEqual(@as(u8, 0), pedc(&h, me).car_phase);
    try std.testing.expect(riding(&h, me).isNone());
}

test "enter: waits beside a car that is too fast; thrown off one that drives away" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 37);
    const car = h.sim.spawnCarAt(blk(60), blk(34), 0, 0).?;
    const me = h.sim.pedOf(0).?;
    const cv = h.sim.state.world.get(car, c.Velocity).?;
    const ct = h.sim.transformOf(car).?;
    // Stand at the door of a car moving at 0.25: he waits (no door phase).
    const m = T.carModel(0);
    const door = S.doorPos(ct, m, 0);
    h.ped(0).* = .{ .x = door.x, .y = door.y - fx.one, .z = h.ped(0).z, .heading = 16384 };
    press(&h, 0);
    for (0..5) |_| {
        cv.* = .{ .vx = 0, .vy = 0, .vz = 0, .spin = 0 };
        ct.x = blk(60);
        h.run(1);
    }
    // Now the car creeps along too fast: he stops rather than run.
    const y_wait = h.ped(0).y;
    for (0..10) |_| {
        cv.vx = fx.ratio(25, 100);
        ct.x = blk(60);
        h.run(1);
        try std.testing.expectEqual(@intFromEnum(S.EnterPhase.walk), pedc(&h, me).car_phase);
    }
    try std.testing.expectEqual(y_wait, h.ped(0).y);
    // It stops: he gets to the door. Then it drives off: thrown.
    cv.vx = 0;
    ct.x = blk(60);
    var at_door = false;
    for (0..60) |_| {
        h.run(1);
        if (pedc(&h, me).car_phase == @intFromEnum(S.EnterPhase.door)) {
            at_door = true;
            break;
        }
    }
    try std.testing.expect(at_door);
    cv.vx = fx.ratio(3, 10);
    h.run(1);
    try std.testing.expectEqual(@as(u8, 0), pedc(&h, me).car_phase);
    const st = pedc(&h, me).state;
    try std.testing.expect(st == c.Pedestrian.state_over or st == c.Pedestrian.state_down);
    try std.testing.expect(riding(&h, me).isNone());
    try std.testing.expect(h.sim.state.world.get(me, c.Collider).?.flags & c.Collider.flag_disabled == 0);
}

test "carjack: the driver is pulled out onto the pavement, the jacker scores the hijack" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 31);
    const car = h.sim.spawnCarAt(blk(60), blk(33), 0, 0).?;
    const driver = aiDriver(&h, car);
    const me = h.sim.pedOf(0).?;
    const before = h.sim.playerRow(0).score;
    h.ped(0).heading = 16384;
    press(&h, 0);
    // Walk, then the door frames up to the hijack on frame 5.
    var hijacked = false;
    for (0..200) |_| {
        h.run(1);
        if (pedc(&h, driver).state == c.Pedestrian.state_pulled_out) {
            hijacked = true;
            break;
        }
    }
    try std.testing.expect(hijacked);
    try std.testing.expect(riding(&h, driver).isNone());
    try std.testing.expect(h.sim.state.world.get(car, c.Vehicle).?.driver.isNone());
    try std.testing.expectEqual(before + T.carModel(0).value, h.sim.playerRow(0).score);
    _ = runUntilSettled(&h, me, 200);
    try std.testing.expect(eql(riding(&h, me), car));
    // The victim is back on his feet beside the car, outside it.
    _ = runUntilSettled(&h, driver, 200);
    try std.testing.expectEqual(c.Pedestrian.state_up, pedc(&h, driver).state);
    try std.testing.expect(h.sim.state.world.get(driver, c.Collider).?.flags & c.Collider.flag_disabled == 0);
    const dt = h.sim.transformOf(driver).?;
    const ct = h.sim.transformOf(car).?;
    try std.testing.expect(!S.inRect(ct, T.carModel(0), dt.x, dt.y));
    try std.testing.expect(fx.length(dt.x - ct.x, dt.y - ct.y) < fx.fromInt(2));
}

test "carjack: a traffic car's driver is pulled out too" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 31);
    const car = h.sim.spawnCarAt(blk(60), blk(33), 0, 0).?;
    const v = h.sim.state.world.get(car, c.Vehicle).?;
    v.flags |= c.Vehicle.flag_ai;
    v.halt = 300;
    const peds0 = h.sim.state.world.count(S.Ped);
    h.ped(0).heading = 16384;
    press(&h, 0);
    _ = runUntilSettled(&h, h.sim.pedOf(0).?, 300);
    try std.testing.expect(eql(riding(&h, h.sim.pedOf(0).?), car));
    try std.testing.expectEqual(peds0 + 1, h.sim.state.world.count(S.Ped));
    try std.testing.expect(v.flags & c.Vehicle.flag_ai == 0);
}

test "carjack: one player pulls another out (deathmatch)" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 31);
    h.join(1, 64, 31);
    const car = h.sim.spawnCarAt(blk(60), blk(33), 0, 0).?;
    const them = h.sim.pedOf(1).?;
    h.sim.board(them, car);
    h.ped(0).heading = 16384;
    press(&h, 0);
    _ = runUntilSettled(&h, h.sim.pedOf(0).?, 300);
    try std.testing.expect(eql(riding(&h, h.sim.pedOf(0).?), car));
    try std.testing.expect(h.sim.playerRow(1).car.isNone());
    try std.testing.expect(riding(&h, them).isNone());
}

test "doors: the other side when the driver's door is blocked; none usable fails" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 37);
    const car = h.sim.spawnCarAt(blk(60), blk(34), 0, 0).?;
    const ct = h.sim.transformOf(car).?;
    const m = T.carModel(0);
    // Another car parked on the driver's (north) side.
    const north = h.sim.spawnCarAt(blk(60), blk(34) - m.half_wid * 2 - fx.ratio(1, 10), 0, 0).?;
    _ = north;
    try std.testing.expectEqual(@as(?u8, 1), S.firstUsableDoor(h.sim, car, ct, m));
    const me = h.sim.pedOf(0).?;
    h.ped(0).heading = 16384 * 3;
    press(&h, 0);
    _ = runUntilSettled(&h, me, 300);
    try std.testing.expect(eql(riding(&h, me), car));
    // Both sides blocked: no door.
    h.sim.tryExit(me);
    _ = runUntilSettled(&h, me, 100);
    const south = h.sim.spawnCarAt(blk(60), blk(34) + m.half_wid * 2 + fx.ratio(1, 10), 0, 0).?;
    _ = south;
    try std.testing.expectEqual(@as(?u8, null), S.firstUsableDoor(h.sim, car, ct, m));
}

test "exit: only below 3/10 a tick; the exit animation plays; handbrake kept as left" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 35);
    const car = h.sim.spawnCarAt(blk(61), fx.fromInt(35), 0, 0).?;
    const me = h.sim.pedOf(0).?;
    h.sim.board(me, car);
    const cv = h.sim.state.world.get(car, c.Velocity).?;
    cv.vx = fx.ratio(31, 100);
    h.sim.tryExit(me);
    try std.testing.expect(eql(riding(&h, me), car));
    cv.vx = fx.ratio(29, 100);
    h.frames[0].buttons = Button.handbrake_jump;
    h.run(1);
    h.sim.tryExit(me);
    try std.testing.expect(riding(&h, me).isNone());
    try std.testing.expectEqual(c.Pedestrian.state_exiting, pedc(&h, me).state);
    try std.testing.expect(h.sim.state.world.get(car, c.Controller).?.in.buttons & Button.handbrake_jump != 0);
    h.frames[0].buttons = 0;
    const n = runUntilSettled(&h, me, 100);
    try std.testing.expect(n >= @as(u32, anim.frames.exit_car) * anim.ticks_per_frame.exit_car - 1);
    try std.testing.expectEqual(c.Pedestrian.state_up, pedc(&h, me).state);
    // Without the handbrake held, the car is left free to roll.
    h.sim.board(me, car);
    cv.* = std.mem.zeroes(c.Velocity);
    h.run(1);
    h.sim.tryExit(me);
    try std.testing.expect(h.sim.state.world.get(car, c.Controller).?.in.buttons & Button.handbrake_jump == 0);
}

test "AI thief: gets in, drives for 600 ticks, gets out; removed if the car goes" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    const car = h.sim.spawnCarAt(blk(60), blk(34), 0, 0).?;
    const thief = h.sim.spawnPed(c.Controller.no_player, 0).?;
    h.sim.state.world.applyPending();
    h.sim.transformOf(thief).?.* = .{ .x = blk(60), .y = blk(36), .z = h.sim.transformOf(car).?.z, .heading = 0 };
    h.sim.startEnter(thief, car);
    _ = runUntilSettled(&h, thief, 300);
    try std.testing.expect(eql(riding(&h, thief), car));
    try std.testing.expectEqual(S.EnterPhase.thief, h.sim.enterPhase(thief));
    h.run(E.thief_ticks - 2);
    try std.testing.expect(eql(riding(&h, thief), car));
    h.run(3);
    try std.testing.expect(riding(&h, thief).isNone());
    // In again, then the car is removed: the thief goes with it.
    _ = runUntilSettled(&h, thief, 100);
    h.sim.startEnter(thief, car);
    _ = runUntilSettled(&h, thief, 300);
    try std.testing.expect(eql(riding(&h, thief), car));
    h.sim.state.world.despawn(car);
    h.run(1);
    try std.testing.expect(!h.sim.state.world.isAlive(thief));
}

test "enter and exit stay deterministic through save and load" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 31);
    const car = h.sim.spawnCarAt(blk(60), blk(33), 0, 0).?;
    _ = aiDriver(&h, car);
    h.ped(0).heading = 16384;
    press(&h, 0);
    h.run(10);
    var buf: [S.state_size]u8 = undefined;
    _ = h.sim.save(&buf);
    h.run(80);
    const h1 = h.sim.hash();
    try h.sim.load(&buf);
    h.run(80);
    try std.testing.expectEqual(h1, h.sim.hash());
}
