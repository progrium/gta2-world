//! Tests: Frags and points.

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

test "first to the frag limit ends the round and every score resets" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    h.join(1, 36, 44);
    const pl = &h.sim.state.players;
    pl[0].kills = T.frag_limit - 1;
    pl[0].score = 12345;
    pl[1].deaths = 3;
    const w = &h.sim.state.world;
    const victim = w.get(h.sim.pedOf(1).?, c.Health).?;
    victim.hp = 0;
    victim.last_hit_by = h.sim.pedOf(0).?;
    h.run(1);
    try std.testing.expect(hasEvent(h.sim.events(), .round_end));
    try std.testing.expect(hasEvent(h.sim.events(), .kill));
    try std.testing.expectEqual(@as(i32, 0), pl[0].score);
    try std.testing.expectEqual(@as(i32, 0), pl[0].kills);
    // The victim's death is counted after the reset.
    try std.testing.expectEqual(@as(i32, 1), pl[1].deaths);
}

test "points: civilian kills build a combo, hijacks and wrecks pay the car's value" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    const w = &h.sim.state.world;
    const me = h.sim.pedOf(0).?;
    const row = &h.sim.state.players[0];
    const killOne = struct {
        fn f(hh: *Harness, by: EntityId) void {
            const v = hh.sim.spawnPed(c.Controller.no_player, simmod.spawnHint(30, 40)).?;
            const vh = hh.sim.state.world.get(v, c.Health).?;
            vh.hp = 0;
            vh.last_hit_by = by;
            hh.run(2); // a new entity joins the world at the end of a step
        }
    }.f;
    // Three quick kills: x1, x2, x3; after a pause the combo is back to 1.
    killOne(&h, me);
    try std.testing.expectEqual(T.points_civilian, row.score);
    killOne(&h, me);
    killOne(&h, me);
    try std.testing.expectEqual(T.points_civilian * 6, row.score);
    h.run(T.combo_window + 1);
    killOne(&h, me);
    try std.testing.expectEqual(T.points_civilian * 7, row.score);
    try std.testing.expectEqual(@as(i32, 0), row.kills);
    // Run over from a car you drive: half.
    const car = h.sim.spawnCarAt(blk(40), blk(34), 0, 0).?;
    w.get(car, c.Vehicle).?.driver = me;
    h.run(T.combo_window + 1);
    killOne(&h, car);
    try std.testing.expectEqual(T.points_civilian * 7 + T.points_civilian / 2, row.score);
    w.get(car, c.Vehicle).?.driver = .none;
    // A traffic car taken: its value.
    const before = row.score;
    const traffic = h.sim.spawnCarAt(blk(36), blk(41), 0, 0).?;
    w.get(traffic, c.Vehicle).?.flags = c.Vehicle.flag_ai;
    w.get(traffic, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
    h.ped(0).* = .{ .x = blk(36), .y = blk(40), .z = h.ped(0).z, .heading = 16384 };
    h.tap(0, Button.enter_exit);
    try std.testing.expect(eql(w.get(me, c.Riding).?.vehicle, traffic));
    try std.testing.expectEqual(before + T.default_car_value, row.score);
    // A car destroyed by you: value x 5 (and nothing for your own car).
    const parked = h.sim.spawnCarAt(blk(48), blk(34), 0, 0).?;
    const ph = w.get(parked, c.Health).?;
    ph.hp = 0;
    ph.last_hit_by = me;
    h.run(1);
    try std.testing.expect(row.score >= before + T.default_car_value * (1 + T.destroy_value_factor));
}
