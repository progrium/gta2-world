//! The soak's world: workstream A's sim/ (dm16, or dmp16 with police) on the synthetic test map,
//! or on a real .gmp given with --map (`-Dsim=real`).
const std = @import("std");
const abi = @import("interfaces").abi;
const input = @import("interfaces").input;
const sim = @import("sim");
const formats = @import("formats");

/// `-Dsim=police`: deathmatch with police (dmp16, the living city).
const police = @import("soak_opts").police;
pub const name = if (police) "sim/ dmp16" else "sim/ dm16";
pub const cfg = if (police) sim.config_16_police else sim.config_16;
pub const S = sim.Sim(cfg);
pub const car_r = sim.tuning.default_car_models[0].radius;
pub const atan2 = sim.fx.atan2;
pub const wander_lo = 40;
pub const wander_x = 176;
pub const wander_y = 176;

pub fn buildGrid(gpa: std.mem.Allocator, io: std.Io, grid: *abi.Grid, map_path: ?[]const u8) !void {
    const path = map_path orelse return sim.testmap.build(grid);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    var m = try formats.gmp.parse(gpa, bytes);
    defer m.deinit();
    formats.grid.build(&m, grid);
}

/// Players join on foot: drop a car in front of each and press enter.
pub fn seatPlayers(s: *S, frames: *[cfg.max_players]input.Frame, n: u32) void {
    for (0..n) |p| {
        const ped = s.pedOf(@intCast(p)) orelse continue;
        const t = s.transformOf(ped).?.*;
        const dx = @divTrunc(sim.fx.cos(t.heading) * 72, 64);
        const dy = @divTrunc(sim.fx.sin(t.heading) * 72, 64);
        _ = s.spawnCarAt(t.x + dx, t.y + dy, t.heading, 0);
    }
    for (0..n) |p| frames[p].buttons = input.Button.enter_exit;
    s.step(frames, &.{});
    for (0..n) |p| frames[p].buttons = 0;
    for (0..10) |_| s.step(frames, &.{});
}
