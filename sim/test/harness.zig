//! Shared test harness: a small config with no ambient population, the
//! synthetic test map, and helpers.
const std = @import("std");
pub const simmod = @import("../sim.zig");
pub const abi = simmod.abi;
pub const input = simmod.input;
pub const fx = simmod.fx;
pub const map = simmod.map;
pub const c = simmod.c;
pub const T = simmod.tuning;
pub const testmap = simmod.testmap;
pub const Button = input.Button;
pub const Frame = input.Frame;
pub const EntityId = abi.EntityId;

pub const eql = simmod.ecs.eql;

/// Small config: no ambient population, so tests control everything.
pub const cfg_small: abi.Config = .{ .name = "test", .max_players = 4, .car_capacity = 8, .ped_capacity = 16, .projectile_capacity = 16, .pickup_capacity = 4, .map_object_capacity = 4 };
pub const S = simmod.Sim(cfg_small);

pub const Harness = struct {
    grid: *map.Grid,
    sim: *S,
    frames: [cfg_small.max_players]Frame = @splat(Frame.neutral(0)),

    pub fn init(mode: abi.Mode) !Harness {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(S);
        s.init(g, .{ .seed = 7, .mode = mode });
        return .{ .grid = g, .sim = s };
    }
    pub fn deinit(h: *Harness) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    pub fn join(h: *Harness, slot: u8, bx: u8, by: u8) void {
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = slot, .arg = simmod.spawnHint(bx, by) }});
    }
    pub fn run(h: *Harness, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
    pub fn ped(h: *Harness, slot: u32) *c.Transform {
        return h.sim.transformOf(h.sim.pedOf(slot).?).?;
    }
    pub fn tap(h: *Harness, slot: u32, b: u16) void {
        h.frames[slot].buttons |= b;
        h.run(1);
        h.frames[slot].buttons &= ~b;
        h.run(1);
    }
};

pub fn blk(i: i32) fx.Fx {
    return fx.fromInt(i) + fx.half;
}

pub fn hasEvent(evs: anytype, kind: anytype) bool {
    for (evs) |e| if (e.kind == kind) return true;
    return false;
}

/// Turn the floor cells under (x0..x1, y0..y1) at standing height `z` into
/// deep water.
pub fn flood(h: *Harness, x0: usize, y0: usize, x1: usize, y1: usize, z: fx.Fx) void {
    const l: usize = @intCast(fx.toInt(z) - 1);
    for (y0..y1 + 1) |y| for (x0..x1 + 1) |x| {
        h.grid.blocks[l][y][x] = map.makeCell(map.Shape.water, 0, map.Ground.none, 0);
    };
}

pub fn arm(h: *Harness, slot: u32, k: u8, tenths: u16) *c.Weapon {
    const wpn = h.sim.state.world.get(h.sim.pedOf(slot).?, c.Weapon).?;
    wpn.rounds()[k] = tenths;
    wpn.kind = k;
    return wpn;
}

pub fn shotCount(h: *Harness) u32 {
    return h.sim.state.world.count(S.Shot);
}
