//! WASM build of the replay runner, driven from JS (Node in CI, or a page).

const std = @import("std");
const common = @import("common.zig");
const sp = @import("sp.zig");
const sim = common.sim;
const abi = sim.abi;
const Frame = sim.input.Frame;

var grid: abi.Grid = undefined;
var sim16: common.Sim16 = undefined;
var sim200: common.Sim200 = undefined;
var bots: [200]common.bots.Bot = undefined;
var frames: [200]Frame = undefined;
var cmds: [64]abi.Command = undefined;
var sim_sp: sp.S = undefined;
var sp_golden: sp.Golden = .{};
var sp_live = false;
var sp_heap: [1 << 20]u8 = undefined;
var save_buf: [@max(common.Sim200.state_size, sp.S.state_size)]u8 align(8) = undefined;
var config: u32 = 16;
var bot_tick: u32 = 0;

/// Build the test map and start a session with `cfg` (16 or 200) players,
/// or 1: the single-player golden (sp config, the embedded script).
export fn rp_init(cfg: u32, seed_lo: u32, seed_hi: u32) void {
    sim.testmap.build(&grid);
    config = cfg;
    bot_tick = 0;
    for (&bots, 0..) |*b, i| b.* = common.bots.Bot.init(common.bot_seed, @intCast(i));
    const seed = (@as(u64, seed_hi) << 32) | seed_lo;
    if (cfg == 1) {
        if (sp_live) sp_golden.deinit();
        var fba = std.heap.FixedBufferAllocator.init(&sp_heap);
        var line: usize = 0;
        sp_golden.start(fba.allocator(), &sim_sp, &grid, seed, &line) catch unreachable;
        sp_live = true;
    } else if (cfg == 200) sim200.init(&grid, .{ .seed = seed, .mode = .authoritative }) else sim16.init(&grid, .{ .seed = seed, .mode = .authoritative });
}

export fn rp_grid_hash() u64 {
    return sim.map.gridHash(&grid);
}

/// Input buffers JS fills before `rp_step`: 200 frames of 8 bytes, and 64
/// commands of 8 bytes in I1 layout.
export fn rp_frames_ptr() [*]Frame {
    return &frames;
}
export fn rp_cmds_ptr() [*]abi.Command {
    return &cmds;
}

export fn rp_step(ncmds: u32) void {
    const n = @min(ncmds, cmds.len);
    switch (config) {
        1 => sim_sp.step(frames[0..1], cmds[0..n]),
        200 => sim200.step(frames[0..200], cmds[0..n]),
        else => sim16.step(frames[0..16], cmds[0..n]),
    }
}

/// Bench path: bots make the frames in-module, with the scripted session.
export fn rp_step_bots() void {
    var cbuf: [200]abi.Command = undefined;
    if (config == 200) {
        common.bots.tick(common.Sim200, &sim200, bots[0..200], frames[0..200]);
        sim200.step(frames[0..200], common.sessionCommands(bot_tick, 200, &cbuf));
    } else {
        common.bots.tick(common.Sim16, &sim16, bots[0..16], frames[0..16]);
        sim16.step(frames[0..16], common.sessionCommands(bot_tick, 16, &cbuf));
    }
    bot_tick += 1;
}

export fn rp_hash() u64 {
    return switch (config) {
        1 => sim_sp.hash(),
        200 => sim200.hash(),
        else => sim16.hash(),
    };
}

export fn rp_save() u32 {
    return @intCast(switch (config) {
        1 => sim_sp.save(&save_buf),
        200 => sim200.save(&save_buf),
        else => sim16.save(&save_buf),
    });
}

export fn rp_load() void {
    switch (config) {
        1 => sim_sp.load(save_buf[0..sp.S.state_size]) catch unreachable,
        200 => sim200.load(save_buf[0..common.Sim200.state_size]) catch unreachable,
        else => sim16.load(save_buf[0..common.Sim16.state_size]) catch unreachable,
    }
}

export fn rp_state_size() u32 {
    return switch (config) {
        1 => sp.S.state_size,
        200 => common.Sim200.state_size,
        else => common.Sim16.state_size,
    };
}
