//! Static collision grid. Lives outside the saved state: it never changes
//! during a session, and both hosts load it from the same map file.
//!
//! 256 x 256 x 8 blocks, one byte each:
//!   bits 0-2: type (air, solid, slope)
//!   bits 3-4: slope direction for slope blocks (which way the ramp rises)

const fx = @import("fixed.zig");
const Fx = fx.Fx;

pub const size_x = 256;
pub const size_y = 256;
pub const size_z = 8;

pub const Type = struct {
    pub const air: u8 = 0;
    pub const solid: u8 = 1;
    pub const slope: u8 = 2;
};

pub const Rise = struct {
    pub const pos_x: u8 = 0;
    pub const neg_x: u8 = 1;
    pub const pos_y: u8 = 2;
    pub const neg_y: u8 = 3;
};

pub inline fn makeSlope(rise: u8) u8 {
    return Type.slope | (rise << 3);
}

pub const Grid = extern struct {
    /// [z][y][x]
    blocks: [size_z][size_y][size_x]u8,

    pub inline fn at(g: *const Grid, cx: i32, cy: i32, cz: i32) u8 {
        if (cx < 0 or cy < 0 or cx >= size_x or cy >= size_y) return Type.solid;
        if (cz < 0) return Type.solid;
        if (cz >= size_z) return Type.air;
        return g.blocks[@intCast(cz)][@intCast(cy)][@intCast(cx)];
    }

    pub inline fn isWall(g: *const Grid, cx: i32, cy: i32, cz: i32) bool {
        return (g.at(cx, cy, cz) & 7) == Type.solid;
    }

    pub fn set(g: *Grid, cx: u32, cy: u32, cz: u32, v: u8) void {
        g.blocks[cz][cy][cx] = v;
    }
};

/// Height of a slope block's surface above its base at (x, y), in [0, 1].
pub fn slopeFrac(b: u8, x: Fx, y: Fx) Fx {
    const fxp = x & (fx.one - 1);
    const fyp = y & (fx.one - 1);
    return switch ((b >> 3) & 3) {
        Rise.pos_x => fxp,
        Rise.neg_x => fx.one - fxp,
        Rise.pos_y => fyp,
        else => fx.one - fyp,
    };
}

/// Walkable surface height under (x, y) for a body currently near height z,
/// or null if there is nothing to stand on (the body falls).
pub fn surface(g: *const Grid, x: Fx, y: Fx, z: Fx) ?Fx {
    const cx = fx.toInt(x);
    const cy = fx.toInt(y);
    const l = fx.toInt(z + fx.ratio(1, 8));
    const b = g.at(cx, cy, l);
    if ((b & 7) == Type.slope) return fx.fromInt(l) + slopeFrac(b, x, y);
    if ((b & 7) == Type.solid) return fx.fromInt(l + 1); // pushed up onto a step
    const below = g.at(cx, cy, l - 1);
    return switch (below & 7) {
        Type.solid => fx.fromInt(l),
        Type.slope => fx.fromInt(l - 1) + slopeFrac(below, x, y),
        else => null,
    };
}
