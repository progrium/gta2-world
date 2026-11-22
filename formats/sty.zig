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

/// One car model from the CARI chunk (public DMA style format document):
/// sizes in pixels (64 to a block), wheel and window offsets in signed
/// pixels along the car's length from its centre.
pub const CarInfo = struct {
    model: u8,
    /// How many sprites this model adds to the car sprite group (1, or 0
    /// for a model drawn with the one before it); see `carSprite`.
    sprite: u8,
    w: u8,
    h: u8,
    num_remaps: u8,
    passengers: u8,
    wreck: u8,
    rating: u8,
    front_wheel: i8,
    rear_wheel: i8,
    front_window: i8,
    rear_window: i8,
    info_flags: u8,
    info_flags_2: u8,
    /// Remap palettes (relative), at most 16 kept.
    remaps: [16]u8 = @splat(0),
    num_doors: u8 = 0,
};

/// The deltas of one sprite (DELX, public format document): small patches
/// written over the sprite to show dents, lights, opening doors and the
/// like. `first` is the byte offset of the set's first delta in DELS and
/// `sizes` the byte size of each delta, in order.
pub const DeltaSet = struct {
    sprite: u16,
    first: u32,
    sizes: []const u16,
};

/// Walks one delta's records (offset u16, length u8, data). Offsets are
/// relative to the position the last record ended at, starting at the
/// sprite's top left, in a 256-pixel-wide page. Calls `put(x, y, pixels)`
/// for each run, with x and y relative to the sprite.
pub fn forEachDeltaRun(delta: []const u8, ctx: anytype, comptime put: fn (@TypeOf(ctx), u32, u32, []const u8) void) void {
    var pos: u32 = 0;
    var o: usize = 0;
    while (o + 3 <= delta.len) {
        const off = std.mem.readInt(u16, delta[o..][0..2], .little);
        const len = delta[o + 2];
        o += 3;
        if (o + len > delta.len) break;
        pos += off;
        put(ctx, pos % page_size, pos / page_size, delta[o..][0..len]);
        pos += len;
        o += len;
    }
}

/// A map object model's sprites (OBJI).
pub const ObjectInfo = struct { model: u8, sprites: u8 };

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
    /// Car models from CARI, in file order.
    cars: []CarInfo = &.{},
    /// Map object models from OBJI, in file order.
    objects: []ObjectInfo = &.{},
    /// Delta sets from DELX, in file order (and DELS order).
    delta_sets: []DeltaSet = &.{},
    /// Raw DELS bytes the sets point into.
    delta_store: []const u8 = &.{},
    unknown_chunks: u32 = 0,

    /// The deltas of absolute sprite `sprite`, or null if it has none.
    pub fn deltasOf(s: *const Style, sprite: u16) ?*const DeltaSet {
        for (s.delta_sets) |*d| if (d.sprite == sprite) return d;
        return null;
    }

    /// Bytes of delta `i` of a set (empty past the end).
    pub fn delta(s: *const Style, set: *const DeltaSet, i: usize) []const u8 {
        if (i >= set.sizes.len) return &.{};
        var o: usize = set.first;
        for (set.sizes[0..i]) |z| o += z;
        const end = @min(s.delta_store.len, o + set.sizes[i]);
        return if (o >= end) &.{} else s.delta_store[o..end];
    }

    pub fn deinit(s: *Style) void {
        s.arena.deinit();
    }

    /// Sprite of car model entry `i` within the car sprite group: the sum
    /// of the sprite counts before it, the previous one if it adds none.
    pub fn carSprite(s: *const Style, i: usize) u16 {
        var n: u16 = 0;
        for (s.cars[0..@min(i, s.cars.len)]) |c| n += c.sprite;
        if (i < s.cars.len and s.cars[i].sprite == 0 and n > 0) n -= 1;
        return n;
    }

    /// First sprite of object `model` within the map-object sprite group
    /// (the sum of the sprite counts of the OBJI entries before it) and its
    /// sprite count, or null for a model the style lacks.
    pub fn objectSprites(s: *const Style, model: u16) ?struct { first: u16, count: u8 } {
        var n: u16 = 0;
        for (s.objects) |o| {
            if (o.model == model) return .{ .first = n, .count = o.sprites };
            n += o.sprites;
        }
        return null;
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
        } else if (c.is("CARI")) {
            style.cars = try parseCars(a, c.data);
        } else if (c.is("OBJI")) {
            // object_info: u8 model, u8 sprites (public format document).
            style.objects = try a.alloc(ObjectInfo, c.data.len / 2);
            for (style.objects, 0..) |*o, i| o.* = .{ .model = c.data[i * 2], .sprites = c.data[i * 2 + 1] };
        } else if (c.is("DELS")) {
            style.delta_store = try a.dupe(u8, c.data);
        } else if (c.is("DELX")) {
            style.delta_sets = try parseDeltaIndex(a, c.data);
        } else if (isKnownUnused(c)) {
            // FONB, PSXT, RECY, SPEC: not needed yet.
        } else {
            style.unknown_chunks += 1;
        }
    }
    if (!have_palx or style.ppal.len == 0) return error.MissingPalettes;
    if (style.tiles.len == 0) return error.MissingTiles;
    return style;
}

/// CARI: car_info records back to back. Each is 14 bytes of fixed fields,
/// `num_remaps` remap bytes, a door count, and two signed bytes per door.
fn parseCars(a: std.mem.Allocator, data: []const u8) Error![]CarInfo {
    var list: std.ArrayList(CarInfo) = .empty;
    var o: usize = 0;
    while (o + 15 <= data.len) {
        const b = data[o..];
        var ci: CarInfo = .{
            .model = b[0],
            .sprite = b[1],
            .w = b[2],
            .h = b[3],
            .num_remaps = b[4],
            .passengers = b[5],
            .wreck = b[6],
            .rating = b[7],
            .front_wheel = @bitCast(b[8]),
            .rear_wheel = @bitCast(b[9]),
            .front_window = @bitCast(b[10]),
            .rear_window = @bitCast(b[11]),
            .info_flags = b[12],
            .info_flags_2 = b[13],
        };
        var p: usize = 14;
        const nr = ci.num_remaps;
        if (p + nr + 1 > b.len) break;
        for (0..@min(nr, ci.remaps.len)) |k| ci.remaps[k] = b[p + k];
        p += nr;
        ci.num_doors = b[p];
        p += 1 + 2 * @as(usize, ci.num_doors);
        if (p > b.len) break;
        try list.append(a, ci);
        o += p;
    }
    return list.toOwnedSlice(a);
}

/// DELX: delta_entry records (u16 sprite, u8 count, u8 pad, u16 size per
/// delta). The store holds the sets back to back in the same order.
fn parseDeltaIndex(a: std.mem.Allocator, data: []const u8) Error![]DeltaSet {
    var list: std.ArrayList(DeltaSet) = .empty;
    var o: usize = 0;
    var at: u32 = 0;
    while (o + 4 <= data.len) {
        const sprite = std.mem.readInt(u16, data[o..][0..2], .little);
        const n = data[o + 2];
        o += 4;
        if (o + 2 * @as(usize, n) > data.len) break;
        const sizes = try a.alloc(u16, n);
        var total: u32 = 0;
        for (sizes, 0..) |*z, k| {
            z.* = std.mem.readInt(u16, data[o + 2 * k ..][0..2], .little);
            total += z.*;
        }
        o += 2 * @as(usize, n);
        try list.append(a, .{ .sprite = sprite, .first = at, .sizes = sizes });
        at += total;
    }
    return list.toOwnedSlice(a);
}

fn isKnownUnused(c: chunk.Chunk) bool {
    const known = [_]*const [4]u8{ "FONB", "CARI", "OBJI", "PSXT", "RECY", "SPEC" };
    for (known) |k| if (c.is(k)) return true;
    return false;
}

test "palette base sums" {
    const p: PaletteBase = .{ .counts = .{ 992, 10, 20, 0, 0, 0, 0, 0 } };
    try std.testing.expectEqual(@as(u32, 0), p.base(.tile));
    try std.testing.expectEqual(@as(u32, 992), p.base(.sprite));
    try std.testing.expectEqual(@as(u32, 1002), p.base(.car_remap));
}

test "object sprites count from the OBJI order" {
    var objs = [_]ObjectInfo{ .{ .model = 7, .sprites = 4 }, .{ .model = 1, .sprites = 6 }, .{ .model = 3, .sprites = 1 } };
    var s: Style = .{ .arena = undefined, .version = 700, .palx = &.{}, .ppal = &.{}, .tiles = &.{}, .objects = &objs };
    try std.testing.expectEqual(@as(u16, 0), s.objectSprites(7).?.first);
    try std.testing.expectEqual(@as(u16, 4), s.objectSprites(1).?.first);
    try std.testing.expectEqual(@as(u16, 10), s.objectSprites(3).?.first);
    try std.testing.expectEqual(@as(u8, 6), s.objectSprites(1).?.count);
    try std.testing.expect(s.objectSprites(2) == null);
}
