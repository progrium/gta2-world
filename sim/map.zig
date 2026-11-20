//! Static collision grid (I1 `abi.Grid`). Lives outside the saved state: it
//! never changes during a session, and both hosts build it from the same map
//! file through `formats/`.
//!
//! Each cell is 16 bits: shape (bits 0-2), GTA2 slope code (3-8), ground
//! type (9-10), lid road arrows (11-14). How the sim reads them:
//!
//!   solid    A full block. Blocks movement within its layer; its top (z+1) is
//!            a floor. Slope codes 45-48 on a solid cell make it a diagonal
//!            wall: only the closed half is solid.
//!   slope    Codes 1-44: a ramp whose surface rises from low/denom to
//!            high/denom of a block toward `dir` (the decoding S1's
//!            `formats/gmp.zig` uses: up = toward smaller y). Codes 45-48
//!            are diagonal walls (this is how `formats.grid` writes them).
//!            Codes 49-52 (diagonal slopes) are treated as diagonal walls
//!            for now.
//!   partial  Codes 53-61: a partial block that fills part of the footprint
//!            to the full height.
//!   water    No floor. Treated as air for movement.
//!   air      Nothing.
//!
//! Every shape is reduced to one question: at point (x, y) inside the cell,
//! is there solid matter, and how high is its top? `topAt` answers it, and
//! both floors and walls are derived from it.

const std = @import("std");
const abi = @import("interfaces").abi;
const fx = @import("fixed.zig");
const Fx = fx.Fx;

pub const Grid = abi.Grid;
pub const Cell = abi.Cell;
pub const size_x = abi.map_x;
pub const size_y = abi.map_y;
pub const size_z = abi.map_z;

pub const Shape = struct {
    pub const air: u3 = 0;
    pub const solid: u3 = 1;
    pub const slope: u3 = 2;
    pub const partial: u3 = 3;
    pub const water: u3 = 4;
    /// A floor with no walls (an overpass deck): matter only in its top
    /// `slab_thickness`, so bodies pass under it.
    pub const slab: u3 = 5;
};

pub const Ground = struct {
    pub const none: u2 = 0;
    pub const road: u2 = 1;
    pub const pavement: u2 = 2;
    pub const field: u2 = 3;
};

pub const Arrow = struct {
    pub const pos_y: u4 = 1;
    pub const neg_y: u4 = 2;
    pub const pos_x: u4 = 4;
    pub const neg_x: u4 = 8;
};

pub inline fn shapeOf(c: Cell) u3 {
    return @truncate(c);
}
pub inline fn codeOf(c: Cell) u6 {
    return @truncate(c >> 3);
}
pub inline fn groundOf(c: Cell) u2 {
    return @truncate(c >> 9);
}
pub inline fn arrowsOf(c: Cell) u4 {
    return @truncate(c >> 11);
}

pub inline fn makeCell(shape: u3, code: u6, ground: u2, arrows: u4) Cell {
    return @as(Cell, shape) | (@as(Cell, code) << 3) | (@as(Cell, ground) << 9) | (@as(Cell, arrows) << 11);
}

/// Slope codes, as in the GTA2 block info. Directions: 0 up (-y), 1 down
/// (+y), 2 left (-x), 3 right (+x), naming where the high end is.
pub const Code = struct {
    pub fn ramp26(dir: u2, high_half: bool) u6 {
        return 1 + @as(u6, dir) * 2 + @intFromBool(high_half);
    }
    pub fn ramp7(dir: u2, segment: u3) u6 {
        return 9 + @as(u6, dir) * 8 + segment;
    }
    pub fn ramp45(dir: u2) u6 {
        return 41 + @as(u6, dir);
    }
    /// Diagonal wall; `corner` (0 up-left, 1 up-right, 2 down-left,
    /// 3 down-right) is the open half.
    pub fn diagonal(corner: u2) u6 {
        return 45 + @as(u6, corner);
    }
    /// Partial blocks 53-61: left, right, top, bottom, top-left, top-right,
    /// bottom-right, bottom-left, centre.
    pub fn partial(which: u4) u6 {
        return 53 + @as(u6, which);
    }
};

pub inline fn cellAt(g: *const Grid, cx: i32, cy: i32, cz: i32) Cell {
    if (cx < 0 or cy < 0 or cx >= size_x or cy >= size_y) return makeCell(Shape.solid, 0, 0, 0);
    if (cz < 0) return makeCell(Shape.solid, 0, 0, 0);
    if (cz >= size_z) return 0;
    return g.blocks[@intCast(cz)][@intCast(cy)][@intCast(cx)];
}

pub fn set(g: *Grid, cx: u32, cy: u32, cz: u32, c: Cell) void {
    g.blocks[cz][cy][cx] = c;
}

/// Ramp surface height in [0, 1] at local (u, v) in [0, 1).
fn rampFrac(code: u6, u: Fx, v: Fx) Fx {
    var dir: u2 = undefined;
    var low: i32 = undefined;
    var denom: i32 = undefined;
    switch (code) {
        1...8 => {
            const i = code - 1;
            dir = @truncate(i >> 1);
            low = i & 1;
            denom = 2;
        },
        9...40 => {
            const i = code - 9;
            dir = @truncate(i >> 3);
            low = i & 7;
            denom = 8;
        },
        41...44 => {
            dir = @truncate(code - 41);
            low = 0;
            denom = 1;
        },
        else => return fx.one,
    }
    // t: 0 at the low edge, 1 at the high edge.
    const t: Fx = switch (dir) {
        0 => fx.one - v, // high end toward -y
        1 => v,
        2 => fx.one - u, // high end toward -x
        3 => u,
    };
    return @divTrunc(fx.fromInt(low) + t, denom);
}

/// Is local point (u, v) inside the closed half of a diagonal whose open half
/// faces `corner`?
fn inDiagonal(corner: u2, u: Fx, v: Fx) bool {
    return switch (corner) {
        0 => u + v >= fx.one, // open up-left: closed is down-right
        1 => u <= v, // open up-right: closed is down-left
        2 => u >= v, // open down-left: closed is up-right
        3 => u + v <= fx.one, // open down-right: closed is up-left
    };
}

fn inPartial(which: u6, u: Fx, v: Fx) bool {
    const lo = fx.ratio(3, 8);
    const hi = fx.ratio(5, 8);
    return switch (which) {
        0 => u < lo, // left
        1 => u >= hi, // right
        2 => v < lo, // top
        3 => v >= hi, // bottom
        4 => u < lo and v < lo, // top-left
        5 => u >= hi and v < lo, // top-right
        6 => u >= hi and v >= hi, // bottom-right
        7 => u < lo and v >= hi, // bottom-left
        8 => u >= fx.ratio(1, 4) and u < fx.ratio(3, 4) and v >= fx.ratio(1, 4) and v < fx.ratio(3, 4), // centre
        else => false,
    };
}

/// Height of solid matter at world point (x, y) in cell layer `cz`, relative
/// to the cell's base, in [0, 1]; null if the point is not inside matter.
pub fn topInCell(c: Cell, x: Fx, y: Fx) ?Fx {
    const u = x & (fx.one - 1);
    const v = y & (fx.one - 1);
    const code = codeOf(c);
    switch (shapeOf(c)) {
        Shape.solid => {
            if (code >= 45 and code <= 48) return if (inDiagonal(@truncate(code - 45), u, v)) fx.one else null;
            return fx.one;
        },
        Shape.slope => {
            if (code >= 1 and code <= 44) return rampFrac(code, u, v);
            if (code >= 45 and code <= 48) return if (inDiagonal(@truncate(code - 45), u, v)) fx.one else null;
            if (code >= 49 and code <= 52) return if (inDiagonal(@truncate(code - 49), u, v)) fx.one else null;
            return fx.one;
        },
        Shape.slab => return fx.one,
        Shape.partial => {
            if (code >= 53 and code <= 61) return if (inPartial(code - 53, u, v)) fx.one else null;
            return fx.one;
        },
        else => return null,
    }
}

/// Absolute top of matter in layer `cz` at (x, y), or null.
pub fn topAt(g: *const Grid, x: Fx, y: Fx, cz: i32) ?Fx {
    const c = cellAt(g, fx.toInt(x), fx.toInt(y), cz);
    const t = topInCell(c, x, y) orelse return null;
    return fx.fromInt(cz) + t;
}

/// Highest step a ped climbs without being blocked (a ramp joint). Cars use
/// a larger step (`tuning`) so the corners of a car on a ramp do not catch
/// on the block at its top; a full block (1.0) always blocks both.
pub const ped_step = fx.ratio(5, 16);
/// Height of a body for wall tests: matter whose base is below z + this and
/// whose top is above z + step blocks. Half a block, so a ped walks up a
/// ramp under a one-block ceiling.
pub const body_height = fx.half;
/// Matter in a slab cell: the top eighth.
pub const slab_thickness = fx.one >> 3;

/// Does matter at (x, y) block a body standing at height z?
pub fn blocks(g: *const Grid, x: Fx, y: Fx, z: Fx, step: Fx) bool {
    var l = fx.toInt(z);
    // Layers whose base is strictly below the top of the body.
    while (l <= fx.toInt(z + body_height - 1)) : (l += 1) {
        if (topAt(g, x, y, l)) |top| {
            const bottom = if (shapeOf(cellAt(g, fx.toInt(x), fx.toInt(y), l)) == Shape.slab) top - slab_thickness else fx.fromInt(l);
            if (top > z + step and bottom < z + body_height) return true;
        }
    }
    return false;
}

/// Is the column under (x, y) empty all the way down from height z (no
/// floor at any depth)? Real maps have such voids at their edges and around
/// some structures; the original's water may be among them. Bodies treat a
/// void as a wall rather than falling out of the world.
pub fn isVoid(g: *const Grid, x: Fx, y: Fx, z: Fx) bool {
    var l = fx.toInt(z);
    if (l >= size_z) l = size_z - 1;
    while (l >= 0) : (l -= 1) {
        if (topAt(g, x, y, l) != null) return false;
    }
    return true;
}

/// `blocks`, or a void below: what stops a ped or a car.
pub fn blocksBody(g: *const Grid, x: Fx, y: Fx, z: Fx, step: Fx) bool {
    return blocks(g, x, y, z, step) or isVoid(g, x, y, z + step);
}

/// The floor under (x, y) for a body at height z: the highest top of matter
/// at or below z + step. Returns -1 block when there is nothing.
pub fn floorAt(g: *const Grid, x: Fx, y: Fx, z: Fx, step: Fx) Fx {
    var l = fx.toInt(z + step);
    if (l >= size_z) l = size_z - 1;
    while (l >= 0) : (l -= 1) {
        if (topAt(g, x, y, l)) |top| {
            if (top <= z + step) return top;
        }
    }
    return -fx.one;
}

/// Ground type and arrows of the floor cell under (x, y) at height z.
pub fn floorCell(g: *const Grid, x: Fx, y: Fx, z: Fx, step: Fx) Cell {
    var l = fx.toInt(z + step);
    if (l >= size_z) l = size_z - 1;
    while (l >= 0) : (l -= 1) {
        const c = cellAt(g, fx.toInt(x), fx.toInt(y), l);
        if (topInCell(c, x, y)) |t| {
            if (fx.fromInt(l) + t <= z + step) return c;
        }
    }
    return 0;
}

/// Hash of the grid for replay files (FNV-1a over cells).
pub fn gridHash(g: *const Grid) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (std.mem.asBytes(g)) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

test "ramp heights follow the S1 decoding" {
    // code 41: 45 degree, high end up (-y): top at v=0 is ~1, at v~1 is ~0.
    const c = makeCell(Shape.slope, Code.ramp45(0), 0, 0);
    try std.testing.expect(topInCell(c, fx.ratio(1, 2), 0).? == fx.one);
    try std.testing.expect(topInCell(c, fx.ratio(1, 2), fx.ratio(3, 4)).? == fx.ratio(1, 4));
    // 26 degree right, high half: 0.5 .. 1.0 along +x.
    const d = makeCell(Shape.slope, Code.ramp26(3, true), 0, 0);
    try std.testing.expectEqual(fx.half, topInCell(d, 0, 0).?);
    try std.testing.expectEqual(fx.ratio(3, 4), topInCell(d, fx.half, 0).?);
    // 7 degree down, segment 3: 3/8 .. 4/8 along +y.
    const e = makeCell(Shape.slope, Code.ramp7(1, 3), 0, 0);
    try std.testing.expectEqual(fx.ratio(3, 8), topInCell(e, 0, 0).?);
}

test "floors and walls" {
    const g = try std.testing.allocator.create(Grid);
    defer std.testing.allocator.destroy(g);
    @memset(std.mem.asBytes(g), 0);
    set(g, 10, 10, 0, makeCell(Shape.solid, 0, Ground.road, 0));
    set(g, 11, 10, 0, makeCell(Shape.solid, 0, Ground.road, 0));
    set(g, 11, 10, 1, makeCell(Shape.solid, 0, 0, 0));
    const p = fx.fromInt(10) + fx.half;
    try std.testing.expectEqual(fx.one, floorAt(g, p, p, fx.one, ped_step));
    try std.testing.expect(!blocks(g, p, p, fx.one, ped_step));
    try std.testing.expect(blocks(g, fx.fromInt(11) + fx.half, p, fx.one, ped_step));
    // Standing on top of the wall, it does not block.
    try std.testing.expect(!blocks(g, fx.fromInt(11) + fx.half, p, fx.fromInt(2), ped_step));
    try std.testing.expectEqual(fx.fromInt(2), floorAt(g, fx.fromInt(11) + fx.half, p, fx.fromInt(2), ped_step));
    // Nothing under (5, 5).
    try std.testing.expectEqual(-fx.one, floorAt(g, fx.fromInt(5), fx.fromInt(5), fx.one, ped_step));
}

test "slabs are floors you pass under" {
    const g = try std.testing.allocator.create(Grid);
    defer std.testing.allocator.destroy(g);
    @memset(std.mem.asBytes(g), 0);
    // Road at layer 0, an overpass deck at layer 1 over (11, 10).
    set(g, 10, 10, 0, makeCell(Shape.solid, 0, Ground.road, 0));
    set(g, 11, 10, 0, makeCell(Shape.solid, 0, Ground.road, 0));
    set(g, 11, 10, 1, makeCell(Shape.slab, 0, Ground.road, 0));
    const p = fx.fromInt(10) + fx.half;
    const under = fx.fromInt(11) + fx.half;
    const car_step = fx.ratio(7, 10);
    // On the road below: the deck neither blocks nor counts as the floor.
    try std.testing.expect(!blocks(g, under, p, fx.one, car_step));
    try std.testing.expect(!blocks(g, under, p, fx.one, ped_step));
    try std.testing.expectEqual(fx.one, floorAt(g, under, p, fx.one, car_step));
    // On the deck: its top is the floor.
    try std.testing.expectEqual(fx.fromInt(2), floorAt(g, under, p, fx.fromInt(2), ped_step));
    // A body whose height reaches the deck's underside is stopped by it.
    try std.testing.expect(blocks(g, under, p, fx.fromInt(1) + fx.half, ped_step));
}
