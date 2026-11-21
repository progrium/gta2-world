//! The soak's world: net/'s stand-in arena sim (default, `-Dsim=test`).
const std = @import("std");
const abi = @import("interfaces").abi;
const input = @import("interfaces").input;
const ts = @import("net").testsim;

pub const name = "testsim arena";
pub const cfg: abi.Config = .{
    .name = "arena16",
    .max_players = 16,
    .car_capacity = 64,
    .ped_capacity = 128,
    .projectile_capacity = 0,
    .ambient_cars = 24,
    .ambient_peds = 100,
};
pub const S = ts.Sim(cfg);
pub const car_r = ts.car_r;
pub const atan2 = ts.atan2;
/// Wander targets: the arena's extent in blocks.
pub const wander_lo = 4;
pub const wander_x = 88;
pub const wander_y = 56;

pub fn buildGrid(_: std.mem.Allocator, _: std.Io, grid: *abi.Grid, _: ?[]const u8) !void {
    @memset(std.mem.asBytes(grid), 0);
}

/// Players start in cars in the arena sim.
pub fn seatPlayers(_: *S, _: *[cfg.max_players]input.Frame, _: u32) void {}
