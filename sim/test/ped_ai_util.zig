//! Shared helpers for the ped AI tests (D1): a small single-player config
//! with no ambient population, on the open fields of the test map.

const std = @import("std");
const h_ = @import("harness.zig");
pub const simmod = h_.simmod;
pub const abi = h_.abi;
pub const fx = h_.fx;
pub const map = h_.map;
pub const c = h_.c;
pub const T = h_.T;
pub const Frame = h_.Frame;
pub const Button = h_.Button;
pub const EntityId = abi.EntityId;
pub const eql = h_.eql;
pub const ids = simmod.ids;
pub const testmap = h_.testmap;

pub const cfg: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 8, .ped_capacity = 32, .projectile_capacity = 64, .pickup_capacity = 4, .map_object_capacity = 4 };
pub const S = simmod.Sim(cfg);
pub const Obj = S.objectives;
pub const objectives = @import("../ai/objectives.zig");
pub const Kind = objectives.Kind;
pub const Status = objectives.Status;

pub const World = struct {
    grid: *map.Grid,
    sim: *S,
    frames: [1]Frame = .{Frame.neutral(0)},

    pub fn init() !World {
        const g = try std.testing.allocator.create(map.Grid);
        h_.testmap.build(g);
        const s = try std.testing.allocator.create(S);
        s.init(g, .{ .seed = 11, .mode = .authoritative });
        return .{ .grid = g, .sim = s };
    }
    pub fn deinit(wd: *World) void {
        std.testing.allocator.destroy(wd.sim);
        std.testing.allocator.destroy(wd.grid);
    }
    /// The player on block (bx, by), unarmed.
    pub fn player(wd: *World, bx: u8, by: u8) EntityId {
        wd.sim.step(&wd.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(bx, by) }});
        const id = wd.sim.pedOf(0).?;
        const w = wd.sim.state.world.get(id, c.Weapon).?;
        for (w.rounds()) |*r| r.* = 0;
        return id;
    }
    /// An AI ped at block (bx, by) with an occupation.
    pub fn ped(wd: *World, bx: u8, by: u8, occ: ids.Occupation) EntityId {
        const id = wd.sim.spawnPed(c.Controller.no_player, simmod.spawnHint(bx, by)).?;
        wd.sim.state.world.applyPending();
        Obj.setOccupation(wd.sim, id, occ);
        return id;
    }
    pub fn run(wd: *World, n: u32) void {
        for (0..n) |_| wd.sim.step(&wd.frames, &.{});
    }
    pub fn t(wd: *World, id: EntityId) *c.Transform {
        return wd.sim.state.world.get(id, c.Transform).?;
    }
    pub fn hp(wd: *World, id: EntityId) i32 {
        const h = wd.sim.state.world.get(id, c.Health) orelse return 0;
        return h.hp;
    }
    pub fn alive(wd: *World, id: EntityId) bool {
        return wd.sim.state.world.isAlive(id) and wd.hp(id) > 0;
    }
    pub fn o(wd: *World, id: EntityId) *c.Objective {
        return wd.sim.state.world.get(id, c.Objective).?;
    }
    pub fn dist(wd: *World, a: EntityId, b: EntityId) fx.Fx {
        const ta = wd.t(a);
        const tb = wd.t(b);
        return fx.length(ta.x - tb.x, ta.y - tb.y);
    }
    /// Move an entity to the centre of block (bx, by) at street level.
    pub fn place(wd: *World, id: EntityId, bx: i32, by: i32) void {
        const tt = wd.t(id);
        tt.x = blk(bx);
        tt.y = blk(by);
    }
};

pub fn blk(i: i32) fx.Fx {
    return fx.fromInt(i) + fx.half;
}
