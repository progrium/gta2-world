//! Scripted bot inputs. Integer-only and independent of sim state, so the same
//! input stream can be regenerated anywhere or recorded to a file and replayed.

const sim = @import("sim");
const input = sim.input;
const Button = input.Button;

pub const Bot = struct {
    rng: u32,
    steer: i32 = 0,
    throttle: i32 = 100,
    hold: u32 = 0,
    aim: u16 = 0,
    seq: u16 = 0,

    pub fn init(seed: u32, player: u32) Bot {
        return .{ .rng = (seed ^ (player *% 0x9E3779B9)) | 1 };
    }

    fn next(b: *Bot) u32 {
        b.rng ^= b.rng << 13;
        b.rng ^= b.rng >> 17;
        b.rng ^= b.rng << 5;
        return b.rng;
    }

    pub fn frame(b: *Bot) input.Frame {
        if (b.hold == 0) {
            b.hold = 5 + next(b) % 40;
            const r = next(b) % 10;
            b.steer = if (r < 4) 0 else @as(i32, @intCast(next(b) % 255)) - 127;
            b.throttle = if (r == 9) -80 else 60 + @as(i32, @intCast(next(b) % 68));
            b.aim = @truncate(next(b));
        } else b.hold -= 1;
        var buttons: u16 = 0;
        const r = next(b) % 1000;
        if (r < 120) buttons |= Button.fire;
        if (r >= 990) buttons |= Button.enter_exit;
        if (r >= 900 and r < 960) buttons |= Button.handbrake;
        b.seq +%= 1;
        return .{
            .steer = @intCast(b.steer),
            .throttle = @intCast(b.throttle),
            .buttons = buttons,
            .aim = b.aim,
            .seq = b.seq,
        };
    }
};

/// Fill `out` (num_players frames) with one tick of bot input.
pub fn tick(bots: []Bot, out: []input.Frame) void {
    for (bots, out) |*b, *f| f.* = b.frame();
}
