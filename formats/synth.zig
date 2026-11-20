//! Writers for synthetic .gmp and .sty files. Used to build test fixtures
//! and demo content, since no original game data may live in this repo.
//! The writers follow the same reading of the DMA docs as the parsers, so a
//! round trip proves internal consistency, not agreement with the game.

const std = @import("std");
const gmp = @import("gmp.zig");
const sty = @import("sty.zig");

const Allocator = std.mem.Allocator;

fn putTag(out: *std.ArrayList(u8), gpa: Allocator, tag: *const [4]u8) !void {
    try out.appendSlice(gpa, tag);
}
fn putInt(out: *std.ArrayList(u8), gpa: Allocator, comptime T: type, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}
fn beginChunk(out: *std.ArrayList(u8), gpa: Allocator, tag: *const [4]u8) !usize {
    try putTag(out, gpa, tag);
    try putInt(out, gpa, u32, 0);
    return out.items.len;
}
fn endChunk(out: *std.ArrayList(u8), start: usize) void {
    std.mem.writeInt(u32, out.items[start - 4 ..][0..4], @intCast(out.items.len - start), .little);
}

pub const MapBuilder = struct {
    gpa: Allocator,
    cells: []gmp.Block,
    zones: std.ArrayList(gmp.Zone) = .empty,
    lights: std.ArrayList(gmp.Light) = .empty,

    pub fn init(gpa: Allocator) !MapBuilder {
        const cells = try gpa.alloc(gmp.Block, gmp.cell_count);
        @memset(cells, .air);
        return .{ .gpa = gpa, .cells = cells };
    }

    pub fn deinit(b: *MapBuilder) void {
        b.gpa.free(b.cells);
        b.zones.deinit(b.gpa);
        b.lights.deinit(b.gpa);
    }

    pub fn set(b: *MapBuilder, x: usize, y: usize, z: usize, block: gmp.Block) void {
        b.cells[gmp.Map.cellIndex(x, y, z)] = block;
    }

    pub fn get(b: *const MapBuilder, x: usize, y: usize, z: usize) gmp.Block {
        return b.cells[gmp.Map.cellIndex(x, y, z)];
    }

    pub const Format = enum { umap, cmap, dmap };

    /// Serialises the map. Caller owns the returned bytes.
    pub fn write(b: *const MapBuilder, format: Format) ![]u8 {
        const gpa = b.gpa;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try putTag(&out, gpa, gmp.magic);
        try putInt(&out, gpa, u16, 500);

        switch (format) {
            .umap => {
                const s = try beginChunk(&out, gpa, "UMAP");
                for (b.cells) |blk| {
                    var buf: [12]u8 = undefined;
                    blk.write(&buf);
                    try out.appendSlice(gpa, &buf);
                }
                endChunk(&out, s);
            },
            .cmap => try b.writeCompressed(u16, &out, "CMAP"),
            .dmap => try b.writeCompressed(u32, &out, "DMAP"),
        }

        if (b.zones.items.len > 0) {
            const s = try beginChunk(&out, gpa, "ZONE");
            for (b.zones.items) |z| {
                try out.appendSlice(gpa, &.{ z.zone_type, z.x, z.y, z.w, z.h, @intCast(z.name.len) });
                try out.appendSlice(gpa, z.name);
            }
            endChunk(&out, s);
        }
        if (b.lights.items.len > 0) {
            const s = try beginChunk(&out, gpa, "LGHT");
            for (b.lights.items) |l| {
                try putInt(&out, gpa, u32, l.argb);
                try putInt(&out, gpa, i16, l.x);
                try putInt(&out, gpa, i16, l.y);
                try putInt(&out, gpa, i16, l.z);
                try putInt(&out, gpa, i16, l.radius);
                try out.appendSlice(gpa, &.{ l.intensity, l.shape, l.on_time, l.off_time });
            }
            endChunk(&out, s);
        }
        return out.toOwnedSlice(gpa);
    }

    fn writeCompressed(b: *const MapBuilder, comptime W: type, out: *std.ArrayList(u8), tag: *const [4]u8) !void {
        const gpa = b.gpa;
        var blocks: std.ArrayList(gmp.Block) = .empty;
        defer blocks.deinit(gpa);
        var index: std.AutoHashMapUnmanaged([12]u8, W) = .empty;
        defer index.deinit(gpa);
        try blocks.append(gpa, .air);
        var air_key: [12]u8 = undefined;
        gmp.Block.air.write(&air_key);
        try index.put(gpa, air_key, 0);

        var base: std.ArrayList(W) = .empty;
        defer base.deinit(gpa);
        var column: std.ArrayList(W) = .empty;
        defer column.deinit(gpa);

        // Identical columns share storage, as the real compressor does; CMAP
        // could not even hold one header word per column otherwise.
        var seen: std.StringHashMapUnmanaged(W) = .empty;
        defer {
            var kit = seen.keyIterator();
            while (kit.next()) |k| gpa.free(k.*);
            seen.deinit(gpa);
        }
        var col: std.ArrayList(W) = .empty;
        defer col.deinit(gpa);

        for (0..gmp.size_y) |y| for (0..gmp.size_x) |x| {
            var lo: usize = gmp.size_z;
            var hi: usize = 0;
            for (0..gmp.size_z) |z| if (!b.get(x, y, z).isAir()) {
                lo = @min(lo, z);
                hi = z + 1;
            };
            if (hi == 0) lo = 0;
            col.clearRetainingCapacity();
            // Header word: u8 height, u8 offset (+ u16 pad for DMAP).
            try col.append(gpa, @as(W, @intCast(hi)) | (@as(W, @intCast(lo)) << 8));
            for (lo..hi) |z| {
                const blk = b.get(x, y, z);
                var key: [12]u8 = undefined;
                blk.write(&key);
                const gop = try index.getOrPut(gpa, key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(blocks.items.len);
                    try blocks.append(gpa, blk);
                }
                try col.append(gpa, gop.value_ptr.*);
            }
            const key = std.mem.sliceAsBytes(col.items);
            if (seen.get(key)) |at| {
                try base.append(gpa, at);
            } else {
                const at: W = @intCast(column.items.len);
                try seen.put(gpa, try gpa.dupe(u8, key), at);
                try base.append(gpa, at);
                try column.appendSlice(gpa, col.items);
            }
        };

        const s = try beginChunk(out, gpa, tag);
        for (base.items) |w| try putInt(out, gpa, W, w);
        try putInt(out, gpa, W, @intCast(column.items.len));
        for (column.items) |w| try putInt(out, gpa, W, w);
        try putInt(out, gpa, W, @intCast(blocks.items.len));
        for (blocks.items) |blk| {
            var buf: [12]u8 = undefined;
            blk.write(&buf);
            try out.appendSlice(gpa, &buf);
        }
        endChunk(out, s);
    }
};

/// Builds a style with `tile_count` tiles, where tile t uses physical
/// palette t (PALX is the identity) so every tile can have its own colours.
/// Sprites, if added, follow: sprite s uses virtual and physical palette
/// tile_count + s, and car remap palettes come after the sprites.
pub const StyleBuilder = struct {
    gpa: Allocator,
    tile_count: u32,
    /// tile_count * 4096 palette indices.
    pixels: []u8,
    /// tile_count * 256 colours.
    palettes: []sty.Rgba,
    sprites: std.ArrayList(Sprite) = .empty,
    /// Sprites per group, in `sty.SpriteBase.Kind` order. Sprites must be
    /// added group by group.
    sprite_counts: [6]u16 = @splat(0),
    car_remaps: std.ArrayList([256]sty.Rgba) = .empty,

    pub const Sprite = struct {
        w: u8,
        h: u8,
        /// w * h palette indices, row-major. Owned by the builder.
        pixels: []u8,
        palette: [256]sty.Rgba,
    };

    /// Adds a sprite to `group` and returns its pixels to fill (all 0).
    pub fn addSprite(s: *StyleBuilder, group: sty.SpriteBase.Kind, w: u8, h: u8) !*Sprite {
        const px = try s.gpa.alloc(u8, @as(usize, w) * h);
        @memset(px, 0);
        try s.sprites.append(s.gpa, .{ .w = w, .h = h, .pixels = px, .palette = @splat(.{ 0, 0, 0, 255 }) });
        s.sprite_counts[@intFromEnum(group)] += 1;
        return &s.sprites.items[s.sprites.items.len - 1];
    }

    pub fn init(gpa: Allocator, tile_count: u32) !StyleBuilder {
        const pixels = try gpa.alloc(u8, tile_count * sty.tile_bytes);
        @memset(pixels, 1);
        const palettes = try gpa.alloc(sty.Rgba, tile_count * 256);
        @memset(palettes, .{ 0, 0, 0, 255 });
        return .{ .gpa = gpa, .tile_count = tile_count, .pixels = pixels, .palettes = palettes };
    }

    pub fn deinit(s: *StyleBuilder) void {
        s.gpa.free(s.pixels);
        s.gpa.free(s.palettes);
        for (s.sprites.items) |sp| s.gpa.free(sp.pixels);
        s.sprites.deinit(s.gpa);
        s.car_remaps.deinit(s.gpa);
    }

    pub fn pixel(s: *StyleBuilder, tile: u32, x: u32, y: u32) *u8 {
        return &s.pixels[tile * sty.tile_bytes + y * sty.tile_size + x];
    }

    pub fn write(s: *const StyleBuilder) ![]u8 {
        const gpa = s.gpa;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try putTag(&out, gpa, sty.magic);
        try putInt(&out, gpa, u16, 700);

        const n_sprites: u32 = @intCast(s.sprites.items.len);
        const n_remaps: u32 = @intCast(s.car_remaps.items.len);
        const n_phys = s.tile_count + n_sprites + n_remaps;
        var c = try beginChunk(&out, gpa, "PALX");
        for (0..sty.palx_entries) |i| try putInt(&out, gpa, u16, if (i < n_phys) @intCast(i) else 0);
        endChunk(&out, c);

        const pages = (n_phys + sty.palettes_per_page - 1) / sty.palettes_per_page;
        c = try beginChunk(&out, gpa, "PPAL");
        const ppal = try out.addManyAsSlice(gpa, pages * sty.page_bytes);
        @memset(ppal, 0);
        for (0..n_phys) |p| for (0..256) |i| {
            const col = if (p < s.tile_count)
                s.palettes[p * 256 + i]
            else if (p < s.tile_count + n_sprites)
                s.sprites.items[p - s.tile_count].palette[i]
            else
                s.car_remaps.items[p - s.tile_count - n_sprites][i];
            const off = (p / 64) * sty.page_bytes + (i * 64 + p % 64) * 4;
            ppal[off..][0..4].* = .{ col[2], col[1], col[0], 0 };
        };
        endChunk(&out, c);

        c = try beginChunk(&out, gpa, "PALB");
        try putInt(&out, gpa, u16, @intCast(s.tile_count));
        try putInt(&out, gpa, u16, @intCast(n_sprites));
        try putInt(&out, gpa, u16, @intCast(n_remaps));
        for (0..5) |_| try putInt(&out, gpa, u16, 0);
        endChunk(&out, c);

        if (n_sprites > 0) try s.writeSprites(&out);

        const tpages = (s.tile_count + 15) / 16;
        c = try beginChunk(&out, gpa, "TILE");
        const tiles = try out.addManyAsSlice(gpa, tpages * sty.page_bytes);
        @memset(tiles, 0);
        for (0..s.tile_count) |t| {
            const page = t / 16;
            const rel = t % 16;
            for (0..64) |y| {
                const dst = page * sty.page_bytes + ((rel / 4) * 64 + y) * 256 + (rel % 4) * 64;
                @memcpy(tiles[dst..][0..64], s.pixels[t * sty.tile_bytes + y * 64 ..][0..64]);
            }
        }
        endChunk(&out, c);
        return out.toOwnedSlice(gpa);
    }

    /// SPRG (shelf-packed 256 x 256 pages), SPRX and SPRB.
    fn writeSprites(s: *const StyleBuilder, out: *std.ArrayList(u8)) !void {
        const gpa = s.gpa;
        const ptrs = try gpa.alloc(u32, s.sprites.items.len);
        defer gpa.free(ptrs);
        var page: u32 = 0;
        var x: u32 = 0;
        var y: u32 = 0;
        var shelf: u32 = 0;
        for (s.sprites.items, ptrs) |sp, *p| {
            if (x + sp.w > 256) {
                x = 0;
                y += shelf;
                shelf = 0;
            }
            if (y + sp.h > 256) {
                page += 1;
                x = 0;
                y = 0;
                shelf = 0;
            }
            p.* = page * sty.page_bytes + y * 256 + x;
            x += sp.w;
            shelf = @max(shelf, sp.h);
        }
        var c = try beginChunk(out, gpa, "SPRG");
        const g = try out.addManyAsSlice(gpa, (page + 1) * sty.page_bytes);
        @memset(g, 0);
        for (s.sprites.items, ptrs) |sp, p| for (0..sp.h) |row| {
            @memcpy(g[p + row * 256 ..][0..sp.w], sp.pixels[row * sp.w ..][0..sp.w]);
        };
        endChunk(out, c);
        c = try beginChunk(out, gpa, "SPRX");
        for (s.sprites.items, ptrs) |sp, p| {
            try putInt(out, gpa, u32, p);
            try out.appendSlice(gpa, &.{ sp.w, sp.h, 0, 0 });
        }
        endChunk(out, c);
        c = try beginChunk(out, gpa, "SPRB");
        for (s.sprite_counts) |n| try putInt(out, gpa, u16, n);
        endChunk(out, c);
    }
};

const testing = std.testing;

fn randomMap(gpa: Allocator, seed: u64) !MapBuilder {
    var b = try MapBuilder.init(gpa);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (0..3000) |_| {
        const blk: gmp.Block = .{
            .left = @bitCast(r.int(u16)),
            .right = @bitCast(r.int(u16)),
            .top = @bitCast(r.int(u16)),
            .bottom = @bitCast(r.int(u16)),
            .lid = @bitCast(r.int(u16) | 1),
            .arrows = r.int(u8),
            .slope_type = r.int(u8),
        };
        b.set(r.uintLessThan(usize, 256), r.uintLessThan(usize, 256), r.uintLessThan(usize, 8), blk);
    }
    return b;
}

fn expectSameMap(b: *const MapBuilder, m: *const gmp.Map) !void {
    for (0..gmp.size_z) |z| for (0..gmp.size_y) |y| for (0..gmp.size_x) |x| {
        try testing.expectEqual(b.get(x, y, z), m.get(x, y, z));
    };
}

test "DMAP, CMAP and UMAP round trip" {
    const gpa = testing.allocator;
    var b = try randomMap(gpa, 1);
    defer b.deinit();
    try b.zones.append(gpa, .{ .zone_type = 1, .x = 3, .y = 4, .w = 5, .h = 6, .name = "dtown" });
    inline for (.{ MapBuilder.Format.dmap, .cmap, .umap }) |fmt| {
        const bytes = try b.write(fmt);
        defer gpa.free(bytes);
        var m = try gmp.parse(gpa, bytes);
        defer m.deinit();
        try testing.expectEqual(@as(u16, 500), m.version);
        try expectSameMap(&b, &m);
        try testing.expectEqual(@as(usize, 1), m.zones.len);
        try testing.expectEqualStrings("dtown", m.zones[0].name);
    }
}

test "truncated map is rejected" {
    const gpa = testing.allocator;
    var b = try randomMap(gpa, 2);
    defer b.deinit();
    const bytes = try b.write(.dmap);
    defer gpa.free(bytes);
    try testing.expectError(error.Truncated, gmp.parse(gpa, bytes[0 .. bytes.len - 5]));
    try testing.expectError(error.BadMagic, gmp.parse(gpa, "GBST\x00\x00"));
}

test "corrupt column is rejected" {
    const gpa = testing.allocator;
    var b = try randomMap(gpa, 3);
    defer b.deinit();
    const bytes = try b.write(.dmap);
    defer gpa.free(bytes);
    // Point column (0,0) far past the end of the column data.
    const base0 = 6 + 8;
    std.mem.writeInt(u32, bytes[base0..][0..4], 0x7fffffff, .little);
    try testing.expectError(error.BadColumn, gmp.parse(gpa, bytes));
}

test "style round trip" {
    const gpa = testing.allocator;
    var s = try StyleBuilder.init(gpa, 70);
    defer s.deinit();
    s.pixel(69, 63, 63).* = 7;
    s.pixel(17, 5, 9).* = 0;
    s.palettes[69 * 256 + 7] = .{ 10, 20, 30, 255 };
    const bytes = try s.write();
    defer gpa.free(bytes);
    var st = try sty.parse(gpa, bytes);
    defer st.deinit();
    try testing.expectEqual(@as(u32, 80), st.tileCount()); // padded to whole pages
    try testing.expectEqual(@as(u8, 7), st.tilePixel(69, 63, 63));
    try testing.expectEqual(@as(u8, 0), st.tilePixel(17, 5, 9));
    try testing.expectEqual(@as(u8, 1), st.tilePixel(17, 6, 9));
    try testing.expectEqual(@as(u16, 69), st.tilePhysicalPalette(69));
    try testing.expectEqual(sty.Rgba{ 10, 20, 30, 255 }, st.color(69, 7));
    try testing.expectEqual(@as(u8, 0), st.color(69, 0)[3]);
}

test "style sprites and map lights round trip" {
    const gpa = testing.allocator;
    var s = try StyleBuilder.init(gpa, 16);
    defer s.deinit();
    const a = try s.addSprite(.car, 40, 64);
    a.pixels[3 * 40 + 2] = 9;
    a.palette[9] = .{ 1, 2, 3, 255 };
    for (0..10) |_| _ = try s.addSprite(.ped, 100, 100);
    try s.car_remaps.append(gpa, @splat(.{ 200, 0, 0, 255 }));
    const bytes = try s.write();
    defer gpa.free(bytes);
    var st = try sty.parse(gpa, bytes);
    defer st.deinit();
    try testing.expectEqual(@as(usize, 11), st.sprites.len);
    try testing.expectEqual(@as(u32, 1), st.sprite_base.base(.ped));
    try testing.expectEqual(@as(u8, 40), st.sprites[0].w);
    const p = st.sprites[0].ptr + 3 * 256 + 2;
    try testing.expectEqual(@as(u8, 9), st.sprite_graphics[p]);
    // 10 sprites of 100x100 need more than one page.
    try testing.expect(st.sprite_graphics.len >= 2 * sty.page_bytes);
    const phys = st.palx[st.palette_base.base(.sprite) + 0];
    try testing.expectEqual(sty.Rgba{ 1, 2, 3, 255 }, st.color(phys, 9));
    const rphys = st.palx[st.palette_base.base(.car_remap) + 0];
    try testing.expectEqual(sty.Rgba{ 200, 0, 0, 255 }, st.color(rphys, 5));

    var mb = try MapBuilder.init(gpa);
    defer mb.deinit();
    try mb.lights.append(gpa, .{ .argb = 0xff8040, .x = 100, .y = -5, .z = 64, .radius = 256, .intensity = 200, .shape = 0, .on_time = 1, .off_time = 2 });
    const mbytes = try mb.write(.dmap);
    defer gpa.free(mbytes);
    var m = try gmp.parse(gpa, mbytes);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.lights.len);
    try testing.expectEqual(mb.lights.items[0], m.lights[0]);
}
