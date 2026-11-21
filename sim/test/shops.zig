//! Tests: spray shops (sys/shops.zig), in deathmatch, deathmatch with
//! police and single player, on the synthetic test map with a hand-built
//! one-command script. No game data.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const c = h_.c;
const map = h_.map;
const testmap = h_.testmap;
const Frame = h_.Frame;
const Button = h_.Button;
const lv = simmod.level;
const OT = @import("../tuning/objects.zig");

fn World(comptime S: type) type {
    return struct {
        grid: *map.Grid,
        sim: *S,
        code: [16 + 24]u8 = @splat(0),
        pointers: [11]u16 = @splat(0),
        level: lv.Level = .{},
        frames: [S.config.max_players]Frame = @splat(Frame.neutral(0)),

        const Self = @This();

        fn init(w: *Self) !void {
            w.* = .{ .grid = try std.testing.allocator.create(map.Grid), .sim = try std.testing.allocator.create(S) };
            testmap.build(w.grid);
            w.sim.init(w.grid, .{ .seed = 5, .mode = .authoritative });
            w.sim.step(&w.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(30, 40) }});
            w.run(2);
        }
        fn deinit(w: *Self) void {
            std.testing.allocator.destroy(w.sim);
            std.testing.allocator.destroy(w.grid);
        }
        fn run(w: *Self, n: u32) void {
            for (0..n) |_| w.sim.step(&w.frames, &.{});
        }
        /// Put player 0 in a new car next to them; returns the car.
        fn drive(w: *Self) !abi.EntityId {
            const ped = w.sim.pedOf(0).?;
            const t = w.sim.transformOf(ped).?.*;
            const car = w.sim.spawnCarAt(t.x + fx.one, t.y, t.heading, 0) orelse return error.NoCar;
            for (0..20) |_| {
                w.frames[0].buttons |= Button.enter_exit;
                w.run(1);
                w.frames[0].buttons &= ~Button.enter_exit;
                for (0..120) |_| {
                    if (!w.sim.playerRow(0).car.isNone()) return car;
                    w.run(1);
                }
            }
            return error.NotInCar;
        }
        /// Attach a level whose script declares one shop at block (bx, by).
        fn shopAt(w: *Self, kind: u16, bx: i32, by: i32, value: u8) void {
            const num: u16 = 10;
            std.mem.writeInt(u16, w.code[8..][0..2], num, .little);
            std.mem.writeInt(u16, w.code[10..][0..2], kind, .little);
            const p = w.code[16..];
            std.mem.writeInt(i32, p[4..][0..4], (bx << 14) + (1 << 13), .little);
            std.mem.writeInt(i32, p[8..][0..4], (by << 14) + (1 << 13), .little);
            std.mem.writeInt(i32, p[12..][0..4], 255 << 14, .little);
            std.mem.writeInt(u16, p[16..][0..2], OT.car_shop_model, .little);
            std.mem.writeInt(i32, p[20..][0..4], value, .little);
            w.pointers[num] = 8;
            w.level = .{ .script = .{ .code = &w.code, .pointers = &w.pointers } };
            w.sim.attachLevel(&w.level);
        }
        fn carT(w: *Self, car: abi.EntityId) *c.Transform {
            return w.sim.transformOf(car).?;
        }
        fn remap(w: *Self, car: abi.EntityId) u16 {
            return w.sim.state.world.get(car, c.Appearance).?.remap;
        }
        /// Step once and return the respray events.
        fn stepCount(w: *Self) u32 {
            w.run(1);
            var n: u32 = 0;
            for (w.sim.events()) |e| {
                if (e.kind == .respray) n += 1;
            }
            return n;
        }
        fn moveTo(w: *Self, car: abi.EntityId, bx: i32, by: i32) void {
            const t = w.carT(car);
            t.x = fx.fromInt(bx) + fx.half;
            t.y = fx.fromInt(by) + fx.half;
        }
    };
}

test "shops: a spray shop repaints a player's car once per visit (dm16)" {
    const Wd = World(simmod.Sim16);
    var w: Wd = undefined;
    try w.init();
    defer w.deinit();
    const car = try w.drive();
    const t = w.carT(car);
    const bx = fx.toInt(t.x);
    const by = fx.toInt(t.y);
    w.shopAt(18, bx + 4, by, 7);
    try std.testing.expectEqual(@as(u8, 1), w.sim.shop_count);
    try std.testing.expectEqual(c.Appearance.no_remap, w.remap(car));
    try std.testing.expectEqual(@as(u32, 0), w.stepCount());
    w.moveTo(car, bx + 4, by);
    try std.testing.expectEqual(@as(u32, 1), w.stepCount());
    try std.testing.expectEqual(@as(u16, 7), w.remap(car));
    // Staying inside does nothing more.
    w.moveTo(car, bx + 4, by);
    try std.testing.expectEqual(@as(u32, 0), w.stepCount());
    // Out and back in: another visit.
    w.moveTo(car, bx, by);
    try std.testing.expectEqual(@as(u32, 0), w.stepCount());
    w.sim.state.world.get(car, c.Appearance).?.remap = 3;
    w.moveTo(car, bx + 4, by);
    try std.testing.expectEqual(@as(u32, 1), w.stepCount());
    try std.testing.expectEqual(@as(u16, 7), w.remap(car));
}

test "shops: weapon shop codes and other models are not spray shops" {
    const Wd = World(simmod.Sim16);
    var w: Wd = undefined;
    try w.init();
    defer w.deinit();
    const car = try w.drive();
    const bx = fx.toInt(w.carT(car).x);
    const by = fx.toInt(w.carT(car).y);
    w.shopAt(20, bx + 4, by, 254);
    try std.testing.expectEqual(@as(u8, 1), w.sim.shop_count);
    w.moveTo(car, bx + 4, by);
    try std.testing.expectEqual(@as(u32, 0), w.stepCount());
    try std.testing.expectEqual(c.Appearance.no_remap, w.remap(car));
}

test "shops: in a police room the shop clears the stars for points, if you can pay" {
    const Wd = World(simmod.Sim16Police);
    var w: Wd = undefined;
    try w.init();
    defer w.deinit();
    const S = simmod.Sim16Police;
    const car = try w.drive();
    const bx = fx.toInt(w.carT(car).x);
    const by = fx.toInt(w.carT(car).y);
    w.shopAt(18, bx + 4, by, 12);
    // Can't pay: repainted, stars stay.
    S.wanted.setStars(w.sim, 0, 2);
    w.sim.state.players[0].score = OT.shop_price_mp - 1;
    w.moveTo(car, bx + 4, by);
    w.run(1);
    var ev: ?S.Event = null;
    for (w.sim.events()) |e| if (e.kind == .respray) {
        ev = e;
    };
    try std.testing.expectEqual(@as(u8, 2), ev.?.c);
    try std.testing.expectEqual(@as(u8, 2), S.wanted.stars(w.sim, 0));
    try std.testing.expectEqual(@as(u16, 12), w.remap(car));
    // Out, back in with the points: cleared and charged.
    w.moveTo(car, bx, by);
    w.run(1);
    w.sim.state.players[0].score = OT.shop_price_mp + 500;
    w.moveTo(car, bx + 4, by);
    w.run(1);
    ev = null;
    for (w.sim.events()) |e| if (e.kind == .respray) {
        ev = e;
    };
    try std.testing.expectEqual(@as(u8, 1), ev.?.c);
    try std.testing.expectEqual(@as(u8, 0), S.wanted.stars(w.sim, 0));
    try std.testing.expectEqual(@as(i32, 500), w.sim.state.players[0].score);
}

test "shops: in single player the shop takes career cash to clear the stars" {
    const Wd = World(simmod.Sim(simmod.config_sp));
    const S = simmod.Sim(simmod.config_sp);
    var w: Wd = undefined;
    try w.init();
    defer w.deinit();
    const car = try w.drive();
    const bx = fx.toInt(w.carT(car).x);
    const by = fx.toInt(w.carT(car).y);
    w.shopAt(18, bx + 4, by, 9);
    w.run(1);
    S.wanted.setStars(w.sim, 0, 3);
    S.career.addScore(w.sim, 0, OT.shop_price_sp + 100, .flat);
    w.moveTo(car, bx + 4, by);
    w.run(1);
    try std.testing.expectEqual(@as(u8, 0), S.wanted.stars(w.sim, 0));
    try std.testing.expectEqual(@as(i32, 100), S.career.score(w.sim, 0));
    try std.testing.expectEqual(@as(u16, 9), w.remap(car));
}
