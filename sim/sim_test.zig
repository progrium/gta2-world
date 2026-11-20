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
    const turns = @divTrunc(32768 + T.ped_tank_turn - 1, T.ped_tank_turn);
    h.run(@intCast(turns));
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
    // Run is faster than walk.
    const y1 = t.y;
    h.frames[0].buttons |= Button.run;
    h.run(5);
    try std.testing.expect(t.y - y1 > fx.mulAxis(T.ped_walk, 127) * 5);
}

test "walk up the 45 degree ramp onto the platform, then jump off" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, testmap.yard_x, testmap.yard_y + 4);
    const t = h.ped(0);
    h.frames[0].throttle = 127; // facing +x, toward the ramp
    h.run(60);
    try std.testing.expectEqual(fx.fromInt(2), t.z);
    try std.testing.expect(t.x > fx.fromInt(testmap.yard_x + 3));
    // Jump: leaves the floor, then lands again.
    h.frames[0].throttle = 0;
    h.frames[0].buttons = Button.handbrake_jump;
    h.run(2);
    try std.testing.expect(t.z > fx.fromInt(2));
    h.frames[0].buttons = 0;
    h.run(40);
    try std.testing.expectEqual(fx.fromInt(2), t.z);
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
    try std.testing.expectEqual(@as(i8, @intCast(T.carModel(0).pedal_rate)), w.get(car, c.Vehicle).?.pedal);
    h.run(59);
    const v = w.get(car, c.Velocity).?;
    try std.testing.expect(v.vx > fx.ratio(25, 100));
    try std.testing.expect(v.vx <= T.carModel(0).max_speed);
    try std.testing.expect(ct.x > x0 + fx.fromInt(8));
    // The rider follows the car.
    try std.testing.expectEqual(ct.x, h.ped(0).x);

    // Brake to a stop.
    h.frames[0].throttle = -127;
    h.run(25);
    try std.testing.expect(v.vx <= 0);
    h.frames[0].throttle = 0;
    h.run(30);
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
    // Keep heading south-ish into the city block: it must stop at a building
    // without any corner inside a wall.
    h.frames[0].throttle = 127;
    h.run(120);
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
    for (0..60) |_| {
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
    _ = a.sim.spawnCarAt(blk(61), fx.fromInt(35), 0, 0).?;
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
    // Firing in predict mode reports an intent instead of spawning.
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

test "bottomless columns act as walls; ceilings stop a jump" {
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
    var top: fx.Fx = 0;
    for (0..30) |_| {
        h.run(1);
        top = @max(top, t.z);
    }
    try std.testing.expect(top > fx.one);
    try std.testing.expect(top + map.body_height <= fx.fromInt(2) + T.ped_jump_vz);
}
