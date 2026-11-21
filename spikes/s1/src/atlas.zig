//! GPU-friendly copies of the style's tile data for the S1 viewer:
//! an 8-bit index atlas (32x32 tiles of 64x64) and one 256-colour RGBA row
//! per tile. The shader looks up index -> colour itself, which keeps
//! palette index 0 exact for transparency.

const std = @import("std");
const sty = @import("formats").sty;

pub const tiles_across = 32;
pub const atlas_size = tiles_across * sty.tile_size; // 2048
pub const max_tiles = tiles_across * tiles_across; // 1024

pub fn buildIndexAtlas(style: *const sty.Style, out: []u8) void {
    std.debug.assert(out.len == atlas_size * atlas_size);
    @memset(out, 0);
    const n = @min(style.tileCount(), max_tiles);
    for (0..n) |t| {
        const ox = (t % tiles_across) * 64;
        const oy = (t / tiles_across) * 64;
        for (0..64) |y| for (0..64) |x| {
            out[(oy + y) * atlas_size + ox + x] = style.tilePixel(@intCast(t), @intCast(x), @intCast(y));
        };
    }
}

/// 256 x 1024 RGBA8: row t is tile t's palette.
pub fn buildPaletteRows(style: *const sty.Style, out: []u8) void {
    std.debug.assert(out.len == 256 * max_tiles * 4);
    @memset(out, 0);
    const n = @min(style.tileCount(), max_tiles);
    for (0..n) |t| {
        var pal: [256]sty.Rgba = undefined;
        style.tilePalette(@intCast(t), &pal);
        @memcpy(out[t * 1024 ..][0..1024], std.mem.sliceAsBytes(&pal));
    }
}
