//! `.gci` car handling files, as described in docs/behaviour/car-handling.md
//! ("`.gci` car record"). The file is text: comments in `{ }`, tokens split
//! by whitespace and parentheses, each token a number that becomes a fixed-
//! size binary value packed back to back. A record is 72 bytes: model,
//! turbo, value and a padding byte, then 17 fractions (14 fraction bits).
//!
//! Written from the notes alone; numbers are returned as 16.16 fixed point.

const std = @import("std");

pub const record_bytes = 72;
pub const fraction_count = 17;

pub const Error = error{ BadToken, BadLength, OutOfMemory };

/// The 17 fractional values, in file order.
pub const Field = enum(u5) {
    mass,
    front_drive_bias,
    front_mass_bias,
    brake_friction,
    turn_in,
    turn_ratio,
    rear_end_stability,
    handbrake_slide,
    thrust,
    max_speed,
    anti_strength,
    skid_threshold,
    gear1_multiplier,
    gear2_multiplier,
    gear3_multiplier,
    gear2_speed,
    gear3_speed,
};

pub const Record = struct {
    model: u8,
    turbo: bool,
    value: u8,
    /// 16.16 fixed point, indexed by `Field`.
    f: [fraction_count]i32,

    pub fn get(r: *const Record, field: Field) i32 {
        return r.f[@intFromEnum(field)];
    }
};

/// Parse a whole file. The caller frees the slice.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) Error![]Record {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '{') {
            while (i < text.len and text[i] != '}') i += 1;
            i += 1;
            continue;
        }
        if (isSep(ch)) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and !isSep(text[j]) and text[j] != '{') j += 1;
        try appendToken(gpa, &bytes, text[i..j]);
        i = j;
    }
    if (bytes.items.len % record_bytes != 0) return error.BadLength;
    const n = bytes.items.len / record_bytes;
    const out = try gpa.alloc(Record, n);
    for (out, 0..) |*r, k| {
        const b = bytes.items[k * record_bytes ..][0..record_bytes];
        r.model = b[0];
        r.turbo = b[1] != 0;
        r.value = b[2];
        for (&r.f, 0..) |*v, fi| {
            const raw = std.mem.readInt(i32, b[4 + fi * 4 ..][0..4], .little);
            v.* = raw << 2; // 14 fraction bits to 16
        }
    }
    return out;
}

fn isSep(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == '(' or ch == ')';
}

/// `[-][b|w|l|f][h][-]digits`
fn appendToken(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tok: []const u8) Error!void {
    var t = tok;
    var neg = false;
    if (t.len > 0 and t[0] == '-') {
        neg = true;
        t = t[1..];
    }
    var kind: u8 = 'b';
    if (t.len > 0 and (t[0] == 'b' or t[0] == 'w' or t[0] == 'l' or t[0] == 'f')) {
        kind = t[0];
        t = t[1..];
    }
    var hex = false;
    if (t.len > 0 and t[0] == 'h') {
        hex = true;
        t = t[1..];
    }
    if (t.len > 0 and t[0] == '-') {
        neg = !neg;
        t = t[1..];
    }
    if (t.len == 0) return error.BadToken;
    var v: i64 = 0;
    if (kind == 'f') {
        // Decimal with at most one '.', to 14 fraction bits.
        var int_part: i64 = 0;
        var frac: i64 = 0;
        var scale: i64 = 1;
        var seen_dot = false;
        for (t) |ch| {
            if (ch == '.') {
                if (seen_dot) return error.BadToken;
                seen_dot = true;
            } else if (ch >= '0' and ch <= '9') {
                if (seen_dot) {
                    if (scale < 1_000_000_000) {
                        frac = frac * 10 + (ch - '0');
                        scale *= 10;
                    }
                } else int_part = int_part * 10 + (ch - '0');
            } else return error.BadToken;
        }
        v = (int_part << 14) + @divTrunc(frac << 14, scale);
    } else {
        const base: u8 = if (hex) 16 else 10;
        for (t) |ch| {
            const d: i64 = if (ch >= '0' and ch <= '9') ch - '0' else if (hex and ch >= 'A' and ch <= 'F') ch - 'A' + 10 else return error.BadToken;
            v = v * base + d;
        }
    }
    if (neg) v = -v;
    const size: usize = switch (kind) {
        'b' => 1,
        'w' => 2,
        else => 4,
    };
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @truncate(@as(u64, @bitCast(v))), .little);
    try out.appendSlice(gpa, buf[0..size]);
}

test "a record parses into model, turbo and 16.16 fractions" {
    const text =
        \\{A car}
        \\3 {model} 1 {turbo} 50 0
        \\f16.500 f1.000 f0.500 f1.750 f0.145 f0.450 f1.250 f0.180 f0.152
        \\f0.245 f1.000 f0.065 f0.550 f0.680 f1.000 f0.107 f0.165
    ;
    const recs = try parse(std.testing.allocator, text);
    defer std.testing.allocator.free(recs);
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    const r = recs[0];
    try std.testing.expectEqual(@as(u8, 3), r.model);
    try std.testing.expect(r.turbo);
    try std.testing.expectEqual(@as(i32, 16 << 16) + (1 << 15), r.get(.mass));
    // 0.245 to 14 bits, then to 16.
    try std.testing.expectEqual(@as(i32, @divTrunc(245 << 14, 1000) << 2), r.get(.max_speed));
    try std.testing.expectEqual(@as(i32, 1 << 16), r.get(.gear3_multiplier));
}

test "a short file is rejected" {
    try std.testing.expectError(error.BadLength, parse(std.testing.allocator, "1 2 3"));
    try std.testing.expectError(error.BadToken, parse(std.testing.allocator, "1 x"));
}
