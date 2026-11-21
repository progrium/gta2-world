//! GTA2 map (.gmp, "GBMP") parser.
//!
//! Written from the published DMA document "GBH Map Format" (v8.2, Aug 1999).
//! Everything here is pure: it takes the file bytes and returns plain data.
//! No I/O, so it runs unchanged in WASM, native tools and tests.
//!
//! World conventions used throughout this repo (the DMA doc leaves them
//! implicit; these follow the community editors and must be checked against
//! the game, see spikes/s1/RESULT.md):
//!   x grows east (to the "right"), y grows south (to the "bottom"),
//!   z grows up. A block (x, y, z) spans [x, x+1] x [y, y+1] x [z, z+1].
//!   `left` is the face at x, `right` at x+1, `top` at y, `bottom` at y+1,
//!   `lid` is the upper face.

const std = @import("std");
const chunk = @import("chunk.zig");

pub const magic = "GBMP";
pub const size_x = 256;
pub const size_y = 256;
pub const size_z = 8;
pub const cell_count = size_x * size_y * size_z;

pub const Error = chunk.Error || std.mem.Allocator.Error || error{
    NoMapChunk,
    BadColumn,
    BadBlockIndex,
};

/// A side or lid face word. Bits 10 and 11 mean wall / bullet-wall on side
/// faces and a 2-bit lighting level on lids.
pub const Face = packed struct(u16) {
    tile: u10,
    bit10: bool,
    bit11: bool,
    flat: bool,
    flip: bool,
    /// 0, 90, 180, 270 degrees.
    rotation: u2,

    pub const empty: Face = @bitCast(@as(u16, 0));

    pub fn wall(f: Face) bool {
        return f.bit10;
    }
    pub fn bulletWall(f: Face) bool {
        return f.bit11;
    }
    /// Lid only: 0 normal, 1..3 progressively darker.
    pub fn lighting(f: Face) u2 {
        return @as(u2, @intFromBool(f.bit10)) | (@as(u2, @intFromBool(f.bit11)) << 1);
    }
    pub fn isEmpty(f: Face) bool {
        return f.tile == 0;
    }
};

pub const GroundType = enum(u2) { air = 0, road = 1, pavement = 2, field = 3 };

pub const Dir = enum(u2) { up, down, left, right };
pub const Corner = enum(u2) { up_left, up_right, down_left, down_right };
pub const Partial = enum(u4) {
    left,
    right,
    top,
    bottom,
    top_left,
    top_right,
    bottom_right,
    bottom_left,
    centre,
};

/// The 6-bit slope code decoded into a shape. "up" means the high end is
/// toward the top of the map (smaller y), per the editors' "arrow points at
/// the high end" rule.
pub const Shape = union(enum) {
    cube,
    /// A ramp whose lid rises from `low/denom` to `high/denom` of a block
    /// height, ascending toward `dir`. 26 degree slopes have denom 2, 7
    /// degree slopes denom 8 and 45 degree slopes denom 1.
    ramp: struct { dir: Dir, low: u8, high: u8, denom: u8 },
    /// Diagonal wall; the open half faces `corner`.
    diagonal: Corner,
    /// 3- or 4-sided diagonal slope facing `corner`. A lid tile of 1023
    /// marks the 3-sided variant.
    diagonal_slope: Corner,
    partial: Partial,
    /// Code 62, reserved.
    reserved,
    /// Code 63: this block is empty and the block above is a slope.
    slope_above,
};

pub fn decodeShape(code: u6) Shape {
    return switch (code) {
        0 => .cube,
        1...8 => blk: {
            const i = code - 1;
            const lo: u8 = i & 1;
            break :blk .{ .ramp = .{ .dir = @enumFromInt(i >> 1), .low = lo, .high = lo + 1, .denom = 2 } };
        },
        9...40 => blk: {
            const i = code - 9;
            const lo: u8 = i & 7;
            break :blk .{ .ramp = .{ .dir = @enumFromInt(i >> 3), .low = lo, .high = lo + 1, .denom = 8 } };
        },
        41...44 => .{ .ramp = .{ .dir = @enumFromInt(code - 41), .low = 0, .high = 1, .denom = 1 } },
        45...48 => .{ .diagonal = @enumFromInt(code - 45) },
        49...52 => .{ .diagonal_slope = @enumFromInt(code - 49) },
        53...61 => .{ .partial = @enumFromInt(code - 53) },
        62 => .reserved,
        63 => .slope_above,
    };
}

pub const Block = struct {
    left: Face = .empty,
    right: Face = .empty,
    top: Face = .empty,
    bottom: Face = .empty,
    lid: Face = .empty,
    /// Road arrows. Low nibble green (normal traffic): bit 0 -x, bit 1 +x,
    /// bit 2 -y, bit 3 +y (checked on real maps, see grid.zig). High
    /// nibble red, same order.
    arrows: u8 = 0,
    slope_type: u8 = 0,

    pub const air: Block = .{};
    pub const byte_size = 12;

    pub fn ground(b: Block) GroundType {
        return @enumFromInt(@as(u2, @truncate(b.slope_type)));
    }
    pub fn slopeCode(b: Block) u6 {
        return @intCast(b.slope_type >> 2);
    }
    pub fn shape(b: Block) Shape {
        return decodeShape(b.slopeCode());
    }
    pub fn isAir(b: Block) bool {
        return b.left.isEmpty() and b.right.isEmpty() and b.top.isEmpty() and
            b.bottom.isEmpty() and b.lid.isEmpty() and b.slope_type == 0;
    }

    pub fn read(bytes: *const [byte_size]u8) Block {
        const w = struct {
            fn f(b: *const [byte_size]u8, i: usize) Face {
                return @bitCast(std.mem.readInt(u16, b[i * 2 ..][0..2], .little));
            }
        }.f;
        return .{
            .left = w(bytes, 0),
            .right = w(bytes, 1),
            .top = w(bytes, 2),
            .bottom = w(bytes, 3),
            .lid = w(bytes, 4),
            .arrows = bytes[10],
            .slope_type = bytes[11],
        };
    }

    pub fn write(b: Block, out: *[byte_size]u8) void {
        const faces = [_]Face{ b.left, b.right, b.top, b.bottom, b.lid };
        for (faces, 0..) |f, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], @bitCast(f), .little);
        out[10] = b.arrows;
        out[11] = b.slope_type;
    }
};

pub const Zone = struct {
    zone_type: u8,
    x: u8,
    y: u8,
    w: u8,
    h: u8,
    name: []const u8,
};

/// Fixed point 1.8.7 as used by MOBJ and LGHT: signed, 128 units per block.
pub const Fix16 = i16;

pub const MapObject = struct { x: Fix16, y: Fix16, rotation: u8, object_type: u8 };

pub const Light = struct {
    argb: u32,
    x: Fix16,
    y: Fix16,
    z: Fix16,
    radius: Fix16,
    intensity: u8,
    shape: u8,
    on_time: u8,
    off_time: u8,
};

pub const TileAnim = struct {
    base: u16,
    frame_rate: u8,
    repeat: u8,
    tiles: []const u16,
};

pub const Compression = enum { umap, cmap, dmap };

pub const Diagnostics = struct {
    /// Columns whose height was above 8 and was clamped.
    clamped_columns: u32 = 0,
    /// Unknown chunk tags seen (not an error; the doc says to skip them).
    unknown_chunks: u32 = 0,
    /// Count of each 6-bit slope code over every solid cell.
    slope_histogram: [64]u32 = @splat(0),
};

pub const Map = struct {
    arena: std.heap.ArenaAllocator,
    version: u16,
    compression: Compression,
    /// Distinct block definitions. For DMAP/CMAP block 0 is air.
    blocks: []Block,
    /// `cell_count` indices into `blocks`, laid out [z][y][x].
    cells: []u32,
    zones: []Zone = &.{},
    objects: []MapObject = &.{},
    lights: []Light = &.{},
    anims: []TileAnim = &.{},
    diag: Diagnostics = .{},

    pub fn deinit(m: *Map) void {
        m.arena.deinit();
    }

    pub fn cellIndex(x: usize, y: usize, z: usize) usize {
        return (z * size_y + y) * size_x + x;
    }

    pub fn get(m: *const Map, x: usize, y: usize, z: usize) Block {
        return m.blocks[m.cells[cellIndex(x, y, z)]];
    }

    /// Same as `get` but returns air outside the grid, for neighbour lookups.
    pub fn getOrAir(m: *const Map, x: isize, y: isize, z: isize) Block {
        if (x < 0 or y < 0 or z < 0 or x >= size_x or y >= size_y or z >= size_z) return .air;
        return m.get(@intCast(x), @intCast(y), @intCast(z));
    }
};

/// Parses a whole .gmp file. The result owns all its memory (call `deinit`);
/// `bytes` may be freed afterwards.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Map {
    const header = try chunk.readHeader(bytes, magic);
    var map: Map = .{
        .arena = .init(gpa),
        .version = header.version,
        .compression = .dmap,
        .blocks = &.{},
        .cells = &.{},
    };
    errdefer map.arena.deinit();
    const a = map.arena.allocator();

    var map_chunk: ?chunk.Chunk = null;
    var it = chunk.iterate(bytes);
    while (try it.next()) |c| {
        if (c.is("DMAP")) {
            map_chunk = c;
            map.compression = .dmap;
        } else if (c.is("CMAP")) {
            // Prefer DMAP if a file somehow has both.
            if (map_chunk == null or !map_chunk.?.is("DMAP")) {
                map_chunk = c;
                map.compression = .cmap;
            }
        } else if (c.is("UMAP")) {
            if (map_chunk == null) {
                map_chunk = c;
                map.compression = .umap;
            }
        } else if (c.is("ZONE")) {
            map.zones = try parseZones(a, c.data);
        } else if (c.is("MOBJ")) {
            map.objects = try parseObjects(a, c.data);
        } else if (c.is("LGHT")) {
            map.lights = try parseLights(a, c.data);
        } else if (c.is("ANIM")) {
            map.anims = try parseAnims(a, c.data);
        } else if (c.is("PSXM") or c.is("RGEN") or c.is("EDIT") or c.is("THSR")) {
            // Known, not needed by the client.
        } else {
            map.diag.unknown_chunks += 1;
        }
    }

    const mc = map_chunk orelse return error.NoMapChunk;
    map.cells = try a.alloc(u32, cell_count);
    switch (map.compression) {
        .umap => try parseUmap(a, &map, mc.data),
        .cmap => try parseCompressed(u16, a, &map, mc.data),
        .dmap => try parseCompressed(u32, a, &map, mc.data),
    }

    for (map.cells) |ci| {
        const b = map.blocks[ci];
        if (!b.isAir()) map.diag.slope_histogram[b.slopeCode()] += 1;
    }
    return map;
}

fn parseUmap(a: std.mem.Allocator, map: *Map, data: []const u8) Error!void {
    if (data.len < cell_count * Block.byte_size) return error.Truncated;
    map.blocks = try a.alloc(Block, cell_count);
    for (map.blocks, 0..) |*b, i| {
        b.* = Block.read(data[i * Block.byte_size ..][0..Block.byte_size]);
        map.cells[i] = @intCast(i);
    }
}

/// CMAP (16-bit) and DMAP (32-bit) share a layout and differ only in word
/// size:
///   W base[256][256]; W column_words; W column[column_words];
///   W num_blocks; block_info block[num_blocks];
/// A column starts with a header word (CMAP: u8 height, u8 offset; DMAP:
/// u8 height, u8 offset, u16 pad) followed by `height - offset` block
/// indices for z = offset .. height-1. Cells outside that range are air.
fn parseCompressed(comptime W: type, a: std.mem.Allocator, map: *Map, data: []const u8) Error!void {
    var r: chunk.Reader = .{ .bytes = data };
    const base_bytes = try r.slice(size_x * size_y * @sizeOf(W));
    const column_words = try r.int(W);
    const column_bytes = try r.slice(@as(usize, column_words) * @sizeOf(W));
    const num_blocks = try r.int(W);
    const block_bytes = try r.slice(@as(usize, num_blocks) * Block.byte_size);

    if (num_blocks == 0) return error.BadBlockIndex;
    map.blocks = try a.alloc(Block, num_blocks);
    for (map.blocks, 0..) |*b, i| b.* = Block.read(block_bytes[i * Block.byte_size ..][0..Block.byte_size]);

    const word = struct {
        fn at(bytes: []const u8, i: usize) W {
            return std.mem.readInt(W, bytes[i * @sizeOf(W) ..][0..@sizeOf(W)], .little);
        }
    }.at;

    @memset(map.cells, 0);
    for (0..size_y) |y| for (0..size_x) |x| {
        const start: usize = word(base_bytes, y * size_x + x);
        // The header is one word either way (DMAP: u8 height, u8 offset,
        // u16 pad; CMAP: u8 height, u8 offset), so the first two bytes are
        // height and offset.
        const header_words: usize = 1;
        if (start + header_words > column_words) return error.BadColumn;
        const hdr_byte_off = start * @sizeOf(W);
        var height: usize = column_bytes[hdr_byte_off];
        const offset: usize = column_bytes[hdr_byte_off + 1];
        if (height > size_z) {
            height = size_z;
            map.diag.clamped_columns += 1;
        }
        if (offset > height) return error.BadColumn;
        const count = height - offset;
        if (start + header_words + count > column_words) return error.BadColumn;
        for (0..count) |i| {
            const bi = word(column_bytes, start + header_words + i);
            if (bi >= num_blocks) return error.BadBlockIndex;
            map.cells[Map.cellIndex(x, y, offset + i)] = @intCast(bi);
        }
    };
}

fn parseZones(a: std.mem.Allocator, data: []const u8) Error![]Zone {
    var list: std.ArrayList(Zone) = .empty;
    var r: chunk.Reader = .{ .bytes = data };
    while (r.remaining() > 0) {
        const hdr = try r.slice(6);
        const name = try r.slice(hdr[5]);
        try list.append(a, .{
            .zone_type = hdr[0],
            .x = hdr[1],
            .y = hdr[2],
            .w = hdr[3],
            .h = hdr[4],
            .name = try a.dupe(u8, name),
        });
    }
    return list.toOwnedSlice(a);
}

fn parseObjects(a: std.mem.Allocator, data: []const u8) Error![]MapObject {
    const n = data.len / 6;
    const out = try a.alloc(MapObject, n);
    var r: chunk.Reader = .{ .bytes = data };
    for (out) |*o| o.* = .{
        .x = try r.int(i16),
        .y = try r.int(i16),
        .rotation = try r.int(u8),
        .object_type = try r.int(u8),
    };
    return out;
}

fn parseLights(a: std.mem.Allocator, data: []const u8) Error![]Light {
    const n = data.len / 16;
    const out = try a.alloc(Light, n);
    var r: chunk.Reader = .{ .bytes = data };
    for (out) |*l| l.* = .{
        .argb = try r.int(u32),
        .x = try r.int(i16),
        .y = try r.int(i16),
        .z = try r.int(i16),
        .radius = try r.int(i16),
        .intensity = try r.int(u8),
        .shape = try r.int(u8),
        .on_time = try r.int(u8),
        .off_time = try r.int(u8),
    };
    return out;
}

fn parseAnims(a: std.mem.Allocator, data: []const u8) Error![]TileAnim {
    var list: std.ArrayList(TileAnim) = .empty;
    var r: chunk.Reader = .{ .bytes = data };
    while (r.remaining() >= 6) {
        const base = try r.int(u16);
        const frame_rate = try r.int(u8);
        const repeat = try r.int(u8);
        const len = try r.int(u8);
        _ = try r.int(u8);
        const tiles = try a.alloc(u16, len);
        for (tiles) |*t| t.* = try r.int(u16);
        try list.append(a, .{ .base = base, .frame_rate = frame_rate, .repeat = repeat, .tiles = tiles });
    }
    return list.toOwnedSlice(a);
}

const testing = std.testing;

test "face bits" {
    const f: Face = @bitCast(@as(u16, 0b10_1_1_1_1_0000000101));
    try testing.expectEqual(@as(u10, 5), f.tile);
    try testing.expect(f.wall() and f.bulletWall() and f.flat and f.flip);
    try testing.expectEqual(@as(u2, 2), f.rotation);
    try testing.expectEqual(@as(u2, 3), f.lighting());
}

test "slope decoding" {
    try testing.expectEqual(Shape.cube, decodeShape(0));
    const s2 = decodeShape(2).ramp;
    try testing.expectEqual(Dir.up, s2.dir);
    try testing.expectEqual(@as(u8, 1), s2.low);
    try testing.expectEqual(@as(u8, 2), s2.denom);
    const s8 = decodeShape(8).ramp;
    try testing.expectEqual(Dir.right, s8.dir);
    try testing.expectEqual(@as(u8, 1), s8.low);
    const s16 = decodeShape(16).ramp;
    try testing.expectEqual(Dir.up, s16.dir);
    try testing.expectEqual(@as(u8, 7), s16.low);
    try testing.expectEqual(@as(u8, 8), s16.denom);
    try testing.expectEqual(Dir.right, decodeShape(40).ramp.dir);
    try testing.expectEqual(Dir.left, decodeShape(43).ramp.dir);
    try testing.expectEqual(Corner.down_right, decodeShape(48).diagonal);
    try testing.expectEqual(Corner.up_left, decodeShape(49).diagonal_slope);
    try testing.expectEqual(Partial.centre, decodeShape(61).partial);
    try testing.expectEqual(Shape.slope_above, decodeShape(63));
}

test "block round trip" {
    const b: Block = .{
        .left = @bitCast(@as(u16, 0x1234)),
        .lid = @bitCast(@as(u16, 0xbeef)),
        .arrows = 0x81,
        .slope_type = (41 << 2) | 1,
    };
    var buf: [12]u8 = undefined;
    b.write(&buf);
    const c = Block.read(&buf);
    try testing.expectEqual(b, c);
    try testing.expectEqual(GroundType.road, c.ground());
    try testing.expectEqual(@as(u6, 41), c.slopeCode());
}
