//! WASM harness. The JS side (Node runner or browser page) drives these
//! exports; timing is done in JS with performance.now().

const std = @import("std");
const common = @import("common.zig");
const sim = common.sim;
const Frame = sim.input.Frame;

var grid: sim.map.Grid = undefined;
var sim16: common.Sim16 = undefined;
var sim200: common.Sim200 = undefined;
var bots: [200]common.bots.Bot = undefined;
var frames: [200]Frame = undefined;
var save_buf: [common.Sim200.state_size]u8 align(8) = undefined;
var config: u32 = 16;

/// Build the map and start a session. cfg is 16 or 200.
export fn s2_init(cfg: u32) void {
    common.mapgen.generate(&grid, common.map_seed);
    config = cfg;
    for (&bots, 0..) |*b, i| b.* = common.bots.Bot.init(common.bot_seed, @intCast(i));
    if (cfg == 200) sim200.init(&grid, common.sim_seed, 200) else sim16.init(&grid, common.sim_seed, 16);
}

export fn s2_map_hash() u64 {
    return common.mapHash(&grid);
}

/// Pointer to the 16-player input buffer (16 x 8 bytes), filled by JS for replay.
export fn s2_input_ptr() [*]Frame {
    return &frames;
}

/// Step once with the frames JS wrote to the input buffer.
export fn s2_step_inputs() void {
    if (config == 200) sim200.step(frames[0..200]) else sim16.step(frames[0..16]);
}

/// Generate bot inputs in-module, then step once (bench path).
export fn s2_step_bots() void {
    if (config == 200) {
        common.bots.tick(bots[0..200], frames[0..200]);
        sim200.step(frames[0..200]);
    } else {
        common.bots.tick(bots[0..16], frames[0..16]);
        sim16.step(frames[0..16]);
    }
}

/// Generate one tick of bot input into the buffer without stepping.
export fn s2_gen_bots() void {
    if (config == 200) common.bots.tick(bots[0..200], frames[0..200]) else common.bots.tick(bots[0..16], frames[0..16]);
}

export fn s2_hash() u64 {
    return if (config == 200) sim200.hash() else sim16.hash();
}

export fn s2_save() u32 {
    return @intCast(if (config == 200) sim200.save(&save_buf) else sim16.save(&save_buf));
}

export fn s2_load() void {
    if (config == 200) sim200.load(&save_buf) else sim16.load(&save_buf);
}

export fn s2_state_size() u32 {
    return if (config == 200) common.Sim200.state_size else common.Sim16.state_size;
}

export fn s2_counts(which: u32) u32 {
    if (config == 200) {
        const w = &sim200.state.world;
        return switch (which) {
            0 => w.count(common.Sim200.Car),
            1 => w.count(common.Sim200.Ped),
            else => w.count(common.Sim200.Shot),
        };
    }
    const w = &sim16.state.world;
    return switch (which) {
        0 => w.count(common.Sim16.Car),
        1 => w.count(common.Sim16.Ped),
        else => w.count(common.Sim16.Shot),
    };
}
