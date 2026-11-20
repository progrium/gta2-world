//! I2. Input frame: 8 bytes per player per tick.
//!
//! Frozen interface. Spec: interfaces/I2-input-frame.md. Changing anything in
//! this file needs a written proposal accepted by the owners of every
//! workstream that uses it (A, C, D, E).
//!
//! Wire and memory layout are the same: little-endian, no padding.
//!   offset 0  steer    i8   -127..127, + = turn clockwise (right on screen)
//!   offset 1  throttle i8   -127..127, + = accelerate / walk forward, - = brake / reverse
//!   offset 2  buttons  u16  bit mask, see `Button`
//!   offset 4  aim      u16  binary angle (65536 = one turn), see I1 angle convention
//!   offset 6  seq      u16  low 16 bits of the tick this frame drives

const std = @import("std");

pub const Frame = extern struct {
    steer: i8,
    throttle: i8,
    buttons: u16,
    aim: u16,
    seq: u16,

    pub const size = 8;

    /// The neutral frame: no input. `seq` must still be stamped.
    pub fn neutral(seq: u16) Frame {
        return .{ .steer = 0, .throttle = 0, .buttons = 0, .aim = 0, .seq = seq };
    }

    /// Normalise a frame received from an untrusted source. The sim may assume
    /// every frame it is given has passed through here.
    pub fn sanitize(f: Frame) Frame {
        var out = f;
        if (out.steer == -128) out.steer = -127;
        if (out.throttle == -128) out.throttle = -127;
        out.buttons &= Button.defined_mask;
        if (out.buttons & Button.direct == 0) out.aim = 0;
        return out;
    }

    pub fn encode(f: Frame, out: *[size]u8) void {
        out[0] = @bitCast(f.steer);
        out[1] = @bitCast(f.throttle);
        std.mem.writeInt(u16, out[2..4], f.buttons, .little);
        std.mem.writeInt(u16, out[4..6], f.aim, .little);
        std.mem.writeInt(u16, out[6..8], f.seq, .little);
    }

    pub fn decode(in: *const [size]u8) Frame {
        return .{
            .steer = @bitCast(in[0]),
            .throttle = @bitCast(in[1]),
            .buttons = std.mem.readInt(u16, in[2..4], .little),
            .aim = std.mem.readInt(u16, in[4..6], .little),
            .seq = std.mem.readInt(u16, in[6..8], .little),
        };
    }

    /// Content equality, ignoring `seq`. Used for "repeat the previous frame".
    pub fn sameControls(a: Frame, b: Frame) bool {
        return a.steer == b.steer and a.throttle == b.throttle and a.buttons == b.buttons and a.aim == b.aim;
    }
};

comptime {
    std.debug.assert(@sizeOf(Frame) == 8);
    std.debug.assert(@offsetOf(Frame, "buttons") == 2);
    std.debug.assert(@offsetOf(Frame, "aim") == 4);
    std.debug.assert(@offsetOf(Frame, "seq") == 6);
}

/// Button bits. Bits marked reserved must be sent as zero and are cleared by
/// `Frame.sanitize`. New bits are added only by interface proposal.
pub const Button = struct {
    /// Shoot the current weapon. Held = keep firing.
    pub const fire: u16 = 1 << 0;
    /// Enter or leave a vehicle. Acted on at the rising edge.
    pub const enter_exit: u16 = 1 << 1;
    /// Handbrake in a vehicle, jump on foot (the original shares one key).
    pub const handbrake_jump: u16 = 1 << 2;
    /// Next / previous weapon. Rising edge.
    pub const weapon_next: u16 = 1 << 3;
    pub const weapon_prev: u16 = 1 << 4;
    /// Horn in a vehicle; the original's "special" key.
    pub const special: u16 = 1 << 5;
    /// On-foot direct mode: `aim` is the heading to turn toward and
    /// `throttle` (0..127) is the walking speed; `steer` is ignored.
    /// Clear = tank controls: `steer` turns, `throttle` walks forward/back.
    /// Ignored in a vehicle.
    pub const direct: u16 = 1 << 6;
    /// Run modifier on foot (keyboard shift / stick fully deflected).
    pub const run: u16 = 1 << 7;
    // Bits 8..15 reserved.

    pub const defined_mask: u16 = 0x00FF;
    /// Buttons the sim acts on at their rising edge, not while held.
    pub const edge_mask: u16 = enter_exit | weapon_next | weapon_prev;
};

/// Map a tick to the `seq` carried in a frame.
pub inline fn seqOf(tick: u32) u16 {
    return @truncate(tick);
}

/// Expand a 16-bit `seq` to the full tick nearest to `reference`
/// (serial-number arithmetic, valid while |tick - reference| < 32768,
/// about 18 minutes at 30 Hz).
pub fn expandSeq(seq: u16, reference: u32) u32 {
    const diff: i16 = @bitCast(seq -% @as(u16, @truncate(reference)));
    return reference +% @as(u32, @bitCast(@as(i32, diff)));
}

/// Quantise an analog value in [-1, 1] given as a signed fraction num/den to
/// an axis. Rounds half away from zero, clamps to -127..127.
/// (Shells use the TS twin `quantizeAxis`; this exists for tools and bots.)
pub fn axisFromRatio(num: i32, den: i32) i8 {
    if (den == 0) return 0;
    const n: i64 = @as(i64, num) * 127;
    const d: i64 = den;
    var q = @divTrunc(2 * n + (if ((n < 0) != (d < 0)) -d else d), 2 * d);
    if (q > 127) q = 127;
    if (q < -127) q = -127;
    return @intCast(q);
}

test "frame round trip and sanitize" {
    const f: Frame = .{ .steer = -128, .throttle = 100, .buttons = 0xFF41, .aim = 0x4000, .seq = 7 };
    var b: [8]u8 = undefined;
    f.encode(&b);
    try std.testing.expectEqual(f, Frame.decode(&b));
    const s = f.sanitize();
    try std.testing.expectEqual(@as(i8, -127), s.steer);
    try std.testing.expectEqual(@as(u16, 0x41), s.buttons);
    try std.testing.expectEqual(@as(u16, 0x4000), s.aim);
    const t = (Frame{ .steer = 0, .throttle = 0, .buttons = Button.fire, .aim = 123, .seq = 0 }).sanitize();
    try std.testing.expectEqual(@as(u16, 0), t.aim);
}

test "seq expansion" {
    try std.testing.expectEqual(@as(u32, 70000), expandSeq(seqOf(70000), 69990));
    try std.testing.expectEqual(@as(u32, 70000), expandSeq(seqOf(70000), 70020));
    try std.testing.expectEqual(@as(u32, 65535), expandSeq(0xFFFF, 65540));
    try std.testing.expectEqual(@as(u32, 0), expandSeq(0, 5));
}

test "axis quantisation" {
    try std.testing.expectEqual(@as(i8, 127), axisFromRatio(1, 1));
    try std.testing.expectEqual(@as(i8, -127), axisFromRatio(-3, 2));
    try std.testing.expectEqual(@as(i8, 64), axisFromRatio(1, 2)); // 63.5 -> 64
    try std.testing.expectEqual(@as(i8, -64), axisFromRatio(-1, 2));
    try std.testing.expectEqual(@as(i8, 0), axisFromRatio(0, 5));
}
