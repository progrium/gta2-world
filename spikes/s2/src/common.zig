//! Shared host code for the native and WASM harnesses.

const std = @import("std");
pub const sim = @import("sim");
pub const mapgen = @import("mapgen.zig");
pub const bots = @import("bots.zig");

pub const Sim16 = sim.Sim(sim.config_16);
pub const Sim200 = sim.Sim(sim.config_200);

pub const map_seed: u32 = 0x5EED_0002;
pub const sim_seed: u64 = 0x0002_5EED_C0FF_EE00;
pub const bot_seed: u32 = 0xB07_5EED;

pub fn mapHash(g: *const sim.map.Grid) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(g));
}
