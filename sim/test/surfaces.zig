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
    h.ped(0).* = .{ .x = blk(43), .y = fx.fromInt(33), .z = z, .heading = 16384 };
    h.tap(0, Button.enter_exit);
    if (!eql(w.get(me, c.Riding).?.vehicle, car)) return error.TestNotBoarded;
    h.frames[0].throttle = 127;
    h.run(2);
    try std.testing.expect(w.get(car, c.Vehicle).?.flags & c.Vehicle.flag_in_water != 0);
    try std.testing.expect(fx.length(w.get(car, c.Velocity).?.vx, w.get(car, c.Velocity).?.vy) == 0);
    h.run(40);
    try std.testing.expect(!w.isAlive(car));
    try std.testing.expect(h.sim.pedOf(0) == null);
}
