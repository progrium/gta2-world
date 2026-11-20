//! Collision data for the sim: the I1 `abi.Grid` built from a parsed map,
//! plus a per-face wall table that I1's 16-bit cell has no room for.
//!
//! The mapping was agreed with workstream A (sim):
//!   - slope codes 1-52 become `slope` with the code kept (ramps 1-44,
//!     diagonal walls 45-48, diagonal slopes 49-52),
//!   - codes 53-61 become `partial` with the code kept,
//!   - any other block (including code 63) is `solid` if it has a
//!     wall-flagged side face or a ground type other than air, otherwise
//!     air. A lid alone does not make a block solid: lid-only blocks with
//!     ground air are overhead graphics, and ground-typed blocks with no
//!     lid are real floors. (Revised after workstream A's 10,000-tick soak
//!     on wil, ste, bil and the mp maps: code 63 blocks hold up ramps.)
//!   - ground type is copied from the block,
//!   - the green road arrows are copied into bits 11-14.
//!
//! Checked on wil, ste and bil: the gmp arrow bits are bit 0 = -x, bit 1 =
//! +x, bit 2 = -y, bit 3 = +y. With that reading the opposite lane sits on
//! the left of travel in every single-arrow road cell (right-hand traffic),
//! which agrees with the axes S1 settled.
//!
//! Neither function allocates.

const std = @import("std");
const abi = @import("interfaces").abi;
const gmp = @import("gmp.zig");

comptime {
    std.debug.assert(abi.map_x == gmp.size_x and abi.map_y == gmp.size_y and abi.map_z == gmp.size_z);
}

/// I1 cell field positions.
pub const shape_shift = 0;
pub const code_shift = 3;
pub const ground_shift = 9;
pub const arrow_pos_y: abi.Cell = 1 << 11;
pub const arrow_neg_y: abi.Cell = 1 << 12;
pub const arrow_pos_x: abi.Cell = 1 << 13;
pub const arrow_neg_x: abi.Cell = 1 << 14;

/// gmp `Block.arrows` bits (green arrows, low nibble).
pub const gmp_arrow_neg_x: u8 = 1;
pub const gmp_arrow_pos_x: u8 = 2;
pub const gmp_arrow_neg_y: u8 = 4;
pub const gmp_arrow_pos_y: u8 = 8;

pub fn encode(shape: abi.Shape, code: u6, ground: abi.Ground, arrows: abi.Cell) abi.Cell {
    return @as(abi.Cell, @intFromEnum(shape)) << shape_shift |
        @as(abi.Cell, code) << code_shift |
        @as(abi.Cell, @intFromEnum(ground)) << ground_shift |
        (arrows & 0x7800);
}

pub fn cellShape(c: abi.Cell) abi.Shape {
    return @enumFromInt(@as(u3, @truncate(c >> shape_shift)));
}
pub fn cellCode(c: abi.Cell) u6 {
    return @truncate(c >> code_shift);
}
pub fn cellGround(c: abi.Cell) abi.Ground {
    return @enumFromInt(@as(u2, @truncate(c >> ground_shift)));
}

pub fn arrowsOf(b: gmp.Block) abi.Cell {
    var a: abi.Cell = 0;
    if (b.arrows & gmp_arrow_pos_y != 0) a |= arrow_pos_y;
    if (b.arrows & gmp_arrow_neg_y != 0) a |= arrow_neg_y;
    if (b.arrows & gmp_arrow_pos_x != 0) a |= arrow_pos_x;
    if (b.arrows & gmp_arrow_neg_x != 0) a |= arrow_neg_x;
    return a;
}

fn hasWallSide(b: gmp.Block) bool {
    return b.left.wall() or b.right.wall() or b.top.wall() or b.bottom.wall();
}

/// The I1 cell for one block.
pub fn cellOf(b: gmp.Block) abi.Cell {
    if (b.isAir()) return 0;
    const code = b.slopeCode();
    const ground: abi.Ground = @enumFromInt(@intFromEnum(b.ground()));
    const shape: abi.Shape = switch (code) {
        1...52 => .slope,
        53...61 => .partial,
        else => if (hasWallSide(b) or b.ground() != .air) .solid else .air,
    };
    if (shape == .air) return encode(.air, 0, .none, arrowsOf(b));
    return encode(shape, if (shape == .solid) 0 else code, ground, arrowsOf(b));
}

/// Fills `out` from the map. z-major, as both `gmp.Map.cells` and
/// `abi.Grid` are.
pub fn build(map: *const gmp.Map, out: *abi.Grid) void {
    const flat: *[gmp.cell_count]abi.Cell = @ptrCast(&out.blocks);
    for (map.cells, flat) |bi, *c| c.* = cellOf(map.blocks[bi]);
}

/// Per-face wall bits, one byte per cell, laid out like `abi.Grid`.
/// Bits 0-3: wall on the left (x), right (x+1), top (y), bottom (y+1) face.
/// Bits 4-7: bullet wall on the same faces.
pub const Walls = [abi.map_z][abi.map_y][abi.map_x]u8;
pub const wall_left: u8 = 1;
pub const wall_right: u8 = 2;
pub const wall_top: u8 = 4;
pub const wall_bottom: u8 = 8;
pub const bullet_shift = 4;

pub fn wallsOf(b: gmp.Block) u8 {
    const faces = [_]gmp.Face{ b.left, b.right, b.top, b.bottom };
    var w: u8 = 0;
    for (faces, 0..) |f, i| {
        if (f.isEmpty()) continue;
        if (f.wall()) w |= @as(u8, 1) << @intCast(i);
        if (f.bulletWall()) w |= @as(u8, 1) << @intCast(i + bullet_shift);
    }
    return w;
}

pub fn buildWalls(map: *const gmp.Map, out: *Walls) void {
    const flat: *[gmp.cell_count]u8 = @ptrCast(out);
    for (map.cells, flat) |bi, *w| w.* = wallsOf(map.blocks[bi]);
}

const testing = std.testing;
const synth = @import("synth.zig");

fn face(tile: u10, wall: bool) gmp.Face {
    return .{ .tile = tile, .bit10 = wall, .bit11 = false, .flat = false, .flip = false, .rotation = 0 };
}

test "cell mapping" {
    // Road with an east arrow.
    const road: gmp.Block = .{ .lid = face(5, false), .slope_type = 1, .arrows = gmp_arrow_pos_x };
    const c = cellOf(road);
    try testing.expectEqual(abi.Shape.solid, cellShape(c));
    try testing.expectEqual(abi.Ground.road, cellGround(c));
    try testing.expectEqual(arrow_pos_x, c & 0x7800);

    // Wall column with no lid and ground air: solid.
    try testing.expectEqual(abi.Shape.solid, cellShape(cellOf(.{ .left = face(3, true) })));
    // Decorative side face with no wall bit and no lid: air.
    try testing.expectEqual(abi.Shape.air, cellShape(cellOf(.{ .left = face(3, false) })));

    // Ramp code 41 keeps its code.
    const ramp = cellOf(.{ .lid = face(1, false), .slope_type = (41 << 2) | 2 });
    try testing.expectEqual(abi.Shape.slope, cellShape(ramp));
    try testing.expectEqual(@as(u6, 41), cellCode(ramp));
    try testing.expectEqual(abi.Ground.pavement, cellGround(ramp));

    // Partial and slope_above.
    try testing.expectEqual(abi.Shape.partial, cellShape(cellOf(.{ .lid = face(1, false), .slope_type = 57 << 2 })));
    // Code 63 is an ordinary block: solid with walls or ground.
    try testing.expectEqual(abi.Shape.solid, cellShape(cellOf(.{ .left = face(3, true), .slope_type = (63 << 2) | 3 })));
    // Lid with ground air: overhead graphics, air. Ground with no lid: floor.
    try testing.expectEqual(abi.Shape.air, cellShape(cellOf(.{ .lid = face(1, false) })));
    try testing.expectEqual(abi.Shape.solid, cellShape(cellOf(.{ .slope_type = 2 })));
    try testing.expectEqual(@as(abi.Cell, 0), cellOf(.{ .lid = face(1, false), .arrows = 0xFF }) & 0x8000);
}

test "grid from a synthetic map" {
    var mb = try synth.MapBuilder.init(testing.allocator);
    defer mb.deinit();
    mb.set(10, 20, 1, .{ .lid = face(5, false), .slope_type = 1, .arrows = gmp_arrow_neg_y });
    mb.set(11, 20, 2, .{ .left = face(3, true), .right = face(3, true) });
    const bytes = try mb.write(.dmap);
    defer testing.allocator.free(bytes);
    var map = try gmp.parse(testing.allocator, bytes);
    defer map.deinit();

    const grid = try testing.allocator.create(abi.Grid);
    defer testing.allocator.destroy(grid);
    build(&map, grid);
    const c = grid.blocks[1][20][10];
    try testing.expectEqual(abi.Shape.solid, cellShape(c));
    try testing.expectEqual(arrow_neg_y, c & 0x7800);
    try testing.expectEqual(abi.Shape.solid, cellShape(grid.blocks[2][20][11]));
    try testing.expectEqual(@as(abi.Cell, 0), grid.blocks[0][0][0]);

    const walls = try testing.allocator.create(Walls);
    defer testing.allocator.destroy(walls);
    buildWalls(&map, walls);
    try testing.expectEqual(wall_left | wall_right, walls[2][20][11]);
    try testing.expectEqual(@as(u8, 0), walls[1][20][10]);
}
