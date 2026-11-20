//! Tests: I1 conformance, save and load, predict mode, replicas, joining.

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

test "I1 conformance and layout" {
    comptime abi.checkSim(S);
    comptime abi.checkSim(simmod.Sim16);
    try std.testing.expect(simmod.Sim16.state_size < 256 * 1024);
    // Views locate the tick and the first ped's transform.
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, testmap.lo + 6, testmap.lo + 6);
    const bytes = h.sim.stateBytes();
    var found = false;
    for (S.views()) |v| {
        if (v.kind == @backingInt(abi.Kind.ped) and v.component == @backingInt(abi.ComponentId.transform)) {
            const id = h.sim.pedOf(0).?;
            const off = v.offset + v.stride * id.index();
            const t = std.mem.bytesToValue(abi.Transform, bytes[off..][0..@sizeOf(abi.Transform)]);
            try std.testing.expectEqual(h.ped(0).*, t);
            found = true;
        }
        if (v.component == abi.ColumnDesc.Special.tick)
            try std.testing.expectEqual(h.sim.tick(), std.mem.readInt(u32, bytes[v.offset..][0..4], .little));
    }
    try std.testing.expect(found);
}

test "join spawns on foot at the hint; leave clears the row" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(1, testmap.lo + 5, testmap.lo + 5);
    const row = h.sim.playerRow(1);
    try std.testing.expect(row.flags & abi.PlayerRow.flag_active != 0);
    try std.testing.expectEqual(fx.one, h.ped(1).z);
    try std.testing.expectEqual(blk(testmap.lo + 5), h.ped(1).x);
    h.sim.step(&h.frames, &.{.{ .op = .leave, .slot = 1, .arg = 0 }});
    try std.testing.expect(row.ped.isNone());
    try std.testing.expectEqual(@as(u32, 0), row.flags);
}

test "save, step, load, step gives identical hashes" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 35);
    h.join(1, 52, 56);
    _ = h.sim.spawnCarAt(blk(61), fx.fromInt(35), 0, 0).?;
    h.frames[0] = .{ .steer = 40, .throttle = 100, .buttons = Button.fire, .aim = 0, .seq = 0 };
    h.frames[1] = .{ .steer = 0, .throttle = 127, .buttons = Button.direct | Button.fire, .aim = 20000, .seq = 0 };
    h.run(20);
    var buf: [S.state_size]u8 = undefined;
    _ = h.sim.save(&buf);
    h.frames[0].buttons |= Button.enter_exit;
    h.run(50);
    const h1 = h.sim.hash();
    try h.sim.load(&buf);
    h.run(50);
    try std.testing.expectEqual(h1, h.sim.hash());
    try std.testing.expectError(error.BadSize, h.sim.load(buf[0..10]));
}

test "predict mode with everything predicted matches authoritative" {
    var a = try Harness.init(.authoritative);
    defer a.deinit();
    var p = try Harness.init(.predict);
    defer p.deinit();
    a.join(0, 60, 35);
    const car = a.sim.spawnCarAt(blk(61), fx.fromInt(35), 0, 0).?;
    a.run(2);
    // Hand the client the server's state and predict everything.
    var buf: [S.state_size]u8 = undefined;
    _ = a.sim.save(&buf);
    try p.sim.load(&buf);
    const w = &p.sim.state.world;
    w.each(.{c.Predicted}, {}, struct {
        fn f(_: void, _: abi.EntityId, pr: *c.Predicted) void {
            pr.on = 1;
        }
    }.f);
    // Mirror the flags on the server so the bytes match.
    a.sim.state.world.each(.{c.Predicted}, {}, struct {
        fn f(_: void, _: abi.EntityId, pr: *c.Predicted) void {
            pr.on = 1;
        }
    }.f);
    try std.testing.expectEqual(a.sim.hash(), p.sim.hash());
    var frames: [4]Frame = @splat(Frame.neutral(0));
    frames[0].buttons = Button.enter_exit;
    for (0..3) |i| {
        if (i == 1) frames[0] = .{ .steer = 30, .throttle = 127, .buttons = 0, .aim = 0, .seq = 0 };
        a.sim.step(&frames, &.{});
        p.sim.step(&frames, &.{});
    }
    for (0..60) |_| {
        a.sim.step(&frames, &.{});
        p.sim.step(&frames, &.{});
        try std.testing.expectEqual(a.sim.hash(), p.sim.hash());
    }
    // Firing in predict mode reports an intent instead of spawning. (Stop
    // the car first: nobody gets out above 0.3 a tick.)
    p.sim.state.world.get(car, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
    frames[0] = .{ .steer = 0, .throttle = 0, .buttons = Button.enter_exit, .aim = 0, .seq = 0 };
    p.sim.step(&frames, &.{});
    frames[0].buttons = Button.fire;
    for (0..3) |_| p.sim.step(&frames, &.{});
    try std.testing.expectEqual(@as(u32, 0), p.sim.state.world.count(S.Shot));
    try std.testing.expect(p.sim.scratch.stats.shots > 0);
}

test "predict mode leaves unpredicted entities alone" {
    var a = try Harness.init(.authoritative);
    defer a.deinit();
    var p = try Harness.init(.predict);
    defer p.deinit();
    a.join(0, 60, 35);
    a.join(1, 64, 35);
    var buf: [S.state_size]u8 = undefined;
    _ = a.sim.save(&buf);
    try p.sim.load(&buf);
    const own = p.sim.pedOf(0).?;
    p.sim.state.world.get(own, c.Predicted).?.on = 1;
    const other = p.sim.transformOf(p.sim.pedOf(1).?).?.*;
    var frames: [4]Frame = @splat(.{ .steer = 0, .throttle = 127, .buttons = 0, .aim = 0, .seq = 0 });
    for (0..10) |_| p.sim.step(&frames, &.{});
    try std.testing.expect(p.sim.transformOf(own).?.x > blk(60));
    try std.testing.expectEqual(other, p.sim.transformOf(p.sim.pedOf(1).?).?.*);
}

test "replicaPut and replicaRemove" {
    var p = try Harness.init(.predict);
    defer p.deinit();
    const id = abi.EntityId.make(.car, 5, 3);
    try std.testing.expect(p.sim.replicaPut(id));
    try std.testing.expect(p.sim.state.world.isAlive(id));
    p.sim.state.world.get(id, c.Transform).?.x = 99;
    try std.testing.expect(p.sim.replicaPut(id)); // same generation: kept
    try std.testing.expectEqual(@as(fx.Fx, 99), p.sim.state.world.get(id, c.Transform).?.x);
    p.sim.replicaRemove(id);
    try std.testing.expect(!p.sim.state.world.isAlive(id));
    try std.testing.expect(!p.sim.replicaPut(abi.EntityId.make(.car, 4000, 0)));
}

test "dm16 session with ambient population runs and stays deterministic" {
    const S16 = simmod.Sim16;
    const g = try std.testing.allocator.create(map.Grid);
    defer std.testing.allocator.destroy(g);
    testmap.build(g);
    const s1 = try std.testing.allocator.create(S16);
    defer std.testing.allocator.destroy(s1);
    const s2 = try std.testing.allocator.create(S16);
    defer std.testing.allocator.destroy(s2);
    s1.init(g, .{ .seed = 99, .mode = .authoritative });
    s2.init(g, .{ .seed = 99, .mode = .authoritative });
    try std.testing.expectEqual(@as(u32, simmod.config_16.ambient_cars), s1.state.world.count(S16.Car));
    try std.testing.expectEqual(@as(u32, simmod.config_16.ambient_peds), s1.state.world.count(S16.Ped));
    var cmds: [16]abi.Command = undefined;
    for (&cmds, 0..) |*cm, i| cm.* = .{ .op = .join, .slot = @intCast(i), .arg = 0 };
    var frames: [16]Frame = @splat(.{ .steer = 20, .throttle = 127, .buttons = Button.fire, .aim = 0, .seq = 0 });
    s1.step(&frames, &cmds);
    s2.step(&frames, &cmds);
    for (0..300) |_| {
        s1.step(&frames, &.{});
        s2.step(&frames, &.{});
    }
    try std.testing.expectEqual(s1.hash(), s2.hash());
    // Ambient peds stay on the map (none fell through the floor).
    var below: u32 = 0;
    s1.state.world.each(.{ c.Pedestrian, c.Transform }, &below, struct {
        fn f(n: *u32, _: abi.EntityId, _: *c.Pedestrian, t: *c.Transform) void {
            if (t.z < fx.one) n.* += 1;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 0), below);
}

test "a player joining without a hint spawns near someone already playing" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    // Seat slot 0 somewhere on the test map, then let several others join
    // with no hint: each lands on pavement near an active player.
    h.join(0, 52, 56);
    const p0 = h.sim.transformOf(h.sim.pedOf(0).?).?.*;
    var joined: u8 = 0;
    for (1..4) |slot| {
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = @intCast(slot), .arg = 0 }});
        const id = h.sim.pedOf(@intCast(slot)) orelse continue;
        const t = h.sim.transformOf(id).?.*;
        const d = @max(@abs(fx.toInt(t.x) - fx.toInt(p0.x)), @abs(fx.toInt(t.y) - fx.toInt(p0.y)));
        try std.testing.expect(d <= T.spawn_near_radius and d >= T.spawn_near_min);
        joined += 1;
    }
    try std.testing.expect(joined == 3);
}

test "players joining in the same tick spawn near the first of them" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    var joins: [4]abi.Command = undefined;
    for (&joins, 0..) |*j, i| j.* = .{ .op = .join, .slot = @intCast(i), .arg = 0 };
    h.sim.step(&h.frames, &joins);
    const p0 = h.sim.transformOf(h.sim.pedOf(0).?).?.*;
    for (1..4) |slot| {
        const t = h.sim.transformOf(h.sim.pedOf(@intCast(slot)).?).?.*;
        const d = @max(@abs(fx.toInt(t.x) - fx.toInt(p0.x)), @abs(fx.toInt(t.y) - fx.toInt(p0.y)));
        try std.testing.expect(d <= T.spawn_near_radius and d >= T.spawn_near_min);
    }
}
