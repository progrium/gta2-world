//! Tests: Traffic.

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

test "traffic follows its lane and brakes for a ped in the road" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // The +x lane of the road along y = 32..35 is y = 34..35.
    const car = h.sim.spawnCarAt(blk(37), blk(34), 0, 0).?;
    const w = &h.sim.state.world;
    const v = w.get(car, c.Vehicle).?;
    v.flags = c.Vehicle.flag_ai;
    v.ai_dir = 0;
    h.run(90);
    const t = h.sim.transformOf(car).?;
    try std.testing.expect(t.x > blk(44));
    try std.testing.expect(fx.abs(t.y - blk(34)) < fx.half);
    // A ped steps out ahead: the car stops short of them.
    h.join(0, @intCast(fx.toInt(t.x) + 4), 34);
    const ped = h.sim.pedOf(0).?;
    h.run(60);
    try std.testing.expectEqual(T.ped_hp, w.get(ped, c.Health).?.hp);
    try std.testing.expect(fx.length(w.get(car, c.Velocity).?.vx, w.get(car, c.Velocity).?.vy) < fx.ratio(1, 100));
    // Standing next to the stopped car, the player can take it (held
    // stopped while he runs to the door and pulls the driver out).
    v.halt = 200;
    h.ped(0).* = .{ .x = h.sim.transformOf(car).?.x, .y = blk(33), .z = h.ped(0).z, .heading = 0 };
    h.tap(0, Button.enter_exit);
    try std.testing.expect(eql(w.get(ped, c.Riding).?.vehicle, car));
    try std.testing.expect(v.flags & c.Vehicle.flag_ai == 0);
}
