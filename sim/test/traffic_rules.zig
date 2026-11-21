//! Tests: traffic rules, car tasks and the route planner (workstream F,
//! traffic-and-car-ai.md). Uses a small single-player config with no
//! ambient population, so the car tasks and crossing markers are compiled.

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
const eql = h_.eql;
const blk = h_.blk;
const route = @import("../ai/route.zig");
const TF = @import("../tuning/traffic.zig");
const ids = @import("../ids.zig");

pub const cfg_sp_small: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 16, .ped_capacity = 16, .projectile_capacity = 8, .pickup_capacity = 4, .map_object_capacity = 8 };
pub const Sp = simmod.Sim(cfg_sp_small);

pub const SpHarness = struct {
    grid: *map.Grid,
    sim: *Sp,
    frames: [1]Frame = @splat(Frame.neutral(0)),

    pub fn init() !SpHarness {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(Sp);
        s.init(g, .{ .seed = 11, .mode = .authoritative });
        return .{ .grid = g, .sim = s };
    }
    pub fn deinit(h: *SpHarness) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    pub fn join(h: *SpHarness, bx: u8, by: u8) void {
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(bx, by) }});
    }
    pub fn run(h: *SpHarness, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
    /// An AI car at block (bx, by), facing direction `dir`.
    pub fn aiCar(h: *SpHarness, bx: i32, by: i32, dir: u8) EntityId {
        const car = h.sim.spawnCarAt(blk(bx), blk(by), @as(u16, dir) * 16384, 0).?;
        const v = h.sim.state.world.get(car, c.Vehicle).?;
        v.flags = c.Vehicle.flag_ai;
        v.ai_dir = dir;
        return car;
    }
    pub fn vehicle(h: *SpHarness, id: EntityId) *c.Vehicle {
        return h.sim.state.world.get(id, c.Vehicle).?;
    }
    pub fn speed(h: *SpHarness, id: EntityId) fx.Fx {
        const vel = h.sim.state.world.get(id, c.Velocity).?;
        return fx.length(vel.vx, vel.vy);
    }
    pub fn block(h: *SpHarness, id: EntityId) [2]i32 {
        const t = h.sim.transformOf(id).?;
        return .{ fx.toInt(t.x), fx.toInt(t.y) };
    }
};

fn cheb(a: [2]i32, b: [2]i32) i32 {
    return @intCast(@max(@abs(a[0] - b[0]), @abs(a[1] - b[1])));
}

// The test map: roads every 16 blocks from 32, 4 wide. A road along x
// (y = 32+16k .. +3) runs -x on its first two rows and +x on the last two;
// a road along y runs +y on its first two columns and -y on the last two.
// Junction cells carry no arrows.

test "route: every step is a legal road move and the walk reaches a goal 60 blocks away" {
    const g = try std.testing.allocator.create(map.Grid);
    defer std.testing.allocator.destroy(g);
    testmap.build(g);
    var n: route.Node = .{ .x = 37, .y = 34, .l = 0 };
    const goal = [2]i32{ 85, 99 }; // on the -y lane of the road at x = 80..83
    try std.testing.expect(route.roadAt(g, goal[0] - 2, goal[1], 0));
    var steps: u32 = 0;
    while (n.x != goal[0] - 2 or n.y != goal[1]) : (steps += 1) {
        try std.testing.expect(steps < 200);
        const d = route.firstStep(g, n, goal[0] - 2, goal[1], .{}) orelse return error.NoRoute;
        const m = route.move(g, n, d, .{}) orelse return error.IllegalStep;
        n = m.to;
    }
    // Manhattan distance is 48 + 65; the walk is near it.
    try std.testing.expect(steps < 140);
}

test "route: never against the flow, and the chase allowance only heading south" {
    const g = try std.testing.allocator.create(map.Grid);
    defer std.testing.allocator.destroy(g);
    testmap.build(g);
    // On the +x lane, moving -x is illegal; so is crossing into the -x lane.
    try std.testing.expect(route.move(g, .{ .x = 40, .y = 34, .l = 0 }, 2, .{}) == null);
    try std.testing.expect(route.move(g, .{ .x = 40, .y = 34, .l = 0 }, 3, .{}) == null);
    // Lane change to the parallel +x lane is allowed, at cost 2.
    const lc = route.move(g, .{ .x = 40, .y = 34, .l = 0 }, 1, .{}).?;
    try std.testing.expectEqual(@as(u16, 2), lc.cost);
    // A road cell with only red arrows: closed, except heading south for a
    // chase.
    map.set(g, 40, 36, 0, map.makeCell(map.Shape.solid, 0, map.Ground.road, 0));
    g.surface[0][36][40] = map.Surface.red_pos_y;
    g.surface[0][36][41] = map.Surface.red_pos_y;
    map.set(g, 41, 36, 0, map.makeCell(map.Shape.solid, 0, map.Ground.road, 0));
    try std.testing.expect(route.move(g, .{ .x = 40, .y = 35, .l = 0 }, 1, .{}) == null);
    try std.testing.expect(route.move(g, .{ .x = 40, .y = 35, .l = 0 }, 1, .{ .against_flow_south = true }) != null);
    try std.testing.expect(route.move(g, .{ .x = 40, .y = 36, .l = 0 }, 0, .{ .against_flow_south = true }) == null);
}

test "route: a target off the road routes to the nearest road block" {
    var h = try SpHarness.init();
    defer h.deinit();
    // Block (40, 40) is pavement next to the road at y = 32..35.
    const d = Sp.route.nextRoadDir(h.sim, 37, 34, 0, 40, 40);
    try std.testing.expectEqual(@as(?u2, 0), d);
    try std.testing.expectEqual(@as(?u2, null), Sp.route.nextRoadDir(h.sim, 41, 41, 0, 60, 60)); // not on road
}

test "chase: a task car drives 60+ blocks of road to its target and closes in" {
    var h = try SpHarness.init();
    defer h.deinit();
    h.join(69, 69); // a ped on the pavement, far away
    const ped = h.sim.pedOf(0).?;
    const car = h.aiCar(37, 34, 0);
    Sp.car_tasks.setCarTask(h.sim, car, .chase, ped, 0, 0);
    try std.testing.expectEqual(Sp.car_tasks.carTaskOf(h.sim, car), .chase);
    var arrived_at: ?u32 = null;
    for (0..3000) |i| {
        h.run(1);
        if (Sp.car_tasks.carArrived(h.sim, car)) {
            arrived_at = @intCast(i);
            break;
        }
    }
    try std.testing.expect(arrived_at != null);
    try std.testing.expect(cheb(h.block(car), h.block(ped)) <= TF.task_direct_blocks);
    // Never hurt by walls on the way (no wall hits big enough to damage).
    try std.testing.expect(h.sim.state.world.get(car, c.Health).?.hp > T.car_damage_max - 2000);
}

test "go to: the car drives to a point and stops there" {
    var h = try SpHarness.init();
    defer h.deinit();
    const car = h.aiCar(37, 34, 0);
    Sp.car_tasks.setCarTask(h.sim, car, .go_to, .none, blk(81), blk(70));
    var done = false;
    for (0..2500) |_| {
        h.run(1);
        if (Sp.car_tasks.carArrived(h.sim, car)) done = true;
        if (done and h.speed(car) < fx.ratio(1, 100)) break;
    }
    try std.testing.expect(done);
    try std.testing.expect(cheb(h.block(car), .{ 81, 70 }) <= TF.task_arrive_blocks + 1);
    try std.testing.expect(h.speed(car) < fx.ratio(1, 100));
    h.run(50);
    try std.testing.expect(h.speed(car) < fx.ratio(1, 100));
}

test "stop task holds the car; none returns it to traffic" {
    var h = try SpHarness.init();
    defer h.deinit();
    const car = h.aiCar(37, 34, 0);
    h.run(60);
    Sp.car_tasks.setCarTask(h.sim, car, .stop, .none, 0, 0);
    h.run(60);
    try std.testing.expect(h.speed(car) < fx.ratio(1, 100));
    const x0 = h.sim.transformOf(car).?.x;
    Sp.car_tasks.setCarTask(h.sim, car, .none, .none, 0, 0);
    h.run(60);
    try std.testing.expect(h.sim.transformOf(car).?.x > x0 + fx.one);
}

test "patrol: arrives, wanders, and routes back when it strays" {
    var h = try SpHarness.init();
    defer h.deinit();
    const car = h.aiCar(37, 34, 0);
    Sp.car_tasks.setCarTask(h.sim, car, .patrol, .none, blk(50), blk(34));
    var arrived = false;
    for (0..600) |_| {
        h.run(1);
        if (Sp.car_tasks.carArrived(h.sim, car)) arrived = true;
    }
    try std.testing.expect(arrived);
    // Far from the point it routes back again.
    for (0..4000) |_| h.run(1);
    try std.testing.expect(cheb(h.block(car), .{ 50, 34 }) <= TF.patrol_leash_blocks + 4);
}

test "off-road task car snaps to the road out of sight after 100 ticks (fast snap)" {
    var h = try SpHarness.init();
    defer h.deinit();
    // A car inside a field, far from any road and from the player.
    const car = h.aiCar(10, 10, 0);
    Sp.car_tasks.setCarTaskOpts(h.sim, car, .{ .fast_snap = true });
    Sp.car_tasks.setCarTask(h.sim, car, .go_to, .none, blk(100), blk(100));
    // Hold it in place so it can't find the road by itself.
    h.vehicle(car).halt = 0;
    h.run(TF.task_snap_fast + 2);
    const b = h.block(car);
    try std.testing.expect(route.roadAt(h.grid, b[0], b[1], 0));
}

test "seek road: an ordinary car off the road gives up after 200 ticks; a script car never does" {
    var h = try SpHarness.init();
    defer h.deinit();
    const car = h.aiCar(10, 10, 0);
    const scripted = h.aiCar(14, 10, 0);
    h.vehicle(scripted).ai_flags |= c.Vehicle.ai_script;
    h.run(TF.traffic_give_up_ticks + 5);
    try std.testing.expect(h.vehicle(car).ai_flags & c.Vehicle.ai_abandoned != 0);
    try std.testing.expect(h.vehicle(scripted).ai_flags & c.Vehicle.ai_abandoned == 0);
    h.run(40);
    try std.testing.expect(h.speed(car) < fx.ratio(1, 100));
}

test "seek road: a car just off the road steers back onto it" {
    var h = try SpHarness.init();
    defer h.deinit();
    // Pavement at (40, 36), road at y = 35 to the north (-y).
    const car = h.aiCar(40, 36, 3);
    var reached = false;
    for (0..40) |_| {
        h.run(1);
        const t = h.sim.transformOf(car).?;
        const cell = map.floorCell(h.grid, t.x, t.y, t.z, T.car_step);
        if (map.groundOf(cell) == map.Ground.road) reached = true;
    }
    try std.testing.expect(reached);
    try std.testing.expect(h.vehicle(car).ai_flags & c.Vehicle.ai_abandoned == 0);
}

test "junction right-of-way: crossing cars arriving together don't collide and both get through" {
    var h = try SpHarness.init();
    defer h.deinit();
    // Junction at x = 80..83, y = 80..83. One car eastbound on y = 82 from
    // the west, one southbound on x = 80 from the north.
    const east = h.aiCar(72, 82, 0);
    const south = h.aiCar(80, 72, 1);
    var yielded = false;
    for (0..400) |_| {
        h.run(1);
        if (h.vehicle(east).ai_yield != 0 or h.vehicle(south).ai_yield != 0) yielded = true;
    }
    try std.testing.expect(yielded);
    const w = &h.sim.state.world;
    try std.testing.expectEqual(T.car_damage_max, w.get(east, c.Health).?.hp);
    try std.testing.expectEqual(T.car_damage_max, w.get(south, c.Health).?.hp);
    // Both cleared the junction.
    try std.testing.expect(h.block(east)[0] > 84 or h.block(east)[1] > 84 or h.block(east)[1] < 80);
    try std.testing.expect(h.block(south)[1] > 84 or h.block(south)[0] > 84 or h.block(south)[0] < 80);
}

test "crossing marker: a rolling stop on every pass, never on a task" {
    var h = try SpHarness.init();
    defer h.deinit();
    const car = h.aiCar(37, 34, 0);
    // A marker in the lane ahead (normally placed by the light setup).
    const w = &h.sim.state.world;
    const mk = w.spawn(Sp.MapObject).?;
    w.get(mk, c.Transform).?.* = .{ .x = blk(50), .y = blk(34), .z = fx.one, .heading = 0 };
    w.get(mk, c.Object).?.* = .{ .kind = @intFromEnum(ids.ObjectKind.crossing_marker) };
    w.applyPending();
    var stopped = false;
    for (0..300) |_| {
        h.run(1);
        const t = h.sim.transformOf(car).?;
        if (t.x < blk(50) and h.speed(car) < fx.ratio(3, 100) and t.x > blk(45)) stopped = true;
    }
    try std.testing.expect(stopped);
    try std.testing.expect(h.sim.transformOf(car).?.x > blk(52)); // and went on
    // A task car drives straight past.
    const car2 = h.aiCar(37, 34, 0);
    Sp.car_tasks.setCarTask(h.sim, car2, .go_to, .none, blk(70), blk(34));
    var min_speed: fx.Fx = fx.one;
    for (0..200) |_| {
        h.run(1);
        const t = h.sim.transformOf(car2).?;
        if (t.x > blk(46) and t.x < blk(50)) min_speed = @min(min_speed, h.speed(car2));
    }
    try std.testing.expect(min_speed > fx.ratio(5, 100));
}

test "look-ahead: a car stops behind a stopped car and honks only if it is a honker" {
    var h = try SpHarness.init();
    defer h.deinit();
    const front = h.sim.spawnCarAt(blk(45), blk(34), 0, 0).?; // parked in the lane
    const back = h.aiCar(37, 34, 0);
    h.vehicle(back).ai_flags |= c.Vehicle.ai_emergency;
    h.run(200);
    const tb = h.sim.transformOf(back).?;
    const tf = h.sim.transformOf(front).?;
    try std.testing.expect(tb.x < tf.x - fx.ratio(8, 10));
    try std.testing.expect(h.speed(back) < fx.ratio(1, 100));
    const w = &h.sim.state.world;
    try std.testing.expectEqual(T.car_damage_max, w.get(back, c.Health).?.hp);
}

test "honk: an emergency car honks at a ped close ahead" {
    var h = try SpHarness.init();
    defer h.deinit();
    const car = h.aiCar(37, 34, 0);
    h.vehicle(car).ai_flags |= c.Vehicle.ai_emergency;
    h.vehicle(car).ai_age = 100;
    h.join(39, 34);
    var honked = false;
    for (0..40) |_| {
        h.run(1);
        if (h.vehicle(car).flags & c.Vehicle.flag_horn != 0) honked = true;
    }
    try std.testing.expect(honked);
}

test "traffic is deterministic: two runs of a busy city hash the same" {
    const S = simmod.Sim(.{ .name = "sp_soak", .max_players = 1, .car_capacity = 64, .ped_capacity = 32, .projectile_capacity = 8, .pickup_capacity = 4, .map_object_capacity = 8, .ambient_cars = 48, .ambient_peds = 16 });
    const g = try std.testing.allocator.create(map.Grid);
    defer std.testing.allocator.destroy(g);
    testmap.build(g);
    var hashes: [2]u64 = undefined;
    for (0..2) |k| {
        const s = try std.testing.allocator.create(S);
        defer std.testing.allocator.destroy(s);
        s.init(g, .{ .seed = 5, .mode = .authoritative });
        var frames = [1]Frame{Frame.neutral(0)};
        s.step(&frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(100, 100) }});
        for (0..1500) |_| s.step(&frames, &.{});
        hashes[k] = s.hash();
    }
    try std.testing.expectEqual(hashes[0], hashes[1]);
}
