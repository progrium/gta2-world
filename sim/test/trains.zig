//! Tests: trains (`sys/trains.zig`). A rail loop laid on the test map's
//! ground, one station, a small single-player config.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const testmap = h_.testmap;
const Frame = h_.Frame;
const EntityId = h_.EntityId;
const TV = @import("../tuning/vehicles.zig");

const cfg: abi.Config = .{ .name = "sp_train_test", .max_players = 1, .car_capacity = 16, .ped_capacity = 24, .projectile_capacity = 32, .pickup_capacity = 4, .map_object_capacity = 8 };
const Sp = simmod.Sim(cfg);

/// The loop: east along y 100 from x 100 to 130, south down x 130 to y
/// 110, west back along y 110, north up x 100.
const x0 = 100;
const x1 = 130;
const y0 = 100;
const y1 = 110;
const zones = [_]simmod.level.Zone{
    .{ .kind = .railway_station, .x = 112, .y = 98, .w = 5, .h = 2, .name = "trak00platform" },
    .{ .kind = .railway_station_entry, .x = 104, .y = y0, .w = 1, .h = 1, .name = "trak00entry" },
    .{ .kind = .railway_stop, .x = 115, .y = y0, .w = 1, .h = 1, .name = "trak00stop" },
    .{ .kind = .railway_station_exit, .x = 120, .y = y0, .w = 1, .h = 1, .name = "trak00exit" },
};
const lvl: simmod.Level = .{ .zones = &zones };

fn rail(g: *map.Grid, x: u32, y: u32, arrows: u4) void {
    map.set(g, x, y, 0, map.makeCell(map.Shape.solid, 0, map.Ground.field, arrows));
}

const H = struct {
    grid: *map.Grid,
    sim: *Sp,
    frames: [1]Frame = .{Frame.neutral(0)},

    fn init() !H {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        // Clear everything above the ground around the loop.
        for (y0 - 4..y1 + 5) |y| for (x0 - 4..x1 + 5) |x| {
            map.set(g, @intCast(x), @intCast(y), 0, map.makeCell(map.Shape.solid, 0, map.Ground.pavement, 0));
            for (1..map.size_z) |z| map.set(g, @intCast(x), @intCast(y), @intCast(z), 0);
        };
        for (x0..x1) |x| rail(g, @intCast(x), y0, map.Arrow.pos_x);
        for (y0..y1) |y| rail(g, x1, @intCast(y), map.Arrow.pos_y);
        for (x0 + 1..x1 + 1) |x| rail(g, @intCast(x), y1, map.Arrow.neg_x);
        for (y0 + 1..y1 + 1) |y| rail(g, x0, @intCast(y), map.Arrow.neg_y);
        const s = try std.testing.allocator.create(Sp);
        s.init(g, .{ .seed = 3, .mode = .authoritative });
        s.attachLevel(&lvl);
        var h: H = .{ .grid = g, .sim = s };
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(114, 98) }});
        h.run(1);
        return h;
    }
    fn deinit(h: *H) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    fn run(h: *H, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
    fn tr(h: *H, id: EntityId) c.Transform {
        return h.sim.state.world.get(id, c.Transform).?.*;
    }
    fn train(h: *H) *simmod.sp_state.trains.Train {
        return &h.sim.state.sp.trains.trains[0];
    }
};

test "trains: a declared train starts at its station's entry, runs, and waits at the stop" {
    var h = try H.init();
    defer h.deinit();
    const engine = Sp.trains.declare(h.sim, "trak00platform", 2, 0, 0).?;
    try std.testing.expectEqual(@as(u8, 3), h.train().count);
    // On the rail, east of the entry, heading east.
    const t0 = h.tr(engine);
    try std.testing.expectEqual(@as(i32, y0), fx.toInt(t0.y));
    try std.testing.expect(fx.toInt(t0.x) > 104);
    // The coaches trail behind, in a line.
    const c1 = h.tr(h.train().cars[1]);
    try std.testing.expect(c1.x < t0.x);
    try std.testing.expectEqual(@as(i32, y0), fx.toInt(c1.y));
    var waited = false;
    for (0..600) |_| {
        h.run(1);
        if (h.train().phase == 1) {
            waited = true;
            break;
        }
    }
    try std.testing.expect(waited);
    const ts = h.tr(engine);
    try std.testing.expectEqual(@as(i32, 115), fx.toInt(ts.x));
    try std.testing.expect(!Sp.trains.moving(h.sim, engine));
}

test "trains: the train goes round the loop with its carriages and stops again; a passenger rides" {
    var h = try H.init();
    defer h.deinit();
    _ = Sp.trains.declare(h.sim, "trak00platform", 1, 0, 1).?;
    // Wait for the stop, board the coach, and ride.
    for (0..600) |_| {
        h.run(1);
        if (h.train().phase == 1) break;
    }
    const coach = h.train().cars[1];
    h.sim.board(h.sim.pedOf(0).?, coach);
    var left = false;
    var turned = false;
    var back = false;
    for (0..4000) |_| {
        h.run(1);
        if (h.train().phase == 0) left = true;
        const t = h.tr(coach);
        if (fx.toInt(t.y) == y1) turned = true;
        if (left and turned and h.train().phase == 1) {
            back = true;
            break;
        }
        // Can't get off while it moves.
        if (h.train().phase == 0 and h.train().speed > 0) {
            h.sim.tryExit(h.sim.pedOf(0).?);
            try std.testing.expect(!h.sim.state.players[0].car.isNone());
        }
    }
    try std.testing.expect(back);
    // The passenger came round with it.
    const pt = h.tr(h.sim.pedOf(0).?);
    const ct = h.tr(coach);
    try std.testing.expect(@abs(pt.x - ct.x) < fx.one and @abs(pt.y - ct.y) < fx.one);
}

test "trains: a moving train blows up a car on the line and takes no damage" {
    var h = try H.init();
    defer h.deinit();
    const engine = Sp.trains.declare(h.sim, "trak00platform", 1, 0, 0).?;
    // Past the stop, on the line round the corner.
    const car = h.sim.spawnCarAt(fx.fromInt(x1) + fx.half, fx.fromInt(105) + fx.half, 16384, 0).?;
    var blown = false;
    for (0..2000) |_| {
        h.run(1);
        const v = h.sim.state.world.get(car, c.Vehicle);
        if (v == null or v.?.flags & c.Vehicle.flag_wrecked != 0) {
            blown = true;
            break;
        }
    }
    try std.testing.expect(blown);
    try std.testing.expectEqual(T.car_damage_max, h.sim.state.world.get(engine, c.Health).?.hp);
}
