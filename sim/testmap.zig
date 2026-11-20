//! A synthetic test map in I1 cells, used until `formats/` builds grids from
//! real `.gmp` files, and kept afterwards for tests and the golden replay
//! (real map data is never committed).
//!
//! Layout: a ground slab at layer 0 (its top, z = 1, is street level), a grid
//! of two-lane roads every 16 blocks with right-hand traffic arrows and
//! pavements, buildings of varying height in each city block, and one "test
//! yard" block with every kind of ramp, partial blocks and diagonal walls.

const std = @import("std");
const map = @import("map.zig");
const Shape = map.Shape;
const Ground = map.Ground;
const Arrow = map.Arrow;
const Code = map.Code;

pub const lo = 32;
pub const hi = 224;
pub const pitch = 16;
pub const road_w = 4;
pub const pave_w = 2;

/// Block coordinates of the test yard's corner (inside one city block).
pub const yard_x = 128 + road_w + pave_w;
pub const yard_y = 128 + road_w + pave_w;

fn solid(g: *map.Grid, x: u32, y: u32, z: u32, ground: u2, arrows: u4) void {
    map.set(g, x, y, z, map.makeCell(Shape.solid, 0, ground, arrows));
}

pub fn build(g: *map.Grid) void {
    @memset(std.mem.asBytes(g), 0);
    // Ground slab everywhere: fields outside the city.
    for (0..map.size_y) |y| for (0..map.size_x) |x| solid(g, @intCast(x), @intCast(y), 0, Ground.field, 0);

    var y: u32 = lo;
    while (y < hi) : (y += 1) {
        var x: u32 = lo;
        while (x < hi) : (x += 1) {
            const mx = (x - lo) % pitch;
            const my = (y - lo) % pitch;
            const on_road_x = my < road_w; // road running along x
            const on_road_y = mx < road_w; // road running along y
            if (on_road_x or on_road_y) {
                var arrows: u4 = 0;
                if (on_road_x and !on_road_y) arrows = if (my >= road_w / 2) Arrow.pos_x else Arrow.neg_x;
                if (on_road_y and !on_road_x) arrows = if (mx < road_w / 2) Arrow.pos_y else Arrow.neg_y;
                solid(g, x, y, 0, Ground.road, arrows);
            } else if (mx < road_w + pave_w or my < road_w + pave_w or mx >= pitch - pave_w or my >= pitch - pave_w) {
                solid(g, x, y, 0, Ground.pavement, 0);
            } else {
                solid(g, x, y, 0, Ground.pavement, 0);
            }
        }
    }
    // Buildings: the inner part of each city block, height from a cheap hash.
    var by: u32 = lo;
    while (by < hi) : (by += pitch) {
        var bx: u32 = lo;
        while (bx < hi) : (bx += pitch) {
            const x0 = bx + road_w + pave_w;
            const y0 = by + road_w + pave_w;
            const x1 = bx + pitch - pave_w;
            const y1 = by + pitch - pave_w;
            if (x0 == yard_x and y0 == yard_y) {
                buildYard(g);
                continue;
            }
            const h: u32 = 1 + ((bx *% 7 +% by *% 13) >> 4) % 4;
            var yy = y0;
            while (yy < y1) : (yy += 1) {
                var xx = x0;
                while (xx < x1) : (xx += 1) {
                    var z: u32 = 1;
                    while (z <= h) : (z += 1) solid(g, xx, yy, z, if (z == h) Ground.pavement else Ground.none, 0);
                }
            }
        }
    }
}

/// The test yard: an 8 x 8 area (yard_x..+8, yard_y..+8) at street level.
///   * a raised 3 x 3 platform (top at z = 2) in the middle,
///   * a 45 degree ramp up to it from the west, a two-part 26 degree ramp
///     from the south, and an eight-part 7 degree ramp from the north that
///     starts outside the yard on the pavement and road,
///   * partial blocks and diagonal walls around the east side.
fn buildYard(g: *map.Grid) void {
    const px = yard_x + 3;
    const py = yard_y + 3;
    for (0..3) |dy| for (0..3) |dx| solid(g, @intCast(px + dx), @intCast(py + dy), 1, Ground.pavement, 0);
    // West: 45 degree, high end toward +x (right).
    for (0..3) |dy| map.set(g, px - 1, @intCast(py + dy), 1, map.makeCell(Shape.slope, Code.ramp45(3), Ground.pavement, 0));
    // South: 26 degree in two parts, high end toward -y (up).
    for (0..3) |dx| {
        map.set(g, @intCast(px + dx), py + 3, 1, map.makeCell(Shape.slope, Code.ramp26(0, true), Ground.pavement, 0));
        map.set(g, @intCast(px + dx), py + 4, 1, map.makeCell(Shape.slope, Code.ramp26(0, false), Ground.pavement, 0));
    }
    // North: 7 degree in eight parts, high end toward +y (down), from py-8 to py-1.
    for (0..8) |i| {
        for (0..3) |dx| map.set(g, @intCast(px + dx), @intCast(py - 8 + i), 1, map.makeCell(Shape.slope, Code.ramp7(1, @intCast(i)), Ground.pavement, 0));
    }
    // East: partial blocks and diagonal walls in a column.
    const ex = yard_x + 7;
    for (0..4) |i| map.set(g, ex, @intCast(yard_y + i), 1, map.makeCell(Shape.partial, Code.partial(@intCast(i)), Ground.none, 0));
    for (0..4) |i| map.set(g, ex, @intCast(yard_y + 4 + i), 1, map.makeCell(Shape.solid, Code.diagonal(@intCast(i)), Ground.none, 0));
}

/// A spawn point near the start of the yard's west ramp, facing east.
pub const yard_spawn = .{ .x = yard_x, .y = yard_y + 4 };

test "test map builds and the yard has a ramp" {
    const g = try std.testing.allocator.create(map.Grid);
    defer std.testing.allocator.destroy(g);
    build(g);
    const fx = @import("fixed.zig");
    // Road cell at street level.
    try std.testing.expectEqual(Ground.road, map.groundOf(map.cellAt(g, lo, lo, 0)));
    // Platform top.
    const p = fx.fromInt(yard_x + 4) + fx.half;
    try std.testing.expectEqual(fx.fromInt(2), map.floorAt(g, p, p, fx.fromInt(2), map.ped_step));
    // Halfway up the 45 degree ramp.
    const rx = fx.fromInt(yard_x + 2) + fx.half;
    try std.testing.expectEqual(fx.fromInt(1) + fx.half, map.floorAt(g, rx, p, fx.fromInt(1) + fx.half, map.ped_step));
}
