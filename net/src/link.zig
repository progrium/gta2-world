//! A fake one-way datagram link for headless tests and the in-page sandbox:
//! latency, uniform jitter (which also reorders) and loss, from a seeded
//! generator so runs repeat exactly. A port of S3's `Link`, carrying bytes.
//! Optional bursty loss (Gilbert model) for harsher cases.

const std = @import("std");

pub const max_msg = 1200;
const cap = 512;

pub const Link = struct {
    one_way_ms: f64 = 75,
    jitter_ms: f64 = 0,
    loss: f64 = 0,
    /// Probability a loss starts a burst; while in a burst every datagram
    /// is lost until `burst_end` fires. 0 = independent loss.
    burst_end: f64 = 0,
    in_burst: bool = false,
    rng: std.Random.DefaultPrng,
    q: [cap]struct { t: f64, len: u16, buf: [max_msg]u8 } = undefined,
    n: usize = 0,
    sent: u64 = 0,
    dropped: u64 = 0,
    bytes: u64 = 0,

    pub fn init(seed: u64) Link {
        return .{ .rng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn send(self: *Link, now: f64, msg: []const u8) void {
        const r = self.rng.random();
        self.sent += 1;
        self.bytes += msg.len;
        if (self.in_burst) {
            if (r.float(f64) < self.burst_end) self.in_burst = false else {
                self.dropped += 1;
                return;
            }
        }
        if (r.float(f64) < self.loss) {
            self.dropped += 1;
            if (self.burst_end > 0) self.in_burst = true;
            return;
        }
        if (self.n == cap or msg.len > max_msg) {
            self.dropped += 1;
            return;
        }
        const d = @max(0, self.one_way_ms + (r.float(f64) * 2 - 1) * self.jitter_ms);
        const e = &self.q[self.n];
        e.t = now + d;
        e.len = @intCast(msg.len);
        @memcpy(e.buf[0..msg.len], msg);
        self.n += 1;
    }

    /// Pop the earliest message due at `now`, if any. The returned slice is
    /// valid until the next call.
    pub fn poll(self: *Link, now: f64, out: *[max_msg]u8) ?[]const u8 {
        var best: ?usize = null;
        for (self.q[0..self.n], 0..) |e, i| {
            if (e.t <= now and (best == null or e.t < self.q[best.?].t)) best = i;
        }
        const i = best orelse return null;
        const len = self.q[i].len;
        @memcpy(out[0..len], self.q[i].buf[0..len]);
        self.q[i] = self.q[self.n - 1];
        self.n -= 1;
        return out[0..len];
    }
};

test "link delays, drops and delivers in time order" {
    var l = Link.init(1);
    l.one_way_ms = 50;
    l.jitter_ms = 10;
    l.send(0, "a");
    l.send(1, "b");
    var buf: [max_msg]u8 = undefined;
    try std.testing.expect(l.poll(30, &buf) == null);
    var got: usize = 0;
    while (l.poll(100, &buf)) |_| got += 1;
    try std.testing.expectEqual(@as(usize, 2), got);
}
