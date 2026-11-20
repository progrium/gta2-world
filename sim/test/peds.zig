//! Tests: Peds on foot: controls, ramps, jumps, walls.

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

test "tank controls: walk forward, turn, walls stop you" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // Pavement of the city block at (48, 48): x 52..53 pavement, 54.. building.
    h.join(0, 52, 56);
    const t = h.ped(0);
    try std.testing.expectEqual(@as(u16, 0), t.heading); // facing +x
    h.frames[0].throttle = 127;
    h.run(30);
    // Walked into the building at x = 54 and stopped against it.
    try std.testing.expect(t.x > blk(52));
    try std.testing.expect(t.x + T.ped_radius <= fx.fromInt(54));
    // Turn half way round with full steer, then walk back.
    h.frames[0].throttle = 0;
    h.frames[0].steer = 127;
    // The turn speed builds up to its cap, so half a turn takes a while.
    var turned: u32 = 0;
    while (@abs(@as(i32, @as(i16, @bitCast(t.heading -% 32768)))) > T.ped_turn_max and turned < 100) : (turned += 1) h.run(1);
    try std.testing.expect(turned > @divTrunc(32768, T.ped_turn_max));
    h.frames[0].steer = 0;
    const x0 = t.x;
    h.frames[0].throttle = 127;
    h.run(10);
    try std.testing.expect(t.x < x0);
}

test "direct controls: turn toward aim and move along it" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 52, 56);
    const t = h.ped(0);
    h.frames[0] = .{ .steer = 0, .throttle = 127, .buttons = Button.direct, .aim = 16384, .seq = 0 }; // south
    const y0 = t.y;
    h.run(10);
    try std.testing.expectEqual(@as(u16, 16384), t.heading);
    try std.testing.expect(t.y > y0);
    // One pace: run is no faster than walk (ped-movement.md 3.2).
    const y1 = t.y;
    h.frames[0].buttons |= Button.run;
    h.run(5);
    try std.testing.expectEqual(fx.mulAxis(T.ped_run, 127) * 5, t.y - y1);
}

test "walk up the 45 degree ramp onto the platform, then jump along it" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, testmap.yard_x, testmap.yard_y + 4);
    const t = h.ped(0);
    h.frames[0].throttle = 127; // facing +x, toward the ramp
    h.run(60);
    try std.testing.expectEqual(fx.fromInt(2), t.z);
    try std.testing.expect(t.x > fx.fromInt(testmap.yard_x + 3));
    // Jump: carries him forward at the run pace without leaving the floor.
    h.frames[0].throttle = 0;
    h.frames[0].buttons = Button.handbrake_jump;
    const x0 = t.x;
    h.run(4);
    try std.testing.expectEqual(fx.fromInt(2), t.z);
    try std.testing.expect(t.x > x0);
    // Holding the key does not jump again.
    h.run(T.ped_jump_ticks);
    const x1 = t.x;
    h.run(4);
    try std.testing.expectEqual(x1, t.x);
    h.frames[0].buttons = 0;
}

test "bottomless columns act as walls; a jump stays on the ground" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // Dig a void: the whole column at (54, 40) down to the bottom.
    const vx = 54;
    const vy = 40;
    for (0..map.size_z) |z| map.set(h.grid, vx, vy, @intCast(z), 0);
    h.join(0, vx - 2, vy); // facing +x, toward the void
    const t = h.ped(0);
    h.frames[0].throttle = 127;
    h.run(40);
    try std.testing.expectEqual(fx.one, t.z);
    try std.testing.expect(t.x < fx.fromInt(vx));
    // A one-block-high ceiling over (50, 40): a jump does not enter it.
    map.set(h.grid, 50, 40, 2, map.makeCell(map.Shape.solid, 0, 0, 0));
    h.sim.state.world.get(h.sim.pedOf(0).?, c.Transform).?.* = .{ .x = blk(50), .y = blk(40), .z = fx.one, .heading = 0 };
    h.frames[0] = Frame.neutral(0);
    h.frames[0].buttons = Button.handbrake_jump;
    const x0 = t.x;
    for (0..30) |_| {
        h.run(1);
        try std.testing.expectEqual(fx.one, t.z);
    }
    try std.testing.expect(t.x > x0);
}

test "a wall face stops peds and cars along its line only" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // A fence on the line x = 52 for y in [40, 41) at level 1, with open
    // road on both sides (shape-and-map-collision.md 3.2).
    h.grid.walls[1][40][51] = map.wall_right;
    h.join(0, 49, 40);
    const t = h.ped(0);
    t.* = .{ .x = blk(49), .y = blk(40), .z = fx.one, .heading = 0 };
    h.frames[0].throttle = 127;
    h.run(60);
    try std.testing.expect(t.x <= fx.fromInt(52) - T.ped_radius);
    try std.testing.expect(t.x > fx.fromInt(51) + fx.half);
    // One block further down the fence has ended: the ped walks on.
    t.* = .{ .x = blk(49), .y = blk(41), .z = fx.one, .heading = 0 };
    h.run(60);
    try std.testing.expect(t.x > fx.fromInt(53));
    h.frames[0] = Frame.neutral(0);
    // A car driven at it stops too.
    const car = h.sim.spawnCarAt(blk(48), blk(40), 0, 0).?;
    h.sim.state.world.get(car, c.Velocity).?.vx = fx.ratio(3, 10);
    h.run(30);
    const ct = h.sim.transformOf(car).?;
    try std.testing.expect(ct.x < fx.fromInt(52));
    try std.testing.expect(h.sim.scratch.stats.wall_hits > 0);
}
