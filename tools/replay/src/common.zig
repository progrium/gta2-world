//! Shared by the native runner and the WASM module: configurations, seeds,
//! the scripted session and the replay file format.
//!
//! inputs.bin: a 32-byte header, then per tick a u8 command count, that many
//! 8-byte I1 commands, and `players` 8-byte I2 frames.
//!   header: "G2RP", u32 version, u64 seed, u32 players, u32 ticks, u64 grid hash
//! hashes.bin: u64 hash() after init, then after every tick (ticks + 1).

const std = @import("std");
pub const sim = @import("sim");
pub const bots = @import("bots.zig");
const abi = sim.abi;
const Frame = sim.input.Frame;

pub const Sim16 = sim.Sim16;
pub const Sim200 = sim.Sim(sim.config_200);

pub const sim_seed: u64 = 0x6A2_5EED;
pub const bot_seed: u32 = 0xB07_5EED;
pub const version: u32 = 1;
pub const header_size = 32;

/// The session the golden replay records: everyone joins at tick 0; two
/// players leave at 4000 and rejoin at 4100.
pub fn sessionCommands(t: u32, players: u32, out: []abi.Command) []abi.Command {
    var n: usize = 0;
    if (t == 0) {
        var i: u32 = 0;
        while (i < players) : (i += 1) {
            out[n] = .{ .op = .join, .slot = @intCast(i), .arg = 0 };
            n += 1;
        }
    } else if (t == 4000 or t == 4100) {
        for ([_]u8{ 3, 7 }) |slot| {
            if (slot >= players) continue;
            out[n] = .{ .op = if (t == 4000) .leave else .join, .slot = slot, .arg = 0 };
            n += 1;
        }
    }
    return out[0..n];
}

pub const Header = struct {
    seed: u64,
    players: u32,
    ticks: u32,
    grid_hash: u64,

    pub fn write(h: Header, out: *[header_size]u8) void {
        @memcpy(out[0..4], "G2RP");
        std.mem.writeInt(u32, out[4..8], version, .little);
        std.mem.writeInt(u64, out[8..16], h.seed, .little);
        std.mem.writeInt(u32, out[16..20], h.players, .little);
        std.mem.writeInt(u32, out[20..24], h.ticks, .little);
        std.mem.writeInt(u64, out[24..32], h.grid_hash, .little);
    }

    pub fn read(in: []const u8) !Header {
        if (in.len < header_size or !std.mem.eql(u8, in[0..4], "G2RP")) return error.BadReplay;
        if (std.mem.readInt(u32, in[4..8], .little) != version) return error.BadReplayVersion;
        return .{
            .seed = std.mem.readInt(u64, in[8..16], .little),
            .players = std.mem.readInt(u32, in[16..20], .little),
            .ticks = std.mem.readInt(u32, in[20..24], .little),
            .grid_hash = std.mem.readInt(u64, in[24..32], .little),
        };
    }
};

/// Reads one tick of a replay body at `pos`; returns the commands and frames
/// (decoded into the buffers) and the next position.
pub fn readTick(body: []const u8, pos: usize, players: u32, cmds: []abi.Command, frames: []Frame) !struct { cmds: []abi.Command, next: usize } {
    if (pos >= body.len) return error.BadReplay;
    const n = body[pos];
    var p = pos + 1;
    if (n > cmds.len or p + @as(usize, n) * 8 + players * 8 > body.len) return error.BadReplay;
    for (0..n) |i| {
        const b = body[p..][0..8];
        cmds[i] = .{ .op = @enumFromInt(b[0]), .slot = b[1], .arg = std.mem.readInt(u32, b[4..8], .little) };
        p += 8;
    }
    for (frames[0..players]) |*f| {
        f.* = Frame.decode(body[p..][0..8]);
        p += 8;
    }
    return .{ .cmds = cmds[0..n], .next = p };
}

pub fn writeTick(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cmds: []const abi.Command, frames: []const Frame) !void {
    try out.append(gpa, @intCast(cmds.len));
    for (cmds) |cm| {
        var b: [8]u8 = @splat(0);
        b[0] = @intFromEnum(cm.op);
        b[1] = cm.slot;
        std.mem.writeInt(u32, b[4..8], cm.arg, .little);
        try out.appendSlice(gpa, &b);
    }
    for (frames) |f| {
        var b: [8]u8 = undefined;
        f.encode(&b);
        try out.appendSlice(gpa, &b);
    }
}
