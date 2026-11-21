//! The single-player golden (golden-sp/): the sp configuration on the test
//! map, running the hand-written script in sp_golden.sasm. Shared by the
//! native runner and the WASM module. inputs.bin has the dm16 golden's
//! format with players = 1.

const std = @import("std");
const sim = @import("sim");
const formats = @import("formats");
const abi = sim.abi;

pub const S = sim.Sim(sim.config_sp);
pub const script_text = @embedFile("sp_golden.sasm");
pub const seed: u64 = 0x5_9015EED;
pub const ticks: u32 = 6000;

/// The assembled script and the level that points into it; keep it alive
/// as long as the sim runs.
pub const Golden = struct {
    asmd: formats.scr.Assembled = undefined,
    level: sim.Level = undefined,

    /// On a script error `line` holds the failing line of sp_golden.sasm.
    pub fn start(g: *Golden, gpa: std.mem.Allocator, s: *S, grid: *const abi.Grid, sd: u64, line: *usize) !void {
        g.asmd = try formats.scr.assemble(gpa, script_text, line);
        g.level = g.asmd.level();
        s.init(grid, .{ .seed = sd, .mode = .authoritative });
        s.attachLevel(&g.level);
    }

    pub fn deinit(g: *Golden) void {
        g.asmd.deinit();
    }
};

/// The session: the player joins at tick 0 (the script's player
/// declaration then moves it).
pub fn commands(t: u32, out: []abi.Command) []abi.Command {
    if (t != 0) return out[0..0];
    out[0] = .{ .op = .join, .slot = 0, .arg = sim.spawnHint(20, 20) };
    return out[0..1];
}
