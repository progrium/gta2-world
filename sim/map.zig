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
//!            Codes 49-52 (three-sided diagonal blocks) have a flat top over
//!            the whole block and are a diagonal wall along the closed half
//!            (shape-and-map-collision.md 3.1, map-geometry.md 3.3).
//!   partial  Codes 53-61: a partial block. Its top is a floor over part of
//!            the footprint; it never blocks a body from the side (the
//!            original counts it as missing for wall tests).
//!   water    Deep water (car-height.md, ped-movement.md 3.7): a surface at
//!            the top of the cell, like a slab, that bodies rest on. Peds on
//!            it drown; cars on it lose drive and sink (the sim's rules).
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
            // Three-sided diagonal blocks: a flat top over the whole
            // block (map-geometry.md 3.3); `blocks` makes only the closed
            // half a wall.
            if (code >= 49 and code <= 52) return fx.one;
            return fx.one;
        },
        Shape.slab, Shape.water => return fx.one,
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
            const bottom = matterBottom(cellAt(g, fx.toInt(x), fx.toInt(y), l), x, y, l, top);
            if (top > z + step and bottom < z + body_height) return true;
        }
    }
    return false;
}

/// Bottom of the matter at (x, y) in a cell of layer `l` whose top there is
/// `top`. Most matter fills the layer; these are only a floor (their top
/// `slab_thickness`), which bodies stand on but are never walled by:
///   - slabs and deep water;
///   - partial blocks 53-61, which never block in the original
///     (shape-and-map-collision.md 3.2: they count as missing);
///   - the open half of a three-sided diagonal block 49-52, whose closed
///     half is the diagonal wall (3.4).
fn matterBottom(c: Cell, x: Fx, y: Fx, l: i32, top: Fx) Fx {
    const floor_only = switch (shapeOf(c)) {
        Shape.slab, Shape.water, Shape.partial => true,
        Shape.slope => blk: {
            const code = codeOf(c);
            if (code < 49 or code > 52) break :blk false;
            break :blk !inDiagonal(@truncate(code - 49), x & (fx.one - 1), y & (fx.one - 1));
        },
        else => false,
    };
    return if (floor_only) top - slab_thickness else fx.fromInt(l);
}

/// Is the column under (x, y) empty all the way down from height z (no
/// floor whose top is at or below z)? Real maps have such voids at their
/// edges and around some structures, often under a deck that floats above
/// them; matter above z (that deck) is not a floor and does not count.
/// Bodies treat a void as a wall rather than falling out of the world.
pub fn isVoid(g: *const Grid, x: Fx, y: Fx, z: Fx) bool {
    return floorAt(g, x, y, z, 0) < 0;
}

/// The map edge at the top level (shape-and-map-collision.md 3.5,
/// car-collision.md 3.7): at height 7 and above, a point less than one block
/// from any side of the map is against an invisible straight wall. Lower
/// levels rely on the map's own blocks (and voids).
pub const edge_level: i32 = 7;
pub fn pastTopEdge(x: Fx, y: Fx, z: Fx) bool {
    if (z < fx.fromInt(edge_level)) return false;
    const lo = fx.one;
    const hi_x = fx.fromInt(size_x - 1);
    const hi_y = fx.fromInt(size_y - 1);
    return x < lo or y < lo or x > hi_x or y > hi_y;
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

/// Is the floor under (x, y) at height z deep water?
pub fn waterAt(g: *const Grid, x: Fx, y: Fx, z: Fx) bool {
    return shapeOf(floorCell(g, x, y, z, fx.ratio(1, 16))) == Shape.water;
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

// ---------------------------------------------------------------------------
// Wall faces (shape-and-map-collision.md 3.2-3.3)
//
// A wall is a one-block line on a block face, read from `Grid.walls`. A
// vertical line x = X (between y = Y and Y + 1) is a wall at level l if the
// block west of it has its right face flagged or the block east of it has
// its left face flagged; likewise for horizontal lines with bottom and top.

pub const wall_left = abi.wall_left;
pub const wall_right = abi.wall_right;
pub const wall_top = abi.wall_top;
pub const wall_bottom = abi.wall_bottom;
/// Shift for the bullet-wall bits: 0 for bodies, this for projectiles.
pub const bullet = abi.bullet_wall_shift;

inline fn wallBits(g: *const Grid, cx: i32, cy: i32, cz: i32) u8 {
    if (cx < 0 or cy < 0 or cz < 0 or cx >= size_x or cy >= size_y or cz >= size_z) return 0;
    return g.walls[@intCast(cz)][@intCast(cy)][@intCast(cx)];
}

/// Wall on the line x = `x_line` for y in [y_cell, y_cell + 1) at level `cz`.
pub fn wallX(g: *const Grid, x_line: i32, y_cell: i32, cz: i32, shift: u3) bool {
    return (wallBits(g, x_line - 1, y_cell, cz) >> shift) & wall_right != 0 or
        (wallBits(g, x_line, y_cell, cz) >> shift) & wall_left != 0;
}

/// Wall on the line y = `y_line` for x in [x_cell, x_cell + 1) at level `cz`.
pub fn wallY(g: *const Grid, x_cell: i32, y_line: i32, cz: i32, shift: u3) bool {
    return (wallBits(g, x_cell, y_line - 1, cz) >> shift) & wall_bottom != 0 or
        (wallBits(g, x_cell, y_line, cz) >> shift) & wall_top != 0;
}

/// Do intervals [a0, a1] (either order) and (-h, h) overlap?
inline fn spans(a0: Fx, a1: Fx, h: Fx) bool {
    return @min(a0, a1) < h and @max(a0, a1) > -h;
}

/// A ground rectangle: centre, unit axis (cos, sin) of its length, and half
/// length `a` along it and half width `b` across it.
// ---------------------------------------------------------------------------
// Surfaces (`Grid.surface`, W0): red arrows and electrified lids.

pub const Surface = struct {
    pub const red_pos_y = abi.surface_red_pos_y;
    pub const red_neg_y = abi.surface_red_neg_y;
    pub const red_pos_x = abi.surface_red_pos_x;
    pub const red_neg_x = abi.surface_red_neg_x;
    pub const red_mask = abi.surface_red_mask;
    pub const electrified = abi.surface_electrified;
};

/// Surface bits of cell (cx, cy, cz); 0 outside the map.
pub inline fn surfaceAt(g: *const Grid, cx: i32, cy: i32, cz: i32) abi.SurfaceBits {
    if (cx < 0 or cy < 0 or cz < 0 or cx >= size_x or cy >= size_y or cz >= size_z) return 0;
    return g.surface[@intCast(cz)][@intCast(cy)][@intCast(cx)];
}

/// Surface bits of the floor cell under (x, y) for a body at height z (the
/// cell `floorCell` finds); 0 with no floor.
pub fn floorSurface(g: *const Grid, x: Fx, y: Fx, z: Fx, step: Fx) abi.SurfaceBits {
    var l = fx.toInt(z + step);
    if (l >= size_z) l = size_z - 1;
    while (l >= 0) : (l -= 1) {
        const c = cellAt(g, fx.toInt(x), fx.toInt(y), l);
        if (topInCell(c, x, y)) |t| {
            if (fx.fromInt(l) + t <= z + step) return surfaceAt(g, fx.toInt(x), fx.toInt(y), l);
        }
    }
    return 0;
}

/// The red arrows of a surface byte, in `Arrow` bit order (as `arrowsOf`).
pub inline fn redArrowsOf(s: abi.SurfaceBits) u4 {
    return @truncate(s & abi.surface_red_mask);
}

pub const Rect = struct {
    x: Fx,
    y: Fx,
    cos: Fx,
    sin: Fx,
    a: Fx,
    b: Fx,

    pub fn square(x: Fx, y: Fx, half: Fx) Rect {
        return .{ .x = x, .y = y, .cos = fx.one, .sin = 0, .a = half, .b = half };
    }

    /// Does the segment from (x0, y0) to (x0 + dx, y0 + dy) cross the
    /// rectangle? Separating axes: the segment's own two (covered by the
    /// caller's bounding-box loop) and the rectangle's two.
    fn crosses(r: Rect, x0: Fx, y0: Fx, dx: Fx, dy: Fx) bool {
        const rx = x0 - r.x;
        const ry = y0 - r.y;
        const p0 = fx.mul(rx, r.cos) + fx.mul(ry, r.sin);
        const p1 = p0 + fx.mul(dx, r.cos) + fx.mul(dy, r.sin);
        if (!spans(p0, p1, r.a)) return false;
        const q0 = fx.mul(ry, r.cos) - fx.mul(rx, r.sin);
        const q1 = q0 + fx.mul(dy, r.cos) - fx.mul(dx, r.sin);
        return spans(q0, q1, r.b);
    }
};

/// Does a body with ground rectangle `r`, standing at height z, cross a wall
/// face? Faces are checked at the levels from z + `step` up to the top of
/// the body (z + half a block): a level whose top is within a step of the
/// body's feet is one it is climbing onto, as at the top of a ramp, where
/// the block the ramp meets has its face flagged. Touching a face exactly
/// does not count, so a body can stand flush against a wall and slide
/// along it.
pub fn rectHitsWall(g: *const Grid, r: Rect, z: Fx, step: Fx) bool {
    const ca = fx.abs(r.cos);
    const sa = fx.abs(r.sin);
    const ex = fx.mul(r.a, ca) + fx.mul(r.b, sa);
    const ey = fx.mul(r.a, sa) + fx.mul(r.b, ca);
    const x_lo = fx.toInt(r.x - ex);
    const x_hi = fx.toInt(r.x + ex - 1);
    const y_lo = fx.toInt(r.y - ey);
    const y_hi = fx.toInt(r.y + ey - 1);
    var l = @max(0, fx.toInt(z + step));
    const l_hi = @min(size_z - 1, @max(l, fx.toInt(z + body_height - 1)));
    while (l <= l_hi) : (l += 1) {
        // Vertical lines strictly inside the box's x extent.
        var xl = x_lo + 1;
        while (xl <= x_hi) : (xl += 1) {
            var yc = y_lo;
            while (yc <= y_hi) : (yc += 1) {
                if (wallX(g, xl, yc, l, 0) and r.crosses(fx.fromInt(xl), fx.fromInt(yc), 0, fx.one)) return true;
            }
        }
        var yl = y_lo + 1;
        while (yl <= y_hi) : (yl += 1) {
            var xc = x_lo;
            while (xc <= x_hi) : (xc += 1) {
                if (wallY(g, xc, yl, l, 0) and r.crosses(fx.fromInt(xc), fx.fromInt(yl), fx.one, 0)) return true;
            }
        }
    }
    return false;
}

/// Does a straight move from (x0, y0) to (x1, y1) at height z cross a
/// wall face (`shift` 0) or a bullet wall (`shift` = `bullet`)? Each block
/// boundary crossed is looked up at the point where the move crosses it.
pub fn moveHitsWall(g: *const Grid, x0: Fx, y0: Fx, x1: Fx, y1: Fx, z: Fx, shift: u3) bool {
    const l = fx.toInt(z);
    if (l < 0 or l >= size_z) return false;
    const dx = x1 - x0;
    const dy = y1 - y0;
    const cx0 = fx.toInt(x0);
    const cx1 = fx.toInt(x1);
    if (cx0 != cx1) {
        const step: i32 = if (cx1 > cx0) 1 else -1;
        var cx = cx0;
        while (cx != cx1) : (cx += step) {
            const line = if (step > 0) cx + 1 else cx;
            const y = y0 + @as(Fx, @intCast(@divTrunc(@as(i64, fx.fromInt(line) - x0) * dy, dx)));
            if (wallX(g, line, fx.toInt(y), l, shift)) return true;
        }
    }
    const cy0 = fx.toInt(y0);
    const cy1 = fx.toInt(y1);
    if (cy0 != cy1) {
        const step: i32 = if (cy1 > cy0) 1 else -1;
        var cy = cy0;
        while (cy != cy1) : (cy += step) {
            const line = if (step > 0) cy + 1 else cy;
            const x = x0 + @as(Fx, @intCast(@divTrunc(@as(i64, fx.fromInt(line) - y0) * dx, dy)));
            if (wallY(g, fx.toInt(x), line, l, shift)) return true;
        }
    }
    return false;
}

/// Hash of the grid for replay files (FNV-1a over cells and wall faces).
pub fn gridHash(g: *const Grid) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (std.mem.asBytes(&g.blocks)) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    for (std.mem.asBytes(&g.walls)) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    // `surface` (W0) is folded in only when a bit is set, so a grid with no
    // surfaces keeps the hash it had before the table existed (recorded
    // replays carry it).
    const surf = std.mem.asBytes(&g.surface);
    if (std.mem.indexOfNone(u8, surf, &.{0}) != null) {
        for (surf) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
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

test "wall faces are lines, not blocks" {
    const g = try std.testing.allocator.create(Grid);
    defer std.testing.allocator.destroy(g);
    @memset(std.mem.asBytes(g), 0);
    // A fence on the right face of block (10, 10) at level 1: the line
    // x = 11 for y in [10, 11). Bullets pass it.
    g.walls[1][10][10] = wall_right;
    const z = fx.one;
    const y = fx.fromInt(10) + fx.half;
    const r = fx.ratio(1, 10);
    // Inside block (10, 10), clear of the line: free.
    try std.testing.expect(!rectHitsWall(g, Rect.square(fx.fromInt(10) + fx.half, y, r), z, ped_step));
    // Flush against it: free. Over it: blocked.
    try std.testing.expect(!rectHitsWall(g, Rect.square(fx.fromInt(11) - r, y, r), z, ped_step));
    try std.testing.expect(rectHitsWall(g, Rect.square(fx.fromInt(11) - r + 1, y, r), z, ped_step));
    // From the other side too (the face of either block counts).
    try std.testing.expect(rectHitsWall(g, Rect.square(fx.fromInt(11) + r - 1, y, r), z, ped_step));
    // Past its end (y >= 11 + r): free. On the level above: free.
    try std.testing.expect(!rectHitsWall(g, Rect.square(fx.fromInt(11), fx.fromInt(11) + r, r), z, ped_step));
    try std.testing.expect(!rectHitsWall(g, Rect.square(fx.fromInt(11), y, r), fx.fromInt(2), ped_step));
    // Nearly at the top of a ramp that ends against the block's face: the
    // body is stepping onto level 2, so the level-1 face no longer counts.
    try std.testing.expect(!rectHitsWall(g, Rect.square(fx.fromInt(11), y, r), fx.fromInt(2) - fx.ratio(1, 16), ped_step));
    // A car turned 45 degrees whose corner reaches over the line.
    const c45 = fx.ratio(70711, 100000);
    const car: Rect = .{ .x = fx.fromInt(10) + fx.ratio(4, 10), .y = y, .cos = c45, .sin = c45, .a = fx.ratio(8, 10), .b = fx.ratio(3, 10) };
    try std.testing.expect(rectHitsWall(g, car, z, ped_step));
    var away = car;
    away.x = fx.fromInt(10) - fx.ratio(1, 10);
    try std.testing.expect(!rectHitsWall(g, away, z, ped_step));
    // Moves: bodies stop, bullets do not, until it is a bullet wall.
    try std.testing.expect(moveHitsWall(g, fx.fromInt(10) + fx.half, y, fx.fromInt(11) + fx.half, y, z, 0));
    try std.testing.expect(!moveHitsWall(g, fx.fromInt(10) + fx.half, y, fx.fromInt(11) + fx.half, y, z, bullet));
    g.walls[1][10][11] = wall_left << bullet;
    try std.testing.expect(moveHitsWall(g, fx.fromInt(11) + fx.half, y, fx.fromInt(10) + fx.half, y, z, bullet));
    try std.testing.expect(!moveHitsWall(g, fx.fromInt(10) + fx.half, y, fx.fromInt(10) + fx.half, fx.fromInt(12), z, bullet));
}

test "deep water is a surface, and waterAt finds it" {
    const g = try std.testing.allocator.create(Grid);
    defer std.testing.allocator.destroy(g);
    g.* = std.mem.zeroes(Grid);
    set(g, 10, 10, 0, makeCell(Shape.water, 0, Ground.none, 0));
    set(g, 11, 10, 0, makeCell(Shape.solid, 0, Ground.field, 0));
    const y = fx.fromInt(10) + fx.half;
    try std.testing.expectEqual(fx.one, floorAt(g, fx.fromInt(10) + fx.half, y, fx.one, ped_step));
    try std.testing.expect(waterAt(g, fx.fromInt(10) + fx.half, y, fx.one));
    try std.testing.expect(!waterAt(g, fx.fromInt(11) + fx.half, y, fx.one));
}
