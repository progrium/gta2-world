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
    /// The SPRG pages followed by pages of car delta overlays
    /// (`deltaOverlays`); upload these instead of the style's own pages.
    sprite_pages: []u8 = &.{},
    /// Car delta overlays: `car_sprites * delta_slots` entries, by car
    /// sprite (within the car group) and car delta number.
    overlays: []Overlay = &.{},
    car_sprites: u32 = 0,

    pub fn deinit(p: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(p.sprite_table);
        gpa.free(p.sprite_pages);
        gpa.free(p.overlays);
    }

    /// The overlay drawing delta `d` (0-31) over car sprite `car` (within
    /// the car group), or null if the style has none.
    pub fn overlay(p: *const Prepared, car: u32, d: u32) ?Overlay {
        if (car >= p.car_sprites or d >= delta_slots) return null;
        const o = p.overlays[car * delta_slots + d];
        return if (o.sprite == 0) null else o;
    }
};

/// Car delta numbers 0-31 (public style format document): 0-3 dents (rear
/// right, rear left, front left, front right), 4 windscreen, 5/22 brake
/// lights, 6/23 headlights, 7-14 and 24-31 door frames, 15-18 emergency
/// and roof lights. 22-31 mirror 5-14 and are made here.
pub const delta_slots = 32;
pub const delta_mirror_first = 22;
pub const delta_mirrored_from = 5;

/// A delta cut out as its own small sprite, drawn on top of the car: the
/// absolute sprite number and where its centre sits relative to the car
/// sprite's centre, in pixels (x right, y down in the image).
pub const Overlay = extern struct {
    sprite: u16 = 0,
    dx: i16 = 0,
    dy: i16 = 0,
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
    var p: Prepared = .{ .tile_layers = tl, .sprite_layers = spriteLayers(s), .sprite_table = table };
    errdefer gpa.free(table);
    try deltaOverlays(gpa, s, &p);
    return p;
}

const Run = struct { x: u32, y: u32, px: []const u8 };

/// Cuts every car delta out of DELS into a sprite of its own (its
/// bounding box), packed into pages after the style's sprites, so a car
/// is drawn as its sprite plus an overlay per delta shown. Deltas 22-31
/// are 5-14 flipped left to right about the car's centre line.
fn deltaOverlays(gpa: std.mem.Allocator, s: *const sty.Style, p: *Prepared) !void {
    const car_base = s.sprite_base.base(.car);
    const cars: u32 = @intCast(@min(s.sprites.len -| car_base, s.sprite_base.counts[0]));
    var pages: std.ArrayList(u8) = .empty;
    defer pages.deinit(gpa);
    try pages.appendSlice(gpa, s.sprite_graphics);
    // Pad the style's pages to a whole page.
    const whole = (pages.items.len + sty.page_bytes - 1) / sty.page_bytes * sty.page_bytes;
    try pages.appendNTimes(gpa, 0, whole - pages.items.len);
    var rects: std.ArrayList(SpriteRect) = .empty;
    defer rects.deinit(gpa);
    const overlays = try gpa.alloc(Overlay, @as(usize, cars) * delta_slots);
    errdefer gpa.free(overlays);
    @memset(overlays, .{});
    var page_start: usize = pages.items.len;
    var px: u32 = sty.page_size;
    var py: u32 = 0;
    var row_h: u32 = 0;
    var have_page = false;
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    for (s.delta_sets) |*set| {
        if (set.sprite < car_base or set.sprite - car_base >= cars) continue;
        const car = set.sprite - car_base;
        const e = s.sprites[set.sprite];
        for (0..delta_slots) |d| {
            const mirror = d >= delta_mirror_first and d < delta_mirror_first + 10;
            const src = if (mirror) d - delta_mirror_first + delta_mirrored_from else d;
            if (src >= set.sizes.len or (d >= set.sizes.len and !mirror)) continue;
            runs.clearRetainingCapacity();
            sty.forEachDeltaRun(s.delta(set, src), RunCtx{ .gpa = gpa, .list = &runs }, RunCtx.put);
            if (runs.items.len == 0) continue;
            // Bounding box, in the car sprite's pixels.
            var x0: u32 = 0xFFFF;
            var y0: u32 = 0xFFFF;
            var x1: u32 = 0;
            var y1: u32 = 0;
            for (runs.items) |r| {
                const rx0 = if (mirror) e.w -| (r.x + @as(u32, @intCast(r.px.len))) else r.x;
                x0 = @min(x0, rx0);
                x1 = @max(x1, rx0 + @as(u32, @intCast(r.px.len)));
                y0 = @min(y0, r.y);
                y1 = @max(y1, r.y + 1);
            }
            if (x1 <= x0 or y1 <= y0 or x1 > 256 or y1 > 256) continue;
            const w = x1 - x0;
            const h = y1 - y0;
            // Shelf packing into 256 x 256 pages.
            if (px + w > sty.page_size) {
                px = 0;
                py += row_h;
                row_h = 0;
            }
            if (!have_page or py + h > sty.page_size) {
                page_start = pages.items.len;
                try pages.appendNTimes(gpa, 0, sty.page_bytes);
                px = 0;
                py = 0;
                row_h = 0;
                have_page = true;
            }
            const page = pages.items[page_start..][0..sty.page_bytes];
            for (runs.items) |r| {
                for (r.px, 0..) |v, k| {
                    const sx: u32 = if (mirror) e.w -| 1 -| (r.x + @as(u32, @intCast(k))) else r.x + @as(u32, @intCast(k));
                    if (sx < x0 or sx >= x1) continue;
                    page[(py + r.y - y0) * sty.page_size + px + sx - x0] = v;
                }
            }
            const sprite = s.sprites.len + rects.items.len;
            if (sprite > 0xFFFF) break;
            try rects.append(gpa, .{
                .x = @intCast(px),
                .y = @intCast(py),
                .layer = @intCast(p.tile_layers + page_start / sty.page_bytes),
                .wh = @as(u16, @intCast(w)) | (@as(u16, @intCast(h)) << 8),
            });
            overlays[@as(usize, car) * delta_slots + d] = .{
                .sprite = @intCast(sprite),
                .dx = @intCast(@as(i32, @intCast(x0 * 2 + w)) - @as(i32, e.w)),
                .dy = @intCast(@as(i32, @intCast(y0 * 2 + h)) - @as(i32, e.h)),
            };
            px += w;
            row_h = @max(row_h, h);
        }
    }
    // Offsets above are doubled (centre maths in whole pixels); halve.
    for (overlays) |*o| {
        o.dx = @divTrunc(o.dx, 2);
        o.dy = @divTrunc(o.dy, 2);
    }
    if (rects.items.len > 0) {
        const n = s.sprites.len + rects.items.len;
        const rows = (n + sprite_table_width - 1) / sprite_table_width;
        const table = try gpa.alloc(SpriteRect, rows * sprite_table_width);
        @memset(table, .{ .x = 0, .y = 0, .layer = 0, .wh = 0 });
        @memcpy(table[0..s.sprites.len], p.sprite_table[0..s.sprites.len]);
        @memcpy(table[s.sprites.len..n], rects.items);
        gpa.free(p.sprite_table);
        p.sprite_table = table;
    }
    p.sprite_pages = try pages.toOwnedSlice(gpa);
    p.sprite_layers = @intCast(p.sprite_pages.len / sty.page_bytes);
    p.overlays = overlays;
    p.car_sprites = cars;
}

const RunCtx = struct {
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Run),
    fn put(c: RunCtx, x: u32, y: u32, px: []const u8) void {
        c.list.append(c.gpa, .{ .x = x, .y = y, .px = px }) catch {};
    }
};

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
