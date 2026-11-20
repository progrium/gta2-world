//! Turns a parsed map into a flat triangle list for the throwaway S1 viewer.
//!
//! Units: 64 per block (one tile pixel), so every coordinate fits an i16.
//! The viewer draws with back-face culling off and alpha-tests palette
//! index 0 on faces flagged transparent, which is all GTA2 transparency is.

const std = @import("std");
const formats = @import("formats");
const gmp = formats.gmp;

pub const unit = 64;

pub const Vertex = extern struct {
    x: i16,
    y: i16,
    z: i16,
    u: u8,
    v: u8,
    tile: u16,
    flags: u8,
    shade: u8,
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == 12);
}

pub const flag_transparent: u8 = 1;
pub const flag_lid: u8 = 2;
/// Drawn only from the side it faces (counter-clockwise winding). Used for
/// the two halves of a flat side face whose reverse shows another tile.
pub const flag_one_sided: u8 = 4;

pub const Stats = struct {
    lids: u32 = 0,
    sides: u32 = 0,
    transparent: u32 = 0,
    triangles: u32 = 0,
    /// Faces skipped because their tile is the 1023 dummy.
    dummy: u32 = 0,
};

/// Local 2D point inside a block, 0..64.
const P2 = struct { x: i32, y: i32 };
/// Local 3D point.
const P3 = struct { x: i32, y: i32, z: i32 };

const Builder = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Vertex),
    stats: *Stats,
    ox: i32,
    oy: i32,
    oz: i32,

    fn vert(b: *Builder, p: P3, uv: [2]i32, tile: u16, flags: u8, shade: u8) Vertex {
        return .{
            .x = @intCast(b.ox + p.x),
            .y = @intCast(b.oy + p.y),
            .z = @intCast(b.oz + p.z),
            .u = @intCast(std.math.clamp(uv[0], 0, 64) & 0xff),
            .v = @intCast(std.math.clamp(uv[1], 0, 64) & 0xff),
            .tile = tile,
            .flags = flags,
            .shade = shade,
        };
    }

    fn tri(b: *Builder, p: [3]P3, uv: [3][2]i32, face: gmp.Face, flags: u8, shade: u8) !void {
        var verts: [3]Vertex = undefined;
        for (&verts, p, uv) |*v, pp, t| v.* = b.vert(pp, t, face.tile, flags, shade);
        try b.out.appendSlice(b.gpa, &verts);
        b.stats.triangles += 1;
    }
};

/// Applies a face's flip and rotation to a texture coordinate in 0..64.
/// Rotation is taken as clockwise as seen on screen, flip as a horizontal
/// mirror applied before rotating. Both are guesses to check in game.
fn orient(face: gmp.Face, uv: [2]i32) [2]i32 {
    var u = uv[0];
    var v = uv[1];
    if (face.flip) u = 64 - u;
    switch (face.rotation) {
        0 => {},
        1 => {
            const t = u;
            u = v;
            v = 64 - t;
        },
        2 => {
            u = 64 - u;
            v = 64 - v;
        },
        3 => {
            const t = u;
            u = 64 - v;
            v = t;
        },
    }
    return .{ u, v };
}

fn faceFlags(face: gmp.Face, lid: bool) u8 {
    var f: u8 = 0;
    if (face.flat) f |= flag_transparent;
    if (lid) f |= flag_lid;
    return f;
}

fn lidShade(face: gmp.Face) u8 {
    return switch (face.lighting()) {
        0 => 255,
        1 => 205,
        2 => 160,
        3 => 120,
    };
}

const shade_lr: u8 = 215;
const shade_tb: u8 = 180;
const shade_diag: u8 = 200;

/// Corner order used everywhere: NW, NE, SE, SW (top-left clockwise).
const Heights = [4]i32;

fn rampHeights(r: anytype) Heights {
    const lo: i32 = @divTrunc(@as(i32, r.low) * unit, r.denom);
    const hi: i32 = @divTrunc(@as(i32, r.high) * unit, r.denom);
    return switch (r.dir) {
        .up => .{ hi, hi, lo, lo },
        .down => .{ lo, lo, hi, hi },
        .left => .{ hi, lo, lo, hi },
        .right => .{ lo, hi, hi, lo },
    };
}

fn lidUV(face: gmp.Face, p: P3) [2]i32 {
    return orient(face, .{ p.x, p.y });
}

/// Emits a lid over the quad a, b, c, d (clockwise from above), split along
/// a-c.
fn lidQuad(b: *Builder, face: gmp.Face, q: [4]P3) !void {
    if (face.isEmpty()) return;
    if (face.tile == 1023) {
        b.stats.dummy += 1;
        return;
    }
    const fl = faceFlags(face, true);
    const sh = lidShade(face);
    try b.tri(.{ q[0], q[1], q[2] }, .{ lidUV(face, q[0]), lidUV(face, q[1]), lidUV(face, q[2]) }, face, fl, sh);
    try b.tri(.{ q[0], q[2], q[3] }, .{ lidUV(face, q[0]), lidUV(face, q[2]), lidUV(face, q[3]) }, face, fl, sh);
    b.stats.lids += 1;
    if (face.flat) b.stats.transparent += 1;
}

fn lidTri(b: *Builder, face: gmp.Face, t: [3]P3) !void {
    if (face.isEmpty()) return;
    if (face.tile == 1023) {
        b.stats.dummy += 1;
        return;
    }
    const fl = faceFlags(face, true);
    try b.tri(t, .{ lidUV(face, t[0]), lidUV(face, t[1]), lidUV(face, t[2]) }, face, fl, lidShade(face));
    b.stats.lids += 1;
    if (face.flat) b.stats.transparent += 1;
}

/// Emits a vertical wall from 2D point `a` to `b` (left to right as seen
/// from outside), whose top edge is at heights ha and hb. `ua`/`ub` are the
/// horizontal texture coordinates at each end.
fn wall(bld: *Builder, face: gmp.Face, a: P2, b: P2, ha: i32, hb: i32, ua: i32, ub: i32, shade: u8) !void {
    return wallFlags(bld, face, a, b, ha, hb, ua, ub, shade, 0);
}

fn wallFlags(bld: *Builder, face: gmp.Face, a: P2, b: P2, ha: i32, hb: i32, ua: i32, ub: i32, shade: u8, extra: u8) !void {
    if (face.isEmpty()) return;
    if (face.tile == 1023) {
        bld.stats.dummy += 1;
        return;
    }
    if (ha <= 0 and hb <= 0) return;
    const fl = faceFlags(face, false) | extra;
    const a0: P3 = .{ .x = a.x, .y = a.y, .z = 0 };
    const b0: P3 = .{ .x = b.x, .y = b.y, .z = 0 };
    const a1: P3 = .{ .x = a.x, .y = a.y, .z = ha };
    const b1: P3 = .{ .x = b.x, .y = b.y, .z = hb };
    // v runs top (0) to bottom (64) of a full-height block; shorter walls
    // show the bottom part of the tile.
    const uv_a0 = orient(face, .{ ua, 64 });
    const uv_b0 = orient(face, .{ ub, 64 });
    const uv_a1 = orient(face, .{ ua, 64 - ha });
    const uv_b1 = orient(face, .{ ub, 64 - hb });
    if (ha > 0) try bld.tri(.{ a0, b0, a1 }, .{ uv_a0, uv_b0, uv_a1 }, face, fl, shade);
    if (hb > 0) try bld.tri(.{ b0, b1, a1 }, .{ uv_b0, uv_b1, uv_a1 }, face, fl, shade);
    bld.stats.sides += 1;
    if (face.flat) bld.stats.transparent += 1;
}

/// Box with a rectangular footprint [x0,x1] x [y0,y1] and per-corner lid
/// heights. Texture coordinates come from the full block, so partial
/// blocks show the matching part of each tile.
fn box(b: *Builder, blk: gmp.Block, x0: i32, y0: i32, x1: i32, y1: i32, h: Heights) !void {
    const nw: P2 = .{ .x = x0, .y = y0 };
    const ne: P2 = .{ .x = x1, .y = y0 };
    const se: P2 = .{ .x = x1, .y = y1 };
    const sw: P2 = .{ .x = x0, .y = y1 };
    // left (west) face seen from the west: north end on the left.
    // right (east) face seen from the east: south end on the left.
    try sidePair(b, blk.left, blk.right, nw, sw, se, ne, h[0], h[3], h[2], h[1], y0, y1, 64 - y1, 64 - y0, shade_lr);
    // top (north) face seen from the north: east end on the left.
    // bottom (south) face seen from the south: west end on the left.
    try sidePair(b, blk.top, blk.bottom, ne, nw, sw, se, h[1], h[0], h[3], h[2], 64 - x1, 64 - x0, x0, x1, shade_tb);
    try lidQuad(b, blk.lid, .{
        .{ .x = x0, .y = y0, .z = h[0] },
        .{ .x = x1, .y = y0, .z = h[1] },
        .{ .x = x1, .y = y1, .z = h[2] },
        .{ .x = x0, .y = y1, .z = h[3] },
    });
}

/// Draws two opposite side faces `f` (edge a-b) and `g` (edge c-d), each
/// given left to right as seen from outside.
///
/// Checked against wil/ste/bil: when a side face is flat and the opposite
/// face is not, the opposite face is the reverse of the flat one (in the
/// real maps 99% of non-flat faces with see-through tiles sit opposite a
/// flat face, usually with the same tile). It is drawn on the back of the
/// flat face, with transparency, and not as a wall on its own edge.
fn sidePair(b: *Builder, f: gmp.Face, g: gmp.Face, fa: P2, fb: P2, gc: P2, gd: P2, hfa: i32, hfb: i32, hgc: i32, hgd: i32, ufa: i32, ufb: i32, ugc: i32, ugd: i32, shade: u8) !void {
    const f_backed = f.flat and !g.flat and !g.isEmpty();
    const g_backed = g.flat and !f.flat and !f.isEmpty();
    if (f_backed) {
        try backedWall(b, f, g, fa, fb, hfa, hfb, ufa, ufb, shade);
    } else if (g_backed) {
        try backedWall(b, g, f, gc, gd, hgc, hgd, ugc, ugd, shade);
    } else {
        try wall(b, f, fa, fb, hfa, hfb, ufa, ufb, shade);
        try wall(b, g, gc, gd, hgc, hgd, ugc, ugd, shade);
    }
}

/// A flat face on edge a-b whose reverse shows `back`. The reverse is seen
/// from inside the block, so its left end is b.
fn backedWall(b: *Builder, front: gmp.Face, back: gmp.Face, a: P2, bb: P2, ha: i32, hb: i32, ua: i32, ub: i32, shade: u8) !void {
    try wallFlags(b, front, a, bb, ha, hb, ua, ub, shade, flag_one_sided);
    var rev = back;
    rev.flat = true;
    try wallFlags(b, rev, bb, a, hb, ha, 64 - ub, 64 - ua, shade, flag_one_sided);
}

const corners2 = [4]P2{ .{ .x = 0, .y = 0 }, .{ .x = 64, .y = 0 }, .{ .x = 64, .y = 64 }, .{ .x = 0, .y = 64 } };

fn cornerIndex(c: gmp.Corner) usize {
    return switch (c) {
        .up_left => 0,
        .up_right => 1,
        .down_right => 2,
        .down_left => 3,
    };
}

/// Face drawn on the diagonal of a diagonal wall or 3-sided slope. The DMA
/// doc does not say; we take the left tile for left-facing diagonals and
/// the right tile for right-facing ones.
fn diagonalFace(blk: gmp.Block, c: gmp.Corner) gmp.Face {
    return switch (c) {
        .up_left, .down_left => blk.left,
        .up_right, .down_right => blk.right,
    };
}

/// Diagonal wall: a full-height prism over the half of the block away from
/// corner `c`.
fn diagonal(b: *Builder, blk: gmp.Block, c: gmp.Corner) !void {
    const open = cornerIndex(c);
    const a = corners2[(open + 1) % 4];
    const opp = corners2[(open + 2) % 4];
    const d = corners2[(open + 3) % 4];
    // Diagonal face, seen from the open corner: a on the left, d on the
    // right (same handedness as the box walls).
    try wall(b, diagonalFace(blk, c), a, d, 64, 64, 0, 64, shade_diag);
    try solidSides(b, blk, open, .{ 64, 64, 64, 64 });
    try lidTri(b, blk.lid, .{ p3(a, 64), p3(opp, 64), p3(d, 64) });
}

fn p3(p: P2, z: i32) P3 {
    return .{ .x = p.x, .y = p.y, .z = z };
}

/// Draws the block's real side faces except the two that touch corner
/// `open` (which are empty for diagonal shapes).
fn solidSides(b: *Builder, blk: gmp.Block, open: usize, h: Heights) !void {
    const nw = corners2[0];
    const ne = corners2[1];
    const se = corners2[2];
    const sw = corners2[3];
    // Side k joins corners: left = NW-SW (0,3), right = NE-SE (1,2),
    // top = NW-NE (0,1), bottom = SW-SE (3,2).
    if (open != 0 and open != 3) try wall(b, blk.left, nw, sw, h[0], h[3], 0, 64, shade_lr);
    if (open != 1 and open != 2) try wall(b, blk.right, se, ne, h[2], h[1], 0, 64, shade_lr);
    if (open != 0 and open != 1) try wall(b, blk.top, ne, nw, h[1], h[0], 0, 64, shade_tb);
    if (open != 3 and open != 2) try wall(b, blk.bottom, sw, se, h[3], h[2], 0, 64, shade_tb);
}

/// 49-52. A lid of 1023 marks the 3-sided spire: a triangle footprint away
/// from the facing corner, rising to the opposite corner. Otherwise it is a
/// 4-sided inner corner: the facing corner is low, the other three high.
/// Both readings are inferred from editor screenshots, not the DMA doc.
fn diagonalSlope(b: *Builder, blk: gmp.Block, c: gmp.Corner) !void {
    const f = cornerIndex(c);
    const a = corners2[(f + 1) % 4];
    const opp = corners2[(f + 2) % 4];
    const d = corners2[(f + 3) % 4];
    if (blk.lid.tile == 1023) {
        var h: Heights = @splat(0);
        h[(f + 2) % 4] = 64;
        try solidSides(b, blk, f, h);
        try lidTri(b, diagonalFace(blk, c), .{ p3(a, 0), p3(opp, 64), p3(d, 0) });
    } else {
        var h: Heights = @splat(64);
        h[f] = 0;
        const fc = corners2[f];
        try wall(b, blk.left, corners2[0], corners2[3], h[0], h[3], 0, 64, shade_lr);
        try wall(b, blk.right, corners2[2], corners2[1], h[2], h[1], 0, 64, shade_lr);
        try wall(b, blk.top, corners2[1], corners2[0], h[1], h[0], 0, 64, shade_tb);
        try wall(b, blk.bottom, corners2[3], corners2[2], h[3], h[2], 0, 64, shade_tb);
        try lidTri(b, blk.lid, .{ p3(fc, 0), p3(a, 64), p3(d, 64) });
        try lidTri(b, blk.lid, .{ p3(a, 64), p3(opp, 64), p3(d, 64) });
    }
}

fn partialRect(p: gmp.Partial) [4]i32 {
    const n = 24;
    return switch (p) {
        .left => .{ 0, 0, n, 64 },
        .right => .{ 64 - n, 0, 64, 64 },
        .top => .{ 0, 0, 64, n },
        .bottom => .{ 0, 64 - n, 64, 64 },
        .top_left => .{ 0, 0, n, n },
        .top_right => .{ 64 - n, 0, 64, n },
        .bottom_right => .{ 64 - n, 64 - n, 64, 64 },
        .bottom_left => .{ 0, 64 - n, n, 64 },
        .centre => .{ 24, 24, 40, 40 },
    };
}

pub fn emitBlock(gpa: std.mem.Allocator, out: *std.ArrayList(Vertex), stats: *Stats, blk: gmp.Block, x: usize, y: usize, z: usize) !void {
    var b: Builder = .{
        .gpa = gpa,
        .out = out,
        .stats = stats,
        .ox = @intCast(x * unit),
        .oy = @intCast(y * unit),
        .oz = @intCast(z * unit),
    };
    switch (blk.shape()) {
        .cube, .reserved, .slope_above => try box(&b, blk, 0, 0, 64, 64, @splat(64)),
        .ramp => |r| try box(&b, blk, 0, 0, 64, 64, rampHeights(r)),
        .diagonal => |c| try diagonal(&b, blk, c),
        .diagonal_slope => |c| try diagonalSlope(&b, blk, c),
        .partial => |p| {
            const r = partialRect(p);
            try box(&b, blk, r[0], r[1], r[2], r[3], @splat(64));
        },
    }
}

/// Builds the whole map. Caller owns the returned slice.
pub fn build(gpa: std.mem.Allocator, map: *const gmp.Map, stats: *Stats) ![]Vertex {
    var out: std.ArrayList(Vertex) = .empty;
    errdefer out.deinit(gpa);
    for (0..gmp.size_z) |z| for (0..gmp.size_y) |y| for (0..gmp.size_x) |x| {
        const blk = map.get(x, y, z);
        if (blk.isAir()) continue;
        try emitBlock(gpa, &out, stats, blk, x, y, z);
    };
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "cube emits five faces" {
    var out: std.ArrayList(Vertex) = .empty;
    defer out.deinit(testing.allocator);
    var st: Stats = .{};
    const f: gmp.Face = .{ .tile = 4, .bit10 = true, .bit11 = true, .flat = false, .flip = false, .rotation = 0 };
    try emitBlock(testing.allocator, &out, &st, .{ .left = f, .right = f, .top = f, .bottom = f, .lid = f }, 1, 2, 3);
    try testing.expectEqual(@as(u32, 10), st.triangles);
    try testing.expectEqual(@as(u32, 1), st.lids);
    try testing.expectEqual(@as(u32, 4), st.sides);
    for (out.items) |v| {
        try testing.expect(v.x >= 64 and v.x <= 128);
        try testing.expect(v.z >= 192 and v.z <= 256);
    }
}

test "ramp lid heights" {
    // Code 1: up 26 low. North edge at half height, south edge at zero.
    const r = gmp.decodeShape(1).ramp;
    try testing.expectEqual(Heights{ 32, 32, 0, 0 }, rampHeights(r));
    const r7 = gmp.decodeShape(33).ramp; // right 7, lowest
    try testing.expectEqual(Heights{ 0, 8, 8, 0 }, rampHeights(r7));
}

test "orientation" {
    const f0: gmp.Face = .{ .tile = 1, .bit10 = false, .bit11 = false, .flat = false, .flip = false, .rotation = 1 };
    // Rotating 90 degrees clockwise: the source top-left shows at top-right.
    try testing.expectEqual([2]i32{ 0, 0 }, orient(f0, .{ 64, 0 }));
}
