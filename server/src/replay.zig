//! Replay capture: every command and input frame a session's sim consumed,
//! tick by tick, with the state hash after each step.
//!
//! Any bug report with a replay can be re-run headlessly (`gta2-server
//! replay FILE --data DIR`) and the first tick whose hash differs is
//! reported. That is the main debugging tool the design doc asks for, and
//! also the M1 check that the headless server steps the same sim.
//!
//! File layout, little-endian:
//!
//!   header:
//!     [4]  "G2WR"
//!     u16  format version (1)
//!     u16  I1 abi_version
//!     u64  sim layout_hash
//!     [32] map hash (SHA-256 of the .gmp)
//!     u64  seed
//!     u16  max_players
//!     str  config name   (u8 length + bytes)
//!     str  session id    (u8 length + bytes)
//!     i64  wall-clock start, unix seconds
//!   then one record per tick:
//!     u32  tick (the sim tick before the step)
//!     u8   command count, then 8 bytes per I1 Command
//!     [ceil(max_players/8)] bitmask of slots that have a frame
//!     8 bytes per set bit: the I2 frame, in slot order
//!     u64  hash() after the step
//!
//! Slots without a bit get `Frame.neutral(seq of tick)`, which is what the
//! session feeds the sim for empty slots.

const std = @import("std");
const ifc = @import("interfaces");
const util = @import("util.zig");
const abi = ifc.abi;
const input = ifc.input;

pub const magic = "G2WR";
pub const format_version: u16 = 1;

pub const Header = struct {
    abi_version: u16 = abi.abi_version,
    layout_hash: u64,
    map_hash: [32]u8,
    seed: u64,
    max_players: u16,
    config_name: []const u8,
    session: []const u8,
    started: i64,
};

pub const Writer = struct {
    gpa: std.mem.Allocator,
    file: util.OutFile,
    buf: std.ArrayList(u8) = .empty,
    max_players: u16,
    ticks: u64 = 0,
    bytes: u64 = 0,
    failed: bool = false,

    pub fn create(gpa: std.mem.Allocator, path: []const u8, h: Header) !*Writer {
        const w = try gpa.create(Writer);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .file = try util.OutFile.create(path), .max_players = h.max_players };
        const b = &w.buf;
        try b.appendSlice(gpa, magic);
        try putInt(gpa, b, u16, format_version);
        try putInt(gpa, b, u16, h.abi_version);
        try putInt(gpa, b, u64, h.layout_hash);
        try b.appendSlice(gpa, &h.map_hash);
        try putInt(gpa, b, u64, h.seed);
        try putInt(gpa, b, u16, h.max_players);
        try putStr(gpa, b, h.config_name);
        try putStr(gpa, b, h.session);
        try putInt(gpa, b, i64, h.started);
        return w;
    }

    pub fn tick(w: *Writer, t: abi.Tick, cmds: []const abi.Command, frames: []const input.Frame, present: []const bool, hash_after: u64) void {
        if (w.failed) return;
        w.tickInner(t, cmds, frames, present, hash_after) catch {
            w.failed = true;
        };
        if (w.buf.items.len >= 64 * 1024) w.flush();
    }

    fn tickInner(w: *Writer, t: abi.Tick, cmds: []const abi.Command, frames: []const input.Frame, present: []const bool, hash_after: u64) !void {
        const gpa = w.gpa;
        const b = &w.buf;
        try putInt(gpa, b, u32, t);
        try b.append(gpa, @intCast(cmds.len));
        for (cmds) |cmd| try b.appendSlice(gpa, std.mem.asBytes(&cmd));
        const mask_len = (w.max_players + 7) / 8;
        const mstart = b.items.len;
        try b.appendNTimes(gpa, 0, mask_len);
        for (present, 0..) |p, i| {
            if (!p) continue;
            b.items[mstart + i / 8] |= @as(u8, 1) << @intCast(i % 8);
            var fb: [8]u8 = undefined;
            frames[i].encode(&fb);
            try b.appendSlice(gpa, &fb);
        }
        try putInt(gpa, b, u64, hash_after);
        w.ticks += 1;
    }

    pub fn flush(w: *Writer) void {
        if (w.buf.items.len == 0 or w.failed) return;
        w.file.writeAll(w.buf.items) catch {
            w.failed = true;
        };
        w.bytes += w.buf.items.len;
        w.buf.clearRetainingCapacity();
    }

    pub fn close(w: *Writer) void {
        w.flush();
        w.file.close();
        w.buf.deinit(w.gpa);
        w.gpa.destroy(w);
    }
};

fn putInt(gpa: std.mem.Allocator, b: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &tmp, v, .little);
    try b.appendSlice(gpa, &tmp);
}

fn putStr(gpa: std.mem.Allocator, b: *std.ArrayList(u8), s: []const u8) !void {
    const n: u8 = @intCast(@min(s.len, 255));
    try b.append(gpa, n);
    try b.appendSlice(gpa, s[0..n]);
}

// ---------------------------------------------------------------------------
// Reading

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    header: Header = undefined,

    pub fn init(bytes: []const u8) !Reader {
        var r: Reader = .{ .bytes = bytes };
        if (!std.mem.eql(u8, try r.take(4), magic)) return error.NotAReplay;
        if (try r.int(u16) != format_version) return error.UnsupportedVersion;
        var h: Header = undefined;
        h.abi_version = try r.int(u16);
        h.layout_hash = try r.int(u64);
        h.map_hash = (try r.take(32))[0..32].*;
        h.seed = try r.int(u64);
        h.max_players = try r.int(u16);
        h.config_name = try r.take(try r.int(u8));
        h.session = try r.take(try r.int(u8));
        h.started = try r.int(i64);
        r.header = h;
        return r;
    }

    pub const Tick = struct {
        tick: abi.Tick,
        cmds_len: usize,
        cmds: [256]abi.Command,
        hash_after: u64,
    };

    /// Reads the next tick into `frames` (len == max_players). Null at end.
    pub fn next(r: *Reader, frames: []input.Frame, out: *Tick) !?void {
        if (r.pos == r.bytes.len) return null;
        out.tick = try r.int(u32);
        out.cmds_len = try r.int(u8);
        for (0..out.cmds_len) |i| out.cmds[i] = std.mem.bytesToValue(abi.Command, try r.take(8));
        const mask = try r.take((r.header.max_players + 7) / 8);
        for (frames, 0..) |*f, i| {
            if (mask[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0) {
                f.* = input.Frame.decode((try r.take(8))[0..8]);
            } else f.* = input.Frame.neutral(input.seqOf(out.tick));
        }
        out.hash_after = try r.int(u64);
        return {};
    }

    fn take(r: *Reader, n: usize) ![]const u8 {
        if (r.pos + n > r.bytes.len) return error.Truncated;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }
    fn int(r: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

pub const RunResult = struct {
    ticks: u64,
    /// First tick whose hash after the step differs, if any.
    first_mismatch: ?abi.Tick,
    expected: u64 = 0,
    got: u64 = 0,
    final_hash: u64,
};

/// Re-runs a replay on `Sim` over `grid` and compares every tick's hash.
pub fn run(comptime Sim: type, gpa: std.mem.Allocator, bytes: []const u8, grid: *const abi.Grid) !RunResult {
    var r = try Reader.init(bytes);
    if (r.header.layout_hash != Sim.layout_hash) return error.LayoutMismatch;
    if (r.header.max_players != Sim.config.max_players) return error.LayoutMismatch;
    const sim = try gpa.create(Sim);
    defer gpa.destroy(sim);
    sim.init(grid, .{ .seed = r.header.seed, .mode = .authoritative });
    const frames = try gpa.alloc(input.Frame, Sim.config.max_players);
    defer gpa.free(frames);
    var t: Reader.Tick = undefined;
    var res: RunResult = .{ .ticks = 0, .first_mismatch = null, .final_hash = sim.hash() };
    while (try r.next(frames, &t)) |_| {
        if (sim.tick() != t.tick) sim.setTick(t.tick);
        sim.step(frames, t.cmds[0..t.cmds_len]);
        const h = sim.hash();
        res.ticks += 1;
        res.final_hash = h;
        if (h != t.hash_after and res.first_mismatch == null) {
            res.first_mismatch = t.tick;
            res.expected = t.hash_after;
            res.got = h;
        }
    }
    return res;
}

test "replay round trip on the stub" {
    const gpa = std.testing.allocator;
    const Sim = abi.Stub;
    const grid = try gpa.create(abi.Grid);
    defer gpa.destroy(grid);
    @memset(std.mem.asBytes(grid), 0);

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/g2wr-test-{d}.g2wr", .{util.now()});
    const w = try Writer.create(gpa, path, .{ .layout_hash = Sim.layout_hash, .map_hash = @splat(7), .seed = 42, .max_players = Sim.config.max_players, .config_name = Sim.config.name, .session = "t", .started = 0 });
    var sim: Sim = undefined;
    sim.init(grid, .{ .seed = 42, .mode = .authoritative });
    var frames: [Sim.config.max_players]input.Frame = undefined;
    var present: [Sim.config.max_players]bool = @splat(false);
    for (0..300) |i| {
        const tk = sim.tick();
        for (&frames) |*f| f.* = input.Frame.neutral(input.seqOf(tk));
        var cmds: []const abi.Command = &.{};
        const join = [_]abi.Command{.{ .op = .join, .slot = 3, .arg = 0 }};
        if (i == 0) cmds = &join;
        present[3] = true;
        frames[3].throttle = @intCast(i % 100);
        frames[3].steer = 20;
        sim.step(&frames, cmds);
        w.tick(tk, cmds, &frames, &present, sim.hash());
    }
    const final = sim.hash();
    w.close();

    const bytes = try util.readFile(gpa, path, 1 << 24);
    defer gpa.free(bytes);
    const res = try run(Sim, gpa, bytes, grid);
    try std.testing.expectEqual(@as(u64, 300), res.ticks);
    try std.testing.expect(res.first_mismatch == null);
    try std.testing.expectEqual(final, res.final_hash);
}
