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
