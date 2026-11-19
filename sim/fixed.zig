//! Fixed-point arithmetic for the sim. No floating point anywhere in sim/.
//!
//! Fx is 16.16 signed fixed point stored in an i32. One map block is 1.0.
//! Angles are u16 "binary angle" units: 65536 = one full turn.
//!
//! All arithmetic that can overflow uses wrapping or widening operations so the
//! result is defined (and identical) in every build mode and on every target.

const std = @import("std");

pub const Fx = i32;
pub const Angle = u16;

pub const frac_bits = 16;
pub const one: Fx = 1 << frac_bits;
pub const half: Fx = one >> 1;

pub inline fn fromInt(i: i32) Fx {
    return i << frac_bits;
}

/// Build a constant from a ratio, e.g. ratio(3, 100) = 0.03.
pub inline fn ratio(comptime num: i64, comptime den: i64) Fx {
    return @intCast(@divTrunc(num << frac_bits, den));
}

pub inline fn toInt(a: Fx) i32 {
    return a >> frac_bits; // arithmetic shift: floor
}

pub inline fn mul(a: Fx, b: Fx) Fx {
    const p: i64 = @as(i64, a) * @as(i64, b);
    return @truncate(p >> frac_bits);
}

pub inline fn div(a: Fx, b: Fx) Fx {
    if (b == 0) return 0;
    const n: i64 = @as(i64, a) << frac_bits;
    return @truncate(@divTrunc(n, @as(i64, b)));
}

/// Multiply by a value in [-127, 127] scaled to [-1, 1).
pub inline fn mulAxis(a: Fx, axis: i8) Fx {
    return @truncate((@as(i64, a) * @as(i64, axis)) >> 7);
}

pub inline fn clamp(a: Fx, lo: Fx, hi: Fx) Fx {
    return if (a < lo) lo else if (a > hi) hi else a;
}

pub inline fn abs(a: Fx) Fx {
    return if (a < 0) -%a else a;
}

/// Integer square root of a u64 (floor). Deterministic, no floats.
pub fn isqrt64(n: u64) u64 {
    if (n == 0) return 0;
    // Start at or above sqrt(n); Newton iteration from above converges monotonically.
    var x: u64 = if (n >= (1 << 62)) (1 << 32) else n;
    var y: u64 = (x + n / x) >> 1;
    while (y < x) {
        x = y;
        y = (x + n / x) >> 1;
    }
    return x;
}

/// Length of (dx, dy) in Fx.
pub fn length(dx: Fx, dy: Fx) Fx {
    const sx: i64 = dx;
    const sy: i64 = dy;
    const sq: u64 = @intCast(sx * sx + sy * sy); // Fx^2 = 32 frac bits
    return @intCast(@min(isqrt64(sq), std.math.maxInt(i32)));
}

// ---------------------------------------------------------------------------
// Trigonometry: a 1024-entry quarter-free sine table built at comptime with
// integer arithmetic only (Taylor series in Q30), so the table is bit-identical
// regardless of host.

pub const sin_table_bits = 10;
pub const sin_table_len = 1 << sin_table_bits;

const sin_table: [sin_table_len]Fx = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [sin_table_len]Fx = undefined;
    // pi in Q30
    const pi_q30: i64 = 3373259426; // round(pi * 2^30)
    for (0..sin_table_len) |i| {
        // map i to [0, 2pi): reduce to [-pi/2, pi/2] using symmetry
        const quarter = sin_table_len / 4;
        var k: i64 = @intCast(i % (sin_table_len / 2)); // [0, pi)
        const neg = i >= sin_table_len / 2;
        if (k > quarter) k = (sin_table_len / 2) - k; // sin(pi - x) = sin(x)
        // x in Q30 = k / (len/2) * pi
        const x: i64 = @divTrunc(k * pi_q30, sin_table_len / 2);
        // Taylor: x - x^3/6 + x^5/120 - x^7/5040 + x^9/362880 (Q30)
        const x2: i64 = (x * x) >> 30;
        var term: i64 = x;
        var sum: i64 = x;
        var n: i64 = 1;
        var sign: i64 = -1;
        while (n < 13) : (n += 2) {
            term = @divTrunc((term * x2) >> 30, (n + 1) * (n + 2));
            sum += sign * term;
            sign = -sign;
        }
        // Q30 -> Q16 with rounding
        var v: i64 = (sum + (1 << 13)) >> 14;
        if (neg) v = -v;
        t[i] = @intCast(v);
    }
    break :blk t;
};

pub inline fn sin(a: Angle) Fx {
    return sin_table[a >> (16 - sin_table_bits)];
}

pub inline fn cos(a: Angle) Fx {
    return sin_table[(a +% 16384) >> (16 - sin_table_bits)];
}

/// atan2 returning a binary angle. Integer-only octant approximation with a
/// small correction term; error is well under one table step.
pub fn atan2(y: Fx, x: Fx) Angle {
    if (x == 0 and y == 0) return 0;
    const ax: i64 = if (x < 0) -@as(i64, x) else x;
    const ay: i64 = if (y < 0) -@as(i64, y) else y;
    // r in Q16, r = min/max in [0, 1]
    const swap = ay > ax;
    const r: i64 = if (swap) @divTrunc(ax << 16, ay) else @divTrunc(ay << 16, ax);
    // atan(r) ~= r*(pi/4) + 0.273*r*(1-r) (radians), in binary angle units:
    // pi/4 = 8192 units, 0.273 rad = 2847 units
    const base: i64 = (r * 8192) >> 16;
    const corr: i64 = (((r * ((1 << 16) - r)) >> 16) * 2847) >> 16;
    var a: i64 = base + corr; // [0, 8192]
    if (swap) a = 16384 - a;
    if (x < 0) a = 32768 - a;
    if (y < 0) a = 65536 - a;
    return @truncate(@as(u64, @bitCast(a)));
}

test "sin table sanity" {
    try std.testing.expectEqual(@as(Fx, 0), sin(0));
    try std.testing.expect(@abs(sin(16384) - one) <= 2);
    try std.testing.expect(@abs(sin(49152) + one) <= 2);
    try std.testing.expect(@abs(cos(0) - one) <= 2);
    try std.testing.expect(@abs(sin(8192) - 46341) <= 4); // sqrt(2)/2
}

test "atan2 sanity" {
    try std.testing.expect(@abs(@as(i32, atan2(one, one)) - 8192) < 64);
    try std.testing.expect(@abs(@as(i32, atan2(one, 0)) - 16384) < 64);
    try std.testing.expect(@abs(@as(i32, atan2(0, -one)) - 32768) < 64);
}

test "isqrt" {
    try std.testing.expectEqual(@as(u64, 3), isqrt64(15));
    try std.testing.expectEqual(@as(u64, 4), isqrt64(16));
    try std.testing.expectEqual(@as(u64, 4294967295), isqrt64(std.math.maxInt(u64)));
}
