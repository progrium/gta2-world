//! Gameplay and contract tests on the synthetic test map.

const std = @import("std");
const simmod = @import("sim.zig");
const abi = simmod.abi;
const input = simmod.input;
const fx = simmod.fx;
const map = simmod.map;
const c = simmod.c;
const T = simmod.tuning;
const testmap = simmod.testmap;
const Button = input.Button;
const Frame = input.Frame;

/// Small config: no ambient population, so tests control everything.
const cfg_small: abi.Config = .{ .name = "test", .max_players = 4, .car_capacity = 8, .ped_capacity = 16, .projectile_capacity = 16, .pickup_capacity = 4, .map_object_capacity = 4 };
const S = simmod.Sim(cfg_small);

const Harness = struct {
    grid: *map.Grid,
    sim: *S,
    frames: [cfg_small.max_players]Frame = @splat(Frame.neutral(0)),

    fn init(mode: abi.Mode) !Harness {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(S);
        s.init(g, .{ .seed = 7, .mode = mode });
        return .{ .grid = g, .sim = s };
    }
    fn deinit(h: *Harness) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    fn join(h: *Harness, slot: u8, bx: u8, by: u8) void {
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = slot, .arg = simmod.spawnHint(bx, by) }});
    }
    fn run(h: *Harness, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
    fn ped(h: *Harness, slot: u32) *c.Transform {
        return h.sim.transformOf(h.sim.pedOf(slot).?).?;
    }
    fn tap(h: *Harness, slot: u32, b: u16) void {
        h.frames[slot].buttons |= b;
        h.run(1);
        h.frames[slot].buttons &= ~b;
        h.run(1);
    }
};

fn blk(i: i32) fx.Fx {
    return fx.fromInt(i) + fx.half;
}

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
        if (v.kind == @intFromEnum(abi.Kind.ped) and v.component == @intFromEnum(abi.ComponentId.transform)) {
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

fn hasEvent(evs: anytype, kind: anytype) bool {
    for (evs) |e| if (e.kind == kind) return true;
    return false;
}

test "pickups give weapons; the machine gun runs dry back to the pistol" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    const ped = h.sim.pedOf(0).?;
    const wpn = h.sim.state.world.get(ped, c.Weapon).?;
    try std.testing.expectEqual(T.weapon_pistol, wpn.kind);
    // weapon_next with only the pistol keeps the pistol.
    h.tap(0, Button.weapon_next);
    try std.testing.expectEqual(T.weapon_pistol, wpn.kind);
    const t = h.ped(0).*;
    _ = h.sim.spawnPickupAt(t.x, t.y, T.weapon_smg).?;
    h.run(1);
    try std.testing.expect(hasEvent(h.sim.events(), .pickup));
    try std.testing.expectEqual(T.weapon_smg, wpn.kind);
    try std.testing.expectEqual(T.weapons[T.weapon_smg].pickup_rounds * 10, wpn.rounds()[T.weapon_smg]);
    try std.testing.expectEqual(@as(u32, 0), h.sim.state.world.count(S.Pickup));
    // Cycling goes to the pistol and back.
    h.tap(0, Button.weapon_next);
    try std.testing.expectEqual(T.weapon_pistol, wpn.kind);
    h.tap(0, Button.weapon_prev);
    try std.testing.expectEqual(T.weapon_smg, wpn.kind);
    // Empty the machine gun (into the building next door).
    h.frames[0].buttons = Button.fire;
    const smg = T.weapons[T.weapon_smg];
    h.run(@as(u32, smg.cooldown) * smg.pickup_rounds * 10 / smg.tenths_per_pull + 10);
    h.frames[0].buttons = 0;
    try std.testing.expectEqual(@as(u16, 0), wpn.rounds()[T.weapon_smg]);
    try std.testing.expectEqual(T.weapon_pistol, wpn.kind);
    // A health pack is left when not needed.
    _ = h.sim.spawnPickupAt(t.x, t.y, T.pickup_health).?;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 1), h.sim.state.world.count(S.Pickup));
    // A new weapon goes into the hand even when another one is held.
    wpn.rounds()[T.weapon_smg] = 50;
    wpn.kind = T.weapon_smg;
    _ = h.sim.spawnPickupAt(t.x + fx.one / 4, t.y, T.weapon_shotgun).?;
    h.run(1);
    try std.testing.expectEqual(T.weapon_shotgun, wpn.kind);
    // More rounds for a weapon you have leave the hand alone.
    _ = h.sim.spawnPickupAt(t.x + fx.one / 4, t.y, T.weapon_smg).?;
    h.run(1);
    try std.testing.expectEqual(T.weapon_shotgun, wpn.kind);
}

test "a rocket kills another player and credits the shooter; your own costs a point" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.join(1, 33, 66);
    const w = &h.sim.state.world;
    const ped0 = h.sim.pedOf(0).?;
    h.ped(0).heading = 16384; // down the road toward slot 1
    const wpn = w.get(ped0, c.Weapon).?;
    wpn.rounds()[T.weapon_rocket] = 40;
    wpn.kind = T.weapon_rocket;
    h.frames[0].buttons = Button.fire;
    h.run(1);
    h.frames[0].buttons = 0;
    var saw_kill = false;
    for (0..90) |_| {
        h.run(1);
        for (h.sim.events()) |e| {
            if (e.kind == .kill) {
                try std.testing.expectEqual(@as(u8, 0), e.a);
                try std.testing.expectEqual(@as(u8, 1), e.b);
                try std.testing.expectEqual(T.weapon_rocket, e.c);
                saw_kill = true;
            }
        }
    }
    try std.testing.expect(saw_kill);
    try std.testing.expect(h.sim.scratch.stats.explosions >= 1);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[0].kills);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[0].score);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[1].deaths);
    // Now point-blank at a building wall: the blast kills the shooter.
    const t0 = h.ped(0);
    // Within half the blast radius a player is killed (further out, but
    // inside it, only knocked down).
    t0.x = fx.fromInt(37) + fx.ratio(3, 4);
    t0.y = blk(41);
    t0.heading = 0; // +x: building wall at x = 38
    h.frames[0].buttons = Button.fire;
    h.run(1);
    h.frames[0].buttons = 0;
    h.run(60);
    try std.testing.expect(h.sim.pedOf(0) == null);
    try std.testing.expectEqual(@as(i32, 0), h.sim.state.players[0].score);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[0].kills);
}

test "a shot-up car catches fire, explodes and burns out" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 61);
    const car = h.sim.spawnCarAt(blk(33), fx.fromInt(60) + fx.ratio(3, 10), 0, 0).?;
    const w = &h.sim.state.world;
    // Damage at the larger fire: it burns on by itself until it explodes.
    w.get(car, c.Health).?.hp = T.car_damage_max - T.car_fire2_damage;
    h.run(1);
    const v = w.get(car, c.Vehicle).?;
    try std.testing.expect(v.flags & c.Vehicle.flag_burning != 0);
    var ticks: u32 = 0;
    while (v.flags & c.Vehicle.flag_wrecked == 0 and ticks < 200) : (ticks += 1) h.run(1);
    try std.testing.expect(v.flags & c.Vehicle.flag_wrecked != 0);
    try std.testing.expectEqual(@as(u64, 1), h.sim.scratch.stats.explosions);
    // The player 1.2 blocks away (inside twice the radius) is knocked over,
    // then gets up; the wreck cannot be entered.
    const ped = h.sim.pedOf(0).?;
    h.run(2);
    try std.testing.expectEqual(c.Pedestrian.state_over, w.get(ped, c.Pedestrian).?.state);
    h.run(60);
    try std.testing.expectEqual(c.Pedestrian.state_up, w.get(ped, c.Pedestrian).?.state);
    try std.testing.expectEqual(T.ped_hp, w.get(ped, c.Health).?.hp);
    h.ped(0).* = .{ .x = blk(33), .y = blk(61), .z = h.ped(0).z, .heading = 16384 * 3 };
    h.tap(0, Button.enter_exit);
    try std.testing.expect(w.get(ped, c.Riding).?.vehicle.isNone());
    h.run(T.wreck_ticks + 2);
    try std.testing.expect(!w.isAlive(car));
}

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
    // Standing next to the stopped car, the player can take it.
    h.ped(0).* = .{ .x = h.sim.transformOf(car).?.x, .y = blk(33), .z = h.ped(0).z, .heading = 0 };
    h.tap(0, Button.enter_exit);
    try std.testing.expect(eql(w.get(ped, c.Riding).?.vehicle, car));
    try std.testing.expect(v.flags & c.Vehicle.flag_ai == 0);
}

const eql = simmod.ecs.eql;

test "first to the frag limit ends the round and every score resets" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    h.join(1, 36, 44);
    const pl = &h.sim.state.players;
    pl[0].kills = T.frag_limit - 1;
    pl[0].score = T.frag_limit - 1;
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


fn arm(h: *Harness, slot: u32, k: u8, tenths: u16) *c.Weapon {
    const wpn = h.sim.state.world.get(h.sim.pedOf(slot).?, c.Weapon).?;
    wpn.rounds()[k] = tenths;
    wpn.kind = k;
    return wpn;
}

fn shotCount(h: *Harness) u32 {
    return h.sim.state.world.count(S.Shot);
}

test "dual pistols fire two bullets; fast reload halves the wait" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.ped(0).heading = 16384;
    const wpn = arm(&h, 0, T.weapon_dual_pistol, 100);
    h.frames[0].buttons = Button.fire;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 2), shotCount(&h));
    try std.testing.expectEqual(@as(u16, 90), wpn.rounds()[T.weapon_dual_pistol]);
    try std.testing.expectEqual(T.weapons[T.weapon_dual_pistol].cooldown, wpn.cooldown);
    h.frames[0].buttons = 0;
    h.run(30);
    h.sim.state.world.get(h.sim.pedOf(0).?, c.Pedestrian).?.fast_reload = T.fast_reload_ticks;
    h.frames[0].buttons = Button.fire;
    h.run(1);
    try std.testing.expectEqual(T.weapons[T.weapon_dual_pistol].cooldown / 2, wpn.cooldown);
}

test "a held grenade is thrown on release and goes off on its fuse" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.ped(0).heading = 16384;
    const wpn = arm(&h, 0, T.weapon_grenade, 30);
    h.frames[0].buttons = Button.fire;
    h.run(40);
    try std.testing.expectEqual(@as(u32, 0), shotCount(&h));
    h.frames[0].buttons = 0;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 1), shotCount(&h));
    try std.testing.expectEqual(@as(u16, 20), wpn.rounds()[T.weapon_grenade]);
    const y0 = h.ped(0).y;
    const before = h.sim.scratch.stats.explosions;
    h.run(T.grenadeFuse(40) + 2);
    try std.testing.expectEqual(before + 1, h.sim.scratch.stats.explosions);
    _ = y0;
    // Held to 96, the next one goes off in the hand.
    h.frames[0].buttons = Button.fire;
    h.run(T.grenade_in_hand + 1);
    h.frames[0].buttons = 0;
    h.run(1);
    try std.testing.expectEqual(before + 2, h.sim.scratch.stats.explosions);
    try std.testing.expectEqual(@as(u16, 10), wpn.rounds()[T.weapon_grenade]);
}

test "a molotov bursts into a fire that sets people alight" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 56);
    h.join(1, 33, 59);
    h.ped(0).heading = 16384; // toward slot 1
    _ = arm(&h, 0, T.weapon_molotov, 30);
    h.frames[0].buttons = Button.fire;
    h.run(20);
    h.frames[0].buttons = 0;
    // Find the fire once the bottle lands, and walk slot 1 into it.
    var fire: ?c.Transform = null;
    for (0..200) |_| {
        h.run(1);
        const Ctx = struct { out: *?c.Transform };
        h.sim.state.world.each(.{ c.Transform, c.Projectile }, Ctx{ .out = &fire }, struct {
            fn f(cx: Ctx, _: abi.EntityId, t: *c.Transform, p: *c.Projectile) void {
                if (p.weapon == c.Projectile.explosion_bit | T.explosion_fire) cx.out.* = t.*;
            }
        }.f);
        if (fire != null) break;
    }
    const f = fire orelse return error.NoFire;
    try std.testing.expect(f.y > h.ped(0).y + fx.fromInt(2));
    h.ped(1).* = .{ .x = f.x, .y = f.y, .z = f.z, .heading = 0 };
    h.run(2);
    const p1 = h.sim.pedOf(1).?;
    try std.testing.expect(h.sim.state.world.get(p1, c.Pedestrian).?.burn > 0);
    h.run(10);
    try std.testing.expect(h.sim.state.world.get(p1, c.Health).?.hp < T.ped_hp);
}

test "the flamethrower sets a target on fire and burning hurts" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.join(1, 33, 61);
    h.ped(0).heading = 16384;
    h.ped(1).* = .{ .x = h.ped(0).x, .y = h.ped(0).y + fx.ratio(8, 10), .z = h.ped(0).z, .heading = 0 };
    _ = arm(&h, 0, T.weapon_flamethrower, 200);
    h.frames[0].buttons = Button.fire;
    h.run(4);
    h.frames[0].buttons = 0;
    const p1 = h.sim.pedOf(1).?;
    try std.testing.expect(h.sim.state.world.get(p1, c.Pedestrian).?.burn > 0);
    const hp = h.sim.state.world.get(p1, c.Health).?.hp;
    h.run(10);
    try std.testing.expect(h.sim.state.world.get(p1, c.Health).?.hp < hp);
}

test "the electro gun shocks a target to death and chains" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.join(1, 33, 62);
    h.ped(0).heading = 16384;
    h.ped(1).* = .{ .x = h.ped(0).x, .y = h.ped(0).y + fx.ratio(15, 10), .z = h.ped(0).z, .heading = 0 };
    _ = arm(&h, 0, T.weapon_electro, 500);
    h.frames[0].buttons = Button.fire;
    var died = false;
    for (0..40) |_| {
        h.run(1);
        if (h.sim.state.players[1].deaths > 0) died = true;
    }
    try std.testing.expect(died);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[0].kills);
}

test "armour soaks whole hits; invulnerability ignores them; double damage doubles" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.join(1, 33, 62);
    h.ped(0).heading = 16384;
    const p1 = h.sim.pedOf(1).?;
    const w = &h.sim.state.world;
    const ped1 = w.get(p1, c.Pedestrian).?;
    const hp1 = w.get(p1, c.Health).?;
    const shoot = struct {
        fn f(hh: *Harness) void {
            hh.ped(1).* = .{ .x = hh.ped(0).x, .y = hh.ped(0).y + fx.ratio(15, 10), .z = hh.ped(0).z, .heading = 0 };
            const wp = hh.sim.state.world.get(hh.sim.pedOf(0).?, c.Weapon).?;
            wp.cooldown = 0;
            hh.frames[0].buttons = Button.fire;
            hh.run(1);
            hh.frames[0].buttons = 0;
            hh.run(12);
        }
    }.f;
    _ = arm(&h, 0, T.weapon_smg, 100);
    ped1.armour = 2;
    shoot(&h);
    try std.testing.expectEqual(@as(u8, 1), ped1.armour);
    try std.testing.expectEqual(T.ped_hp, hp1.hp);
    ped1.armour = 0;
    ped1.invulnerable = 100;
    shoot(&h);
    try std.testing.expectEqual(T.ped_hp, hp1.hp);
    ped1.invulnerable = 0;
    shoot(&h);
    try std.testing.expectEqual(T.ped_hp - T.weapons[T.weapon_smg].damage_player, hp1.hp);
    w.get(h.sim.pedOf(0).?, c.Pedestrian).?.double_damage = 100;
    shoot(&h);
    try std.testing.expectEqual(T.ped_hp - 3 * T.weapons[T.weapon_smg].damage_player, hp1.hp);
    // Power-up pickups: refused when full.
    const t = h.ped(1).*;
    _ = h.sim.spawnPickupAt(t.x, t.y, T.pickup_armour).?;
    h.run(1);
    try std.testing.expectEqual(T.armour_charges, ped1.armour);
    _ = h.sim.spawnPickupAt(t.x, t.y, T.pickup_armour).?;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 1), w.count(S.Pickup));
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
