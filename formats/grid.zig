//! Collision data for the sim: the I1 `abi.Grid` built from a parsed map,
//! plus a per-face wall table that I1's 16-bit cell has no room for.
//!
//! The mapping was agreed with workstream A (sim):
//!   - slope codes 1-52 become `slope` with the code kept (ramps 1-44,
//!     diagonal walls 45-48, diagonal slopes 49-52),
//!   - codes 53-61 become `partial` with the code kept,
//!   - any other block (including code 63) is `slab` (a floor bodies pass
//!     under, added in M3 for overpasses) if its ground type is not air,
//!     otherwise air. A lid alone does not make a floor: lid-only blocks
//!     with ground air are overhead graphics, and ground-typed blocks with
//!     no lid are real floors. The exception is a lidded block with wall
//!     faces (a hollow building's roof edge), which is a slab too.
//!   - wall faces go into `Grid.walls`, one byte per block
//!     (shape-and-map-collision.md 3.2-3.3): a wall is a line on a block
//!     face, not a solid cube. A ramp's own side faces (the two parallel
//!     to its uphill direction) and every face of a partial block are left
//!     out, since they never block in the original. Until M3 a block with
//!     any wall face became a whole `solid` cube, which players met as
//!     invisible walls beside fences and single faces.
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
    return wallsOf(b) & 0x0F != 0;
}

/// The I1 cell for one block.
pub fn cellOf(b: gmp.Block) abi.Cell {
    if (b.isAir()) return 0;
    const code = b.slopeCode();
    const ground: abi.Ground = @enumFromInt(@intFromEnum(b.ground()));
    const shape: abi.Shape = switch (code) {
        1...52 => .slope,
        53...61 => .partial,
        // A ground block is a floor you can pass under (an overpass deck):
        // a slab. Its walls are in `Grid.walls`, so only its top matters.
        else => if (b.ground() != .air or (hasWallSide(b) and !b.lid.isEmpty())) .slab else .air,
    };
    if (shape == .air) return encode(.air, 0, .none, arrowsOf(b));
    return encode(shape, if (shape == .solid) 0 else code, ground, arrowsOf(b));
}

/// Fills `out` (cells and wall faces) from the map. z-major, as both
/// `gmp.Map.cells` and `abi.Grid` are.
pub fn build(map: *const gmp.Map, out: *abi.Grid) void {
    const flat: *[gmp.cell_count]abi.Cell = @ptrCast(&out.blocks);
    for (map.cells, flat) |bi, *c| c.* = cellOf(map.blocks[bi]);
    const walls: *[gmp.cell_count]abi.WallBits = @ptrCast(&out.walls);
    for (map.cells, walls) |bi, *w| w.* = wallsOf(map.blocks[bi]);
}

/// `abi.Grid.walls` bits.
pub const wall_left = abi.wall_left;
pub const wall_right = abi.wall_right;
pub const wall_top = abi.wall_top;
pub const wall_bottom = abi.wall_bottom;
pub const bullet_shift = abi.bullet_wall_shift;

/// The wall faces of one block. A face's wall bit counts whether or not it
/// has a tile (the original reads only the bit). Ramps (codes 1-44) drop
/// the two side faces parallel to their uphill direction; partial blocks
/// (53-61) have none.
pub fn wallsOf(b: gmp.Block) abi.WallBits {
    const code = b.slopeCode();
    if (code >= 53 and code <= 61) return 0;
    const faces = [_]gmp.Face{ b.left, b.right, b.top, b.bottom };
    var w: abi.WallBits = 0;
    for (faces, 0..) |f, i| {
        if (f.wall()) w |= @as(u8, 1) << @intCast(i);
        if (f.bulletWall()) w |= @as(u8, 1) << @intCast(i + bullet_shift);
    }
    if (rampDir(code)) |dir| {
        const sides: u8 = if (dir < 2) wall_left | wall_right else wall_top | wall_bottom;
        w &= ~(sides | sides << bullet_shift);
    }
    return w;
}

/// Uphill direction of a ramp code (0 up/-y, 1 down/+y, 2 left/-x,
/// 3 right/+x), as `sim/map.zig` decodes it; null if not a ramp.
fn rampDir(code: u6) ?u2 {
    return switch (code) {
        1...8 => @truncate((code - 1) >> 1),
        9...40 => @truncate((code - 9) >> 3),
        41...44 => @truncate(code - 41),
        else => null,
    };
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
    try testing.expectEqual(abi.Shape.slab, cellShape(c));
    try testing.expectEqual(abi.Ground.road, cellGround(c));
    try testing.expectEqual(arrow_pos_x, c & 0x7800);

    // Wall face with no lid and ground air: air (the face is in `walls`).
    try testing.expectEqual(abi.Shape.air, cellShape(cellOf(.{ .left = face(3, true) })));
    try testing.expectEqual(wall_left, wallsOf(.{ .left = face(3, true) }));
    // A lidded block with wall faces is a floor.
    try testing.expectEqual(abi.Shape.slab, cellShape(cellOf(.{ .lid = face(1, false), .left = face(3, true) })));
    // Ramp 41 climbs toward -y: its left and right faces are not walls.
    try testing.expectEqual(wall_top, wallsOf(.{ .left = face(3, true), .right = face(3, true), .top = face(3, true), .slope_type = 41 << 2 }));
    // Ramp 43 climbs toward -x: its top and bottom faces are not walls.
    try testing.expectEqual(wall_left, wallsOf(.{ .left = face(3, true), .top = face(3, true), .bottom = face(3, true), .slope_type = 43 << 2 }));
    // Partial blocks have no walls; a wall bit with no tile still counts.
    try testing.expectEqual(@as(u8, 0), wallsOf(.{ .left = face(3, true), .slope_type = 55 << 2 }));
    try testing.expectEqual(wall_right, wallsOf(.{ .right = face(0, true) }));
    // Decorative side face with no wall bit and no lid: air.
    try testing.expectEqual(abi.Shape.air, cellShape(cellOf(.{ .left = face(3, false) })));

    // Ramp code 41 keeps its code.
    const ramp = cellOf(.{ .lid = face(1, false), .slope_type = (41 << 2) | 2 });
    try testing.expectEqual(abi.Shape.slope, cellShape(ramp));
    try testing.expectEqual(@as(u6, 41), cellCode(ramp));
    try testing.expectEqual(abi.Ground.pavement, cellGround(ramp));

    // Partial and slope_above.
    try testing.expectEqual(abi.Shape.partial, cellShape(cellOf(.{ .lid = face(1, false), .slope_type = 57 << 2 })));
    // Code 63 is an ordinary block: a floor with ground.
    try testing.expectEqual(abi.Shape.slab, cellShape(cellOf(.{ .left = face(3, true), .slope_type = (63 << 2) | 3 })));
    // Lid with ground air: overhead graphics, air. Ground with no lid: floor.
    try testing.expectEqual(abi.Shape.air, cellShape(cellOf(.{ .lid = face(1, false) })));
    try testing.expectEqual(abi.Shape.slab, cellShape(cellOf(.{ .slope_type = 2 })));
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
    try testing.expectEqual(abi.Shape.slab, cellShape(c));
    try testing.expectEqual(arrow_neg_y, c & 0x7800);
    try testing.expectEqual(abi.Shape.air, cellShape(grid.blocks[2][20][11]));
    try testing.expectEqual(@as(abi.Cell, 0), grid.blocks[0][0][0]);
    try testing.expectEqual(wall_left | wall_right, grid.walls[2][20][11]);
    try testing.expectEqual(@as(u8, 0), grid.walls[1][20][10]);
}
