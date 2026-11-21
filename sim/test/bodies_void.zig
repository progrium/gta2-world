//! Tests: bodies against voids and low ceilings (workstream C). Each case is
//! a shape the level runner found on real maps.

const std = @import("std");
const h_ = @import("harness.zig");
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const Harness = h_.Harness;
const blk = h_.blk;

/// A void (no floor at any depth) at x 10..12, y 6..14, under a floating
/// deck one level up: a car or ped at street level passes under the deck,
/// and the deck must not count as a floor below it.
fn voidUnderDeck(h: *Harness) void {
    for (6..15) |y| for (10..13) |x| {
        map.set(h.grid, @intCast(x), @intCast(y), 0, 0);
        map.set(h.grid, @intCast(x), @intCast(y), 1, map.makeCell(map.Shape.slab, 0, map.Ground.field, 0));
    };
}

test "a car driven at a void under a deck stops at its edge" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    voidUnderDeck(&h);
    const car = h.sim.spawnCarAt(blk(17), blk(10), 32768, 0).?; // facing -x
    const t = h.sim.transformOf(car).?;
    const vel = h.sim.state.world.get(car, c.Velocity).?;
    for (0..120) |_| {
        vel.vx = -fx.ratio(15, 100);
        h.run(1);
    }
    h.run(60);
    try std.testing.expectEqual(fx.one, t.z);
    try std.testing.expect(t.x >= fx.fromInt(13));
    try std.testing.expect(!map.isVoid(h.grid, t.x, t.y, t.z));
}

test "a ped walking at a void under a deck stops at its edge" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    voidUnderDeck(&h);
    h.join(0, 16, 10);
    const t = h.ped(0);
    t.heading = 32768;
    h.frames[0].throttle = 127;
    h.run(80);
    try std.testing.expectEqual(fx.one, t.z);
    try std.testing.expect(t.x >= fx.fromInt(13));
}

test "isVoid ignores matter above the height asked about" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    voidUnderDeck(&h);
    // Under the deck: nothing below street level.
    try std.testing.expect(map.isVoid(h.grid, blk(11), blk(10), fx.one + T.car_step));
    // On the deck: its top is a floor.
    try std.testing.expect(!map.isVoid(h.grid, blk(11), blk(10), fx.fromInt(2)));
    // Beside the void: the ground slab.
    try std.testing.expect(!map.isVoid(h.grid, blk(14), blk(10), fx.one));
}

test "a ped walking up a ramp under a low ceiling stops before his head hits it" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // A 45 degree ramp at (20, 10) rising toward +x from 1 to 2, a block of
    // matter over it at level 2 (the mike2e case: a ramp under a partial
    // block).
    map.set(h.grid, 20, 10, 1, map.makeCell(map.Shape.slope, map.Code.ramp45(3), map.Ground.pavement, 0));
    map.set(h.grid, 20, 10, 2, map.makeCell(map.Shape.solid, 0, map.Ground.pavement, 0));
    h.join(0, 18, 10);
    const t = h.ped(0);
    t.heading = 0; // +x
    h.frames[0].throttle = 127;
    h.run(60);
    try std.testing.expect(t.x > fx.fromInt(20));
    try std.testing.expect(!map.blocks(h.grid, t.x, t.y, t.z, T.ped_step));
    // And he can walk back out.
    t.heading = 32768;
    const x0 = t.x;
    h.run(20);
    try std.testing.expect(t.x < x0 - fx.half);
}

test "a car driven up a ramp under a low ceiling stops before its roof hits it" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    for (8..13) |y| {
        map.set(h.grid, 20, @intCast(y), 1, map.makeCell(map.Shape.slope, map.Code.ramp45(3), map.Ground.road, 0));
        map.set(h.grid, 20, @intCast(y), 2, map.makeCell(map.Shape.solid, 0, map.Ground.road, 0));
    }
    const car = h.sim.spawnCarAt(blk(16), blk(10), 0, 0).?;
    const t = h.sim.transformOf(car).?;
    const vel = h.sim.state.world.get(car, c.Velocity).?;
    for (0..80) |_| {
        vel.vx = fx.ratio(15, 100);
        h.run(1);
    }
    try std.testing.expect(!h.sim.boxBlocked(t.x, t.y, t.z, t.heading, T.carModel(0)));
}

/// A tower of `levels` solid blocks at x 10..12, y 19..21 on the field
/// outside the city; a ped joined on it walks off its +x edge. Returns the
/// hit points lost and whether he died, once he has landed.
fn walkOffTower(levels: u32, invulnerable: bool) !struct { lost: i32, dead: bool, ticks: u32 } {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    for (1..levels + 1) |z| for (19..22) |y| for (10..13) |x| {
        map.set(h.grid, @intCast(x), @intCast(y), @intCast(z), map.makeCell(map.Shape.solid, 0, map.Ground.pavement, 0));
    };
    h.join(0, 12, 20);
    const id = h.sim.pedOf(0).?;
    const t = h.ped(0);
    try std.testing.expectEqual(fx.fromInt(@intCast(levels + 1)), t.z);
    const ped = h.sim.state.world.get(id, c.Pedestrian).?;
    if (invulnerable) ped.invulnerable = 1000;
    const hp = h.sim.state.world.get(id, c.Health).?;
    const hp0 = hp.hp;
    t.heading = 0;
    h.frames[0].throttle = 127;
    var fell = false;
    var ticks: u32 = 0;
    while (ticks < 200) : (ticks += 1) {
        h.run(1);
        if (ped.state == c.Pedestrian.state_falling) {
            fell = true;
            try std.testing.expectEqual(c.Pedestrian.anim_fall, ped.anim);
        }
        if (hp.hp <= 0) return .{ .lost = hp0 - hp.hp, .dead = true, .ticks = ticks };
        if (fell and ped.state == c.Pedestrian.state_up) break;
    }
    try std.testing.expect(fell);
    try std.testing.expectEqual(fx.one, t.z);
    return .{ .lost = hp0 - hp.hp, .dead = false, .ticks = ticks };
}

test "falls: one level is harmless, two levels hurt, four are lethal unless invulnerable" {
    const one = try walkOffTower(1, false);
    try std.testing.expect(!one.dead);
    try std.testing.expectEqual(@as(i32, 0), one.lost);
    const two = try walkOffTower(2, false);
    try std.testing.expect(!two.dead);
    try std.testing.expect(two.lost == T.fall_damage or two.lost == 2 * T.fall_damage);
    const four = try walkOffTower(4, false);
    try std.testing.expect(four.dead);
    const safe = try walkOffTower(4, true);
    try std.testing.expect(!safe.dead);
    try std.testing.expectEqual(@as(i32, 0), safe.lost);
}

test "partial blocks are floors that never wall a body; three-sided diagonal blocks are flat on top with a diagonal wall" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    const g = h.grid;
    const z = fx.one;
    // A left partial block (53) at (20, 10) level 1: walked into from the
    // side it does not block, and its strip's top is a floor at 2.
    map.set(g, 20, 10, 1, map.makeCell(map.Shape.partial, map.Code.partial(0), map.Ground.pavement, 0));
    try std.testing.expect(!map.blocks(g, fx.fromInt(20) + fx.ratio(1, 8), blk(10), z, T.ped_step));
    try std.testing.expectEqual(fx.fromInt(2), map.floorAt(g, fx.fromInt(20) + fx.ratio(1, 8), blk(10), fx.fromInt(2), T.ped_step));
    // A three-sided diagonal block 49 (open up-left) at (22, 10) level 1:
    // the top is a floor at 2 over the whole block; from the side, the
    // closed half blocks and the open half does not.
    map.set(g, 22, 10, 1, map.makeCell(map.Shape.slope, 49, map.Ground.pavement, 0));
    const open_u = fx.fromInt(22) + fx.ratio(1, 8);
    const open_v = fx.fromInt(10) + fx.ratio(1, 8);
    const closed_u = fx.fromInt(22) + fx.ratio(7, 8);
    const closed_v = fx.fromInt(10) + fx.ratio(7, 8);
    try std.testing.expect(!map.blocks(g, open_u, open_v, z, T.ped_step));
    try std.testing.expect(map.blocks(g, closed_u, closed_v, z, T.ped_step));
    try std.testing.expectEqual(fx.fromInt(2), map.floorAt(g, open_u, open_v, fx.fromInt(2), T.ped_step));
    try std.testing.expectEqual(fx.fromInt(2), map.floorAt(g, closed_u, closed_v, fx.fromInt(2), T.ped_step));
}

test "the map edge is a wall at the top level only" {
    try std.testing.expect(map.pastTopEdge(fx.ratio(9, 10), blk(100), fx.fromInt(7)));
    try std.testing.expect(map.pastTopEdge(blk(100), fx.fromInt(255) + fx.ratio(1, 10), fx.fromInt(7) + fx.half));
    try std.testing.expect(!map.pastTopEdge(fx.ratio(11, 10), blk(100), fx.fromInt(7)));
    try std.testing.expect(!map.pastTopEdge(fx.ratio(9, 10), blk(100), fx.fromInt(6)));
    // A car on a top-level deck along the west edge stops a block short.
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    for (6..15) |y| for (0..8) |x| map.set(h.grid, @intCast(x), @intCast(y), 6, map.makeCell(map.Shape.slab, 0, map.Ground.road, 0));
    const car = h.sim.spawnCarAt(blk(6), blk(10), 32768, 0).?;
    const t = h.sim.transformOf(car).?;
    t.z = fx.fromInt(7);
    const vel = h.sim.state.world.get(car, c.Velocity).?;
    for (0..80) |_| {
        vel.vx = -fx.ratio(15, 100);
        h.run(1);
    }
    try std.testing.expectEqual(fx.fromInt(7), t.z);
    try std.testing.expect(t.x - T.carModel(0).half_len >= fx.one - fx.ratio(1, 10));
}

test "a body shoved off a roof edge drops clear of the wall below, not into it" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // A two-level building at x 10..14, y 10..13 on the field: roof at z 3,
    // its south face the line y = 14.
    for (1..3) |z| for (10..14) |y| for (10..15) |x| {
        map.set(h.grid, @intCast(x), @intCast(y), @intCast(z), map.makeCell(map.Shape.solid, 0, map.Ground.pavement, 0));
    };
    h.join(0, 12, 13);
    const id = h.sim.pedOf(0).?;
    const t = h.ped(0);
    try std.testing.expectEqual(fx.fromInt(3), t.z);
    // Knocked down, shoved until its centre is just over the edge (the D1
    // soak case).
    h.sim.knock(id, c.Pedestrian.state_down, 0, fx.one, 0, 0, .none);
    t.y = fx.fromInt(14) + fx.ratio(1, 100);
    for (0..120) |_| {
        h.run(1);
        try std.testing.expect(!h.sim.circleBlocked(t.x, t.y, t.z, T.ped_radius, T.ped_step) or t.z > fx.fromInt(2));
    }
    try std.testing.expectEqual(fx.one, t.z);
    try std.testing.expect(t.y - T.ped_radius >= fx.fromInt(14));
}
