//! Synthetic demo map and style, carried forward from the S1 viewer and
//! extended with road arrows, coloured lights, car and ped sprites and car
//! remaps, so the renderer demo runs end to end with no game files.
//! Contains no original game data: every tile and sprite is generated here. The map shows every slope code,
//! flats, rotations, flips and lighting levels in the top-left corner, and
//! fills the rest of the 256x256 grid with a procedural city so the frame
//! rate test has a realistic amount of geometry.

const std = @import("std");
const formats = @import("formats");
const gmp = formats.gmp;
const synth = formats.synth;

pub const T = struct {
    pub const road = 1;
    pub const pavement = 2;
    pub const grass = 3;
    pub const brick = 4;
    pub const roof = 5;
    pub const fence = 6;
    pub const grate = 7;
    pub const arrow = 8;
    pub const water = 9;
    pub const concrete = 10;
    pub const window = 11;
    pub const number0 = 16; // number0 + n shows n, for n in 0..63
};

pub const tile_count = 96;

const digits = [10][5]u3{
    .{ 7, 5, 5, 5, 7 }, .{ 2, 6, 2, 2, 7 }, .{ 7, 1, 7, 4, 7 }, .{ 7, 1, 3, 1, 7 }, .{ 5, 5, 7, 1, 1 },
    .{ 7, 4, 7, 1, 7 }, .{ 7, 4, 7, 5, 7 }, .{ 7, 1, 1, 2, 2 }, .{ 7, 5, 7, 5, 7 }, .{ 7, 5, 7, 1, 7 },
};

fn hsv(h: f32, s: f32, v: f32) formats.sty.Rgba {
    const i: u32 = @intFromFloat(@floor(h * 6));
    const f = h * 6 - @floor(h * 6);
    const p = v * (1 - s);
    const q = v * (1 - f * s);
    const t = v * (1 - (1 - f) * s);
    const rgb: [3]f32 = switch (i % 6) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return .{ @intFromFloat(rgb[0] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[2] * 255), 255 };
}

/// Palette layout for every synthetic tile: 1 base, 2 dark, 3 light,
/// 4 white, 5 black, 6 yellow.
fn setPalette(s: *synth.StyleBuilder, t: u32, base: formats.sty.Rgba) void {
    const p = s.palettes[t * 256 ..][0..256];
    p[0] = .{ 0, 0, 0, 0 };
    p[1] = base;
    p[2] = .{ base[0] / 2, base[1] / 2, base[2] / 2, 255 };
    p[3] = .{ base[0] / 2 + 128, base[1] / 2 + 128, base[2] / 2 + 128, 255 };
    p[4] = .{ 255, 255, 255, 255 };
    p[5] = .{ 0, 0, 0, 255 };
    p[6] = .{ 255, 220, 0, 255 };
}

fn fill(s: *synth.StyleBuilder, t: u32, f: anytype) void {
    for (0..64) |y| for (0..64) |x| {
        s.pixel(t, @intCast(x), @intCast(y)).* = f.at(@intCast(x), @intCast(y));
    };
}

pub fn buildStyle(gpa: std.mem.Allocator) !synth.StyleBuilder {
    var s = try synth.StyleBuilder.init(gpa, tile_count);
    errdefer s.deinit();
    for (0..tile_count) |t| setPalette(&s, @intCast(t), .{ 128, 128, 128, 255 });

    setPalette(&s, T.road, .{ 70, 70, 75, 255 });
    fill(&s, T.road, struct {
        fn at(x: u32, y: u32) u8 {
            return if (x >= 30 and x < 34 and (y / 8) % 2 == 0) 6 else 1;
        }
    });
    setPalette(&s, T.pavement, .{ 170, 165, 150, 255 });
    fill(&s, T.pavement, struct {
        fn at(x: u32, y: u32) u8 {
            return if (x % 32 == 0 or y % 32 == 0) 2 else 1;
        }
    });
    setPalette(&s, T.grass, .{ 60, 140, 50, 255 });
    fill(&s, T.grass, struct {
        fn at(x: u32, y: u32) u8 {
            const h = (x *% 7919 +% y *% 104729) % 11;
            return if (h == 0) 2 else if (h == 1) 3 else 1;
        }
    });
    setPalette(&s, T.brick, .{ 150, 60, 45, 255 });
    fill(&s, T.brick, struct {
        fn at(x: u32, y: u32) u8 {
            const row = y / 8;
            const off: u32 = if (row % 2 == 0) 0 else 8;
            return if (y % 8 == 0 or (x + off) % 16 == 0) 3 else 1;
        }
    });
    setPalette(&s, T.roof, .{ 50, 60, 110, 255 });
    fill(&s, T.roof, struct {
        fn at(x: u32, y: u32) u8 {
            return if (x < 2 or y < 2 or x > 61 or y > 61) 3 else if ((x + y) % 16 == 0) 2 else 1;
        }
    });
    setPalette(&s, T.fence, .{ 90, 90, 90, 255 });
    fill(&s, T.fence, struct {
        fn at(x: u32, y: u32) u8 {
            if (y < 4) return 2;
            if (y >= 16 and (x % 12 < 2 or (x + y) % 12 < 2)) return 1;
            return 0;
        }
    });
    setPalette(&s, T.grate, .{ 120, 120, 130, 255 });
    fill(&s, T.grate, struct {
        fn at(x: u32, y: u32) u8 {
            return if (x % 8 < 2 or y % 8 < 2) 3 else 0;
        }
    });
    setPalette(&s, T.arrow, .{ 110, 40, 150, 255 });
    fill(&s, T.arrow, struct {
        fn at(x: u32, y: u32) u8 {
            // Yellow marker at top-left reveals flips; arrow points up.
            if (x < 12 and y < 12) return 6;
            const cx: i32 = @as(i32, @intCast(x)) - 32;
            const yy: i32 = @intCast(y);
            if (yy >= 8 and yy < 30 and @abs(cx) <= @divTrunc(yy - 8, 1)) return 4;
            if (yy >= 30 and yy < 58 and @abs(cx) <= 6) return 4;
            return 1;
        }
    });
    setPalette(&s, T.water, .{ 30, 80, 170, 255 });
    fill(&s, T.water, struct {
        fn at(x: u32, y: u32) u8 {
            return if ((x + 2 * y) % 20 < 2) 3 else 1;
        }
    });
    setPalette(&s, T.concrete, .{ 150, 150, 150, 255 });
    fill(&s, T.concrete, struct {
        fn at(x: u32, y: u32) u8 {
            _ = x;
            return if (y % 16 == 0) 2 else 1;
        }
    });
    setPalette(&s, T.window, .{ 180, 170, 140, 255 });
    fill(&s, T.window, struct {
        fn at(x: u32, y: u32) u8 {
            const wx = x % 32;
            return if (wx >= 8 and wx < 24 and y >= 12 and y < 44) (if (y < 20) 3 else 2) else 1;
        }
    });

    for (0..64) |n| {
        const t: u32 = @intCast(T.number0 + n);
        setPalette(&s, t, hsv(@as(f32, @floatFromInt(n % 16)) / 16.0, 0.6, 0.75));
        for (0..64) |y| for (0..64) |x| {
            var c: u8 = 1;
            if (x < 3 or y < 3 or x > 60 or y > 60) c = 2;
            // Notch at the top edge marks which way is "up" in the tile.
            if (y < 10 and x >= 28 and x < 36) c = 4;
            s.pixel(t, @intCast(x), @intCast(y)).* = c;
        };
        const ds = [2]usize{ n / 10, n % 10 };
        for (ds, 0..) |d, k| {
            const ox = 11 + k * 24;
            for (0..5) |r| for (0..3) |col| {
                if ((digits[d][r] >> @intCast(2 - col)) & 1 == 0) continue;
                for (0..6) |dy| for (0..6) |dx| {
                    s.pixel(t, @intCast(ox + col * 6 + dx), @intCast(17 + r * 6 + dy)).* = 5;
                };
            };
        }
    }
    try addSprites(&s);
    return s;
}

pub const car_sprites = 8;
pub const car_remaps = 6;

/// Top-down cars facing up (toward -y, as GTA2 sprites do) and a few ped
/// frames. Palette: 1 body, 2 body dark, 3 glass, 4 lights, 5 tyres.
fn addSprites(s: *synth.StyleBuilder) !void {
    for (0..car_sprites) |i| {
        const w: u8 = @intCast(26 + (i % 3) * 4);
        const h: u8 = @intCast(52 + (i % 4) * 6);
        const sp = try s.addSprite(.car, w, h);
        sp.palette[1] = hsv(@as(f32, @floatFromInt(i)) / car_sprites, 0.7, 0.85);
        sp.palette[2] = .{ sp.palette[1][0] / 2, sp.palette[1][1] / 2, sp.palette[1][2] / 2, 255 };
        sp.palette[3] = .{ 60, 90, 120, 255 };
        sp.palette[4] = .{ 255, 250, 200, 255 };
        sp.palette[5] = .{ 20, 20, 20, 255 };
        for (0..h) |y| for (0..w) |x| {
            const inset: usize = if (y < 3 or y + 3 >= h) 3 else 0;
            var c: u8 = 0;
            if (x >= inset and x + inset < w) c = 1;
            if ((x < 2 or x + 2 >= w) and ((y > 8 and y < 18) or (y + 18 > h and y + 8 < h))) c = 5;
            if (x >= 4 and x + 4 < w and y > h / 5 and y < h / 5 + 8) c = 3;
            if (x >= 4 and x + 4 < w and y + h / 6 + 6 > h and y + h / 6 < h) c = 3;
            if (x >= 3 and x + 3 < w and (y == h / 5 + 8 or y + h / 6 == h)) c = 2;
            if (y < 3 and (x < 7 or x + 7 >= w) and x >= 2 and x + 2 < w) c = 4;
            sp.pixels[y * w + x] = c;
        };
    }
    for (0..4) |f| {
        const sp = try s.addSprite(.ped, 16, 16);
        sp.palette[1] = .{ 60, 80, 160, 255 };
        sp.palette[2] = .{ 230, 190, 150, 255 };
        sp.palette[3] = .{ 40, 30, 20, 255 };
        for (0..16) |y| for (0..16) |x| {
            const dx = @as(f32, @floatFromInt(x)) - 7.5;
            const dy = @as(f32, @floatFromInt(y)) - 7.5;
            var c: u8 = 0;
            if (@abs(dx) < 7 and @abs(dy) < 3.5) c = 1;
            if (dx * dx + dy * dy < 12) c = 2;
            if (dx * dx + (dy + 1) * (dy + 1) < 6) c = 3;
            // Walking: feet alternate with the frame.
            const foot: f32 = if (f % 2 == 0) -4 else 4;
            if (@abs(dx - 3) < 1.5 and @abs(dy - foot) < 2) c = 3;
            if (@abs(dx + 3) < 1.5 and @abs(dy + foot) < 2) c = 3;
            sp.pixels[y * 16 + x] = c;
        };
    }
    for (0..car_remaps) |r| {
        var pal: [256]formats.sty.Rgba = @splat(.{ 0, 0, 0, 255 });
        const body = hsv(@as(f32, @floatFromInt(r)) / car_remaps + 0.08, 0.9, 0.95);
        pal[1] = body;
        pal[2] = .{ body[0] / 2, body[1] / 2, body[2] / 2, 255 };
        pal[3] = .{ 60, 90, 120, 255 };
        pal[4] = .{ 255, 250, 200, 255 };
        pal[5] = .{ 20, 20, 20, 255 };
        try s.car_remaps.append(s.gpa, pal);
    }
}

fn face(tile: u10) gmp.Face {
    return .{ .tile = tile, .bit10 = true, .bit11 = true, .flat = false, .flip = false, .rotation = 0 };
}
fn lidFace(tile: u10) gmp.Face {
    return .{ .tile = tile, .bit10 = false, .bit11 = false, .flat = false, .flip = false, .rotation = 0 };
}

fn slopeBlock(code: u6) gmp.Block {
    const w = face(T.brick);
    return .{ .left = w, .right = w, .top = w, .bottom = w, .lid = lidFace(@intCast(T.number0 + @as(u32, code))), .slope_type = (@as(u8, code) << 2) | 1 };
}

fn ground(b: *synth.MapBuilder, x: usize, y: usize, tile: u10, kind: u8) void {
    b.set(x, y, 1, .{ .lid = lidFace(tile), .slope_type = kind });
}

pub fn buildMap(gpa: std.mem.Allocator) !synth.MapBuilder {
    var b = try synth.MapBuilder.init(gpa);
    errdefer b.deinit();

    // Water everywhere at z=0, ground at z=1 except the outer ring.
    for (0..256) |y| for (0..256) |x| {
        b.set(x, y, 0, .{ .lid = lidFace(T.water) });
        if (x >= 2 and y >= 2 and x < 254 and y < 254) ground(&b, x, y, T.pavement, 2);
    };

    // --- Showcase, x and y in 2..60, everything on top of the z=1 ground.
    const z = 2;
    // 26 degree ramps, two blocks each. "up" = high end at smaller y.
    b.set(4, 5, z, slopeBlock(2));
    b.set(4, 6, z, slopeBlock(1));
    b.set(6, 5, z, slopeBlock(3));
    b.set(6, 6, z, slopeBlock(4));
    b.set(8, 5, z, slopeBlock(6));
    b.set(9, 5, z, slopeBlock(5));
    b.set(11, 5, z, slopeBlock(7));
    b.set(12, 5, z, slopeBlock(8));
    // 7 degree ramps, eight blocks each.
    for (0..8) |i| {
        const c: u6 = @intCast(i);
        b.set(15, 11 - i, z, slopeBlock(9 + c)); // up
        b.set(17, 4 + i, z, slopeBlock(17 + c)); // down
        b.set(11 - i, 13, z, slopeBlock(25 + c)); // left
        b.set(4 + i, 15, z, slopeBlock(33 + c)); // right
    }
    // 45 degree, diagonals, diagonal slopes, partials.
    for (0..4) |i| {
        const c: u6 = @intCast(i);
        b.set(20 + 2 * i, 5, z, slopeBlock(41 + c));
        b.set(20 + 2 * i, 8, z, slopeBlock(45 + c));
        b.set(20 + 2 * i, 11, z, slopeBlock(49 + c));
        var spire = slopeBlock(49 + c);
        spire.lid = lidFace(1023);
        b.set(20 + 2 * i, 13, z, spire);
    }
    for (0..9) |i| b.set(20 + 2 * i, 16, z, slopeBlock(@intCast(53 + i)));

    // A building with windows and a flat roof, inner faces left blank as
    // the real compressor does.
    for (40..46) |x| for (4..10) |y| for (2..5) |bz| {
        var blk: gmp.Block = .{};
        if (x == 40) blk.left = face(T.window);
        if (x == 45) blk.right = face(T.window);
        if (y == 4) blk.top = face(T.window);
        if (y == 9) blk.bottom = face(T.window);
        if (bz == 4) blk.lid = lidFace(T.roof);
        b.set(x, y, bz, blk);
    };

    // Transparent flat fence on the top face of a row of blocks.
    for (40..49) |x| {
        var f = face(T.fence);
        f.flat = true;
        b.set(x, 20, z, .{ .top = f });
    }
    // Raised walkway with a transparent grate lid over grass.
    for (40..44) |x| for (23..26) |y| {
        ground(&b, x, y, T.grass, 3);
        var g = lidFace(T.grate);
        g.flat = true;
        b.set(x, y, z, .{ .lid = g });
    };

    // Rotations 0..3, then the same with flip, of the arrow tile.
    for (0..8) |i| {
        var f = lidFace(T.arrow);
        f.rotation = @intCast(i % 4);
        f.flip = i >= 4;
        b.set(4 + i, 28, 1, .{ .lid = f, .slope_type = 2 });
    }
    // Lighting levels 0..3.
    for (0..4) |i| {
        var f = lidFace(T.number0 + @as(u10, @intCast(i)));
        f.bit10 = (i & 1) != 0;
        f.bit11 = (i & 2) != 0;
        b.set(4 + i, 31, 1, .{ .lid = f, .slope_type = 2 });
    }

    // --- Procedural city everywhere else: 10x10 lots with 2-wide roads.
    var prng = std.Random.DefaultPrng.init(2);
    const r = prng.random();
    for (2..254) |y| for (2..254) |x| {
        if (x < 62 and y < 62) continue;
        const lx = x % 12;
        const ly = y % 12;
        if (lx < 2 or ly < 2) {
            // Right-hand traffic. gmp arrow bits: 1 -x, 2 +x, 4 -y, 8 +y.
            var arrows: u8 = 0;
            if (lx == 0) arrows |= 8;
            if (lx == 1) arrows |= 4;
            if (ly == 0) arrows |= 1;
            if (ly == 1) arrows |= 2;
            b.set(x, y, 1, .{ .lid = lidFace(T.road), .slope_type = 1, .arrows = arrows });
        }
    };
    var ly: usize = 2;
    while (ly + 12 <= 254) : (ly += 12) {
        var lx: usize = 2;
        while (lx + 12 <= 254) : (lx += 12) {
            if (lx < 62 and ly < 62) continue;
            const x0 = lx + 1;
            const y0 = ly + 1;
            if (r.uintLessThan(u32, 5) == 0) {
                for (x0..x0 + 10) |x| for (y0..y0 + 10) |y| ground(&b, x, y, T.grass, 3);
                continue;
            }
            // Two buildings per lot with random heights.
            const split = 3 + r.uintLessThan(usize, 5);
            const parts = [2][4]usize{ .{ x0, y0, x0 + split, y0 + 10 }, .{ x0 + split, y0, x0 + 10, y0 + 10 } };
            for (parts) |p| {
                const top = 2 + r.uintLessThan(usize, 5);
                const wall_tile: u10 = if (r.boolean()) T.window else T.concrete;
                for (p[0]..p[2]) |x| for (p[1]..p[3]) |y| for (2..top + 1) |bz| {
                    var blk: gmp.Block = .{};
                    if (x == p[0]) blk.left = face(wall_tile);
                    if (x == p[2] - 1) blk.right = face(wall_tile);
                    if (y == p[1]) blk.top = face(wall_tile);
                    if (y == p[3] - 1) blk.bottom = face(wall_tile);
                    if (bz == top) blk.lid = lidFace(T.roof);
                    b.set(x, y, bz, blk);
                };
            }
        }
    }
    // Street lights at every other junction, in a few colours.
    var jy: usize = 62;
    while (jy < 250) : (jy += 24) {
        var jx: usize = 62;
        while (jx < 250) : (jx += 24) {
            const colours = [_]u32{ 0xffd080, 0x80c0ff, 0xff6040, 0x60ff90 };
            try b.lights.append(gpa, .{
                .argb = colours[(jx / 24 + jy / 24) % colours.len],
                .x = @intCast(jx * 128 + 128),
                .y = @intCast(jy * 128 + 128),
                .z = 3 * 128,
                .radius = 3 * 128,
                .intensity = 255,
                .shape = 0,
                .on_time = 0,
                .off_time = 0,
            });
        }
    }
    try b.zones.append(gpa, .{ .zone_type = 1, .x = 2, .y = 2, .w = 58, .h = 58, .name = "showcase" });
    return b;
}
