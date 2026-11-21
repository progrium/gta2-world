//! GPU-ready views of a parsed style. Almost everything is uploaded as the
//! raw chunk bytes, so loading costs no CPU work in the browser:
//!
//!   - Index texture array (R8UI, 256 x 256 per layer): the TILE pages
//!     (16 tiles each, 4 x 4) followed by the SPRG pages. Tile t lives in
//!     layer t / 16 at ((t % 4) * 64, (t % 16 / 4) * 64).
//!   - Physical palettes (RGBA8, 64 x 256 per PPAL page, pages stacked):
//!     the PPAL chunk as is. Palette p, entry i is texel
//!     (p % 64, (p / 64) * 256 + i), stored B, G, R, _.
//!   - PALX (R16UI, 128 x 128): virtual palette -> physical palette.
//!   - Sprite table (RGBA16UI, `sprite_table_width` wide): per sprite
//!     x, y, layer, w | h << 8, built here.
//!
//! Virtual palettes: tile t uses `palette_base.tile + t`, sprite s uses
//! `palette_base.sprite + s`, and a remap r of a group uses that group's
//! palette base + r (`remapPalette`). This follows our reading of the DMA
//! style document.

const std = @import("std");
const formats = @import("formats");
const sty = formats.sty;

pub const sprite_table_width = 64;

pub const SpriteRect = extern struct {
    x: u16,
    y: u16,
    layer: u16,
    wh: u16,
};

pub const SpriteGroup = sty.SpriteBase.Kind;

pub const Prepared = struct {
    /// Number of 256 x 256 layers of tiles, then of sprites.
    tile_layers: u32,
    sprite_layers: u32,
    /// `sprite_table_width * rows` entries, zero padded.
    sprite_table: []SpriteRect,

    pub fn deinit(p: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(p.sprite_table);
    }
};

pub fn tileLayers(s: *const sty.Style) u32 {
    return @intCast((s.tiles.len + sty.page_bytes - 1) / sty.page_bytes);
}

pub fn spriteLayers(s: *const sty.Style) u32 {
    return @intCast((s.sprite_graphics.len + sty.page_bytes - 1) / sty.page_bytes);
}

pub fn prepare(gpa: std.mem.Allocator, s: *const sty.Style) !Prepared {
    const tl = tileLayers(s);
    const n = s.sprites.len;
    const rows = @max(1, (n + sprite_table_width - 1) / sprite_table_width);
    const table = try gpa.alloc(SpriteRect, rows * sprite_table_width);
    @memset(table, .{ .x = 0, .y = 0, .layer = 0, .wh = 0 });
    for (s.sprites, 0..) |e, i| {
        const page = e.ptr / sty.page_bytes;
        const within = e.ptr % sty.page_bytes;
        table[i] = .{
            .x = @intCast(within % sty.page_size),
            .y = @intCast(within / sty.page_size),
            .layer = @intCast(tl + page),
            .wh = @as(u16, e.w) | (@as(u16, e.h) << 8),
        };
    }
    return .{ .tile_layers = tl, .sprite_layers = spriteLayers(s), .sprite_table = table };
}

/// Absolute sprite number of entry `rel` of a sprite group.
pub fn spriteIndex(s: *const sty.Style, group: SpriteGroup, rel: u32) u32 {
    return s.sprite_base.base(group) + rel;
}

/// Virtual palette for remap `r` of a group (cars, peds, ...).
pub fn remapPalette(s: *const sty.Style, group: sty.PaletteBase.Kind, r: u32) u32 {
    return s.palette_base.base(group) + r;
}

test "sprite table" {
    const gpa = std.testing.allocator;
    var s: sty.Style = .{ .arena = .init(gpa), .version = 0, .palx = &.{}, .ppal = &.{}, .tiles = &.{} };
    defer s.deinit();
    var tiles: [2 * sty.page_bytes]u8 = undefined;
    s.tiles = &tiles;
    var sprites = [_]sty.SpriteEntry{ .{ .ptr = 0, .w = 8, .h = 4 }, .{ .ptr = sty.page_bytes + 3 * 256 + 5, .w = 64, .h = 32 } };
    s.sprites = &sprites;
    var p = try prepare(gpa, &s);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), p.tile_layers);
    try std.testing.expectEqual(SpriteRect{ .x = 5, .y = 3, .layer = 3, .wh = 64 | 32 << 8 }, p.sprite_table[1]);
    try std.testing.expectEqual(@as(usize, 64), p.sprite_table.len);
}
