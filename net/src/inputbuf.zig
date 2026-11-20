//! Server side of I3 input: one buffer per player slot. Holds frames by tick,
//! hands the sim one frame per tick (repeating the last one when a frame is
//! late or lost), and reports `input_ack` and `slack_q` for the snapshot
//! header so the client can stop resending and steer its clock (S3).

const std = @import("std");
const itf = @import("interfaces");
const input = itf.input;
const wire = itf.wire;

pub const ring = 64;

pub const InputBuffer = struct {
    frames: [ring]input.Frame = undefined,
    tick_of: [ring]u32 = @splat(0xFFFF_FFFF),
    last: input.Frame = input.Frame.neutral(0),
    /// Newest tick T with every frame <= T held or already consumed.
    contig: u32 = 0,
    have_any: bool = false,
    /// Slack samples (ms, quarter ticks) for the 1 s minimum.
    samples: [64]struct { t: i64, q: i32 } = undefined,
    ns: usize = 0,
    stats: struct { received: u64 = 0, repeated: u64 = 0, late: u64 = 0 } = .{},

    /// Store frames from one input datagram. `next_tick` is the tick the
    /// server will step next (the state's tick), and `phase` is how far the
    /// server is into the current tick interval, 0..1 in 1/1024 units.
    pub fn receive(self: *InputBuffer, p: wire.InputPlayer, next_tick: u32, phase_1024: u32, now_ms: i64) void {
        const n: u32 = @intCast(p.frames.len);
        for (p.frames, 0..) |f, k| {
            const t = p.newest_tick -% (n - 1 - @as(u32, @intCast(k)));
            if (@as(i32, @bitCast(t -% next_tick)) < 0) continue; // already stepped
            if (@as(i32, @bitCast(t -% next_tick)) >= ring) continue; // too far ahead
            self.frames[t % ring] = f.sanitize();
            self.tick_of[t % ring] = t;
        }
        self.stats.received += 1;
        // Slack of the newest frame: how long before it is consumed.
        // Frame t is consumed when tick t is stepped, (t - next_tick) whole
        // ticks plus the rest of the current interval from now.
        const ahead: i64 = @as(i32, @bitCast(p.newest_tick -% next_tick));
        const q: i64 = ahead * 4 + @divFloor((1024 - @as(i64, phase_1024)) * 4, 1024);
        if (self.ns == self.samples.len) {
            std.mem.copyForwards(@TypeOf(self.samples[0]), self.samples[0 .. self.ns - 1], self.samples[1..self.ns]);
            self.ns -= 1;
        }
        self.samples[self.ns] = .{ .t = now_ms, .q = @intCast(std.math.clamp(q, -10000, 10000)) };
        self.ns += 1;
        if (!self.have_any) {
            self.have_any = true;
            self.contig = next_tick -% 1;
        }
        self.advanceContig();
    }

    fn advanceContig(self: *InputBuffer) void {
        while (self.tick_of[(self.contig +% 1) % ring] == self.contig +% 1) self.contig +%= 1;
    }

    /// The frame for tick `t`, which the server is about to step.
    pub fn consume(self: *InputBuffer, t: u32) input.Frame {
        var f = self.last;
        if (self.tick_of[t % ring] == t) {
            f = self.frames[t % ring];
            self.tick_of[t % ring] = 0xFFFF_FFFF;
        } else if (self.have_any) {
            self.stats.repeated += 1;
        }
        f.seq = input.seqOf(t);
        self.last = f;
        if (@as(i32, @bitCast(t -% self.contig)) > 0) self.contig = t;
        self.advanceContig();
        return f;
    }

    pub fn inputAck(self: *const InputBuffer) u32 {
        return self.contig;
    }

    /// Minimum slack over the last second, in quarter ticks, clamped to i8.
    pub fn slackQ(self: *InputBuffer, now_ms: i64) i8 {
        var m: i32 = 127;
        var keep: usize = 0;
        for (self.samples[0..self.ns]) |s| {
            if (s.t < now_ms - 1000) continue;
            self.samples[keep] = s;
            keep += 1;
            m = @min(m, s.q);
        }
        self.ns = keep;
        return @intCast(std.math.clamp(m, -128, 127));
    }
};

test "input buffer repeats, acks and measures slack" {
    var b: InputBuffer = .{};
    var fr: [3]input.Frame = undefined;
    for (&fr, 0..) |*f, k| f.* = .{ .steer = @intCast(k), .throttle = 0, .buttons = 0, .aim = 0, .seq = input.seqOf(@intCast(10 + k)) };
    b.receive(.{ .slot = 0, .newest_tick = 12, .frames = &fr }, 10, 512, 0);
    try std.testing.expectEqual(@as(u32, 12), b.inputAck());
    // newest frame 12 arrives with server about to step 10, half way in: 2.5 ticks early.
    try std.testing.expectEqual(@as(i8, 10), b.slackQ(0));
    try std.testing.expectEqual(@as(i8, 0), b.consume(10).steer);
    try std.testing.expectEqual(@as(i8, 1), b.consume(11).steer);
    try std.testing.expectEqual(@as(i8, 2), b.consume(12).steer);
    // 13 missing: repeat 12.
    const f13 = b.consume(13);
    try std.testing.expectEqual(@as(i8, 2), f13.steer);
    try std.testing.expectEqual(@as(u16, 13), f13.seq);
    try std.testing.expectEqual(@as(u64, 1), b.stats.repeated);
    try std.testing.expectEqual(@as(u32, 13), b.inputAck());
}
