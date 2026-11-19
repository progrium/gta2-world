//! GTA2 style (.sty, "GBST") parser: palettes, tiles and sprite tables.
//!
//! Written from the published DMA document "GBH Style Format". Pure: takes
//! the file bytes, returns plain data, no I/O.
//!
//! Colour lookup for a tile pixel:
//!   index   = tile pixel byte (0 is transparent)
//!   virtual = palette_base.tile + tile number
//!   phys    = palx[virtual]
//!   colour  = ppal page phys/64, column phys%64, row index, as B,G,R,_ bytes

const std = @import("std");
const chunk = @import("chunk.zig");

pub const magic = "GBST";
pub const tile_size = 64;
pub const tile_bytes = tile_size * tile_size;
pub const page_size = 256;
pub const page_bytes = page_size * page_size;
pub const tiles_per_page = 16;
/// Tiles 992..1023 are reserved by the engine for animation.
pub const max_tiles = 992;
pub const palx_entries = 16384;
pub const palettes_per_page = 64;

pub const Error = chunk.Error || std.mem.Allocator.Error || error{
    MissingPalettes,
    MissingTiles,
};

/// PALB stores per-category counts; bases are their running sums.
pub const PaletteBase = struct {
    pub const Kind = enum { tile, sprite, car_remap, ped_remap, code_obj_remap, map_obj_remap, user_remap, font_remap };
    counts: [8]u16 = @splat(0),

    pub fn count(p: PaletteBase, k: Kind) u16 {
        return p.counts[@intFromEnum(k)];
    }
    pub fn base(p: PaletteBase, k: Kind) u32 {
        var sum: u32 = 0;
        for (p.counts[0..@intFromEnum(k)]) |c| sum += c;
        return sum;
    }
};

pub const SpriteBase = struct {
    pub const Kind = enum { car, ped, code_obj, map_obj, user, font };
    counts: [6]u16 = @splat(0),

    pub fn base(s: SpriteBase, k: Kind) u32 {
        var sum: u32 = 0;
        for (s.counts[0..@intFromEnum(k)]) |c| sum += c;
        return sum;
    }
};

pub const SpriteEntry = struct {
    /// Byte offset into `sprite_graphics` (pages are 256 bytes wide).
    ptr: u32,
    w: u8,
    h: u8,
};

pub const Rgba = [4]u8;

pub const Style = struct {
    arena: std.heap.ArenaAllocator,
    version: u16,
    palx: []u16,
    /// Raw PPAL pages.
    ppal: []const u8,
    palette_base: PaletteBase = .{},
    /// Raw TILE pages, 256x256 bytes each, 4x4 tiles per page.
    tiles: []const u8,
    sprite_graphics: []const u8 = &.{},
    sprites: []SpriteEntry = &.{},
    sprite_base: SpriteBase = .{},
    unknown_chunks: u32 = 0,

    pub fn deinit(s: *Style) void {
        s.arena.deinit();
    }

    pub fn tileCount(s: *const Style) u32 {
        return @intCast(s.tiles.len / tile_bytes);
    }

    pub fn physicalPaletteCount(s: *const Style) u32 {
        return @intCast(s.ppal.len / 1024);
    }

    /// Palette index of pixel (x, y) of `tile`, or 0 if the tile is absent.
    pub fn tilePixel(s: *const Style, tile: u32, x: u32, y: u32) u8 {
        if (tile >= s.tileCount()) return 0;
        const page = tile / tiles_per_page;
        const rel = tile % tiles_per_page;
        const px = (rel % 4) * tile_size + x;
        const py = (rel / 4) * tile_size + y;
        return s.tiles[page * page_bytes + py * page_size + px];
    }

    pub fn tilePhysicalPalette(s: *const Style, tile: u32) u16 {
        const v = s.palette_base.base(.tile) + tile;
        return if (v < s.palx.len) s.palx[v] else 0;
    }

    /// RGBA colour of entry `index` of physical palette `phys`. Alpha is
    /// 0 for index 0 (transparent) and 255 otherwise.
    pub fn color(s: *const Style, phys: u32, index: u8) Rgba {
        const page = phys / palettes_per_page;
        const colm = phys % palettes_per_page;
        const off = page * page_bytes + (@as(u32, index) * palettes_per_page + colm) * 4;
        if (off + 4 > s.ppal.len) return .{ 0, 0, 0, 0 };
        const p = s.ppal[off..][0..4];
        return .{ p[2], p[1], p[0], if (index == 0) 0 else 255 };
    }

    /// Writes the 256 colours a tile uses.
    pub fn tilePalette(s: *const Style, tile: u32, out: *[256]Rgba) void {
        const phys = s.tilePhysicalPalette(tile);
        for (out, 0..) |*c, i| c.* = s.color(phys, @intCast(i));
    }
};

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Style {
    const header = try chunk.readHeader(bytes, magic);
    var style: Style = .{
        .arena = .init(gpa),
        .version = header.version,
        .palx = &.{},
        .ppal = &.{},
        .tiles = &.{},
    };
    errdefer style.arena.deinit();
    const a = style.arena.allocator();

    var have_palx = false;
    var it = chunk.iterate(bytes);
    while (try it.next()) |c| {
        if (c.is("PALX")) {
            style.palx = try a.alloc(u16, palx_entries);
            @memset(style.palx, 0);
            const n = @min(palx_entries, c.data.len / 2);
            for (style.palx[0..n], 0..) |*p, i| p.* = std.mem.readInt(u16, c.data[i * 2 ..][0..2], .little);
            have_palx = true;
        } else if (c.is("PPAL")) {
            style.ppal = try a.dupe(u8, c.data);
        } else if (c.is("PALB")) {
            var r: chunk.Reader = .{ .bytes = c.data };
            for (&style.palette_base.counts) |*n| n.* = r.int(u16) catch 0;
        } else if (c.is("TILE")) {
            style.tiles = try a.dupe(u8, c.data);
        } else if (c.is("SPRG")) {
            style.sprite_graphics = try a.dupe(u8, c.data);
        } else if (c.is("SPRX")) {
            const n = c.data.len / 8;
            style.sprites = try a.alloc(SpriteEntry, n);
            var r: chunk.Reader = .{ .bytes = c.data };
            for (style.sprites) |*e| {
                e.ptr = try r.int(u32);
                e.w = try r.int(u8);
                e.h = try r.int(u8);
                _ = try r.int(u16);
            }
        } else if (c.is("SPRB")) {
            var r: chunk.Reader = .{ .bytes = c.data };
            for (&style.sprite_base.counts) |*n| n.* = r.int(u16) catch 0;
        } else if (isKnownUnused(c)) {
            // DELS, DELX, FONB, CARI, OBJI, PSXT, RECY, SPEC: not needed yet.
        } else {
            style.unknown_chunks += 1;
        }
    }
    if (!have_palx or style.ppal.len == 0) return error.MissingPalettes;
    if (style.tiles.len == 0) return error.MissingTiles;
    return style;
}

fn isKnownUnused(c: chunk.Chunk) bool {
    const known = [_]*const [4]u8{ "DELS", "DELX", "FONB", "CARI", "OBJI", "PSXT", "RECY", "SPEC" };
    for (known) |k| if (c.is(k)) return true;
    return false;
}

test "palette base sums" {
    const p: PaletteBase = .{ .counts = .{ 992, 10, 20, 0, 0, 0, 0, 0 } };
    try std.testing.expectEqual(@as(u32, 0), p.base(.tile));
    try std.testing.expectEqual(@as(u32, 992), p.base(.sprite));
    try std.testing.expectEqual(@as(u32, 1002), p.base(.car_remap));
}
