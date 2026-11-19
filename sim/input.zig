//! I2 input frame: 8 bytes per player per tick.

pub const Frame = extern struct {
    steer: i8,
    throttle: i8,
    buttons: u16,
    aim: u16,
    seq: u16,

    pub const zero: Frame = .{ .steer = 0, .throttle = 0, .buttons = 0, .aim = 0, .seq = 0 };
};

comptime {
    if (@sizeOf(Frame) != 8) @compileError("I2 frame must be 8 bytes");
}

pub const Button = struct {
    pub const fire: u16 = 1 << 0;
    pub const enter_exit: u16 = 1 << 1;
    pub const handbrake: u16 = 1 << 2;
};
