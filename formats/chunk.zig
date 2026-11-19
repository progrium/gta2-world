//! Chunked container shared by the GBH map (GBMP) and style (GBST) files.
//!
//! Layout (DMA "GBH Map/Style Format" docs): a 4-byte file type, a u16
//! version, then any number of chunks of `[4]u8 type, u32 size, size bytes`.
//! All multi-byte values are little-endian (the PC files are written by x86).

const std = @import("std");

pub const Error = error{ BadMagic, Truncated };

pub const Header = struct {
    magic: [4]u8,
    version: u16,
};

pub const Chunk = struct {
    tag: [4]u8,
    /// Offset of the chunk payload from the start of the file.
    offset: usize,
    data: []const u8,

    pub fn is(c: Chunk, tag: *const [4]u8) bool {
        return std.mem.eql(u8, &c.tag, tag);
    }
};

pub fn readHeader(bytes: []const u8, magic: *const [4]u8) Error!Header {
    if (bytes.len < 6) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    return .{ .magic = bytes[0..4].*, .version = std.mem.readInt(u16, bytes[4..6], .little) };
}

pub const Iterator = struct {
    bytes: []const u8,
    pos: usize = 6,

    /// Returns the next chunk, or null at end of file. A chunk whose declared
    /// size runs past the end of the file is an error rather than silently
    /// clipped, since it means the file is corrupt or not what we think it is.
    pub fn next(it: *Iterator) Error!?Chunk {
        if (it.pos >= it.bytes.len) return null;
        if (it.bytes.len - it.pos < 8) return error.Truncated;
        const tag = it.bytes[it.pos..][0..4].*;
        const size = std.mem.readInt(u32, it.bytes[it.pos + 4 ..][0..4], .little);
        const start = it.pos + 8;
        if (size > it.bytes.len - start) return error.Truncated;
        it.pos = start + size;
        return .{ .tag = tag, .offset = start, .data = it.bytes[start..][0..size] };
    }
};

pub fn iterate(bytes: []const u8) Iterator {
    return .{ .bytes = bytes };
}

/// Little-endian cursor over a byte slice with bounds checks.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn remaining(r: Reader) usize {
        return r.bytes.len - r.pos;
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const n = @sizeOf(T);
        if (r.remaining() < n) return error.Truncated;
        const v = std.mem.readInt(T, r.bytes[r.pos..][0..n], .little);
        r.pos += n;
        return v;
    }

    pub fn slice(r: *Reader, n: usize) Error![]const u8 {
        if (r.remaining() < n) return error.Truncated;
        const s = r.bytes[r.pos..][0..n];
        r.pos += n;
        return s;
    }
};

test "chunk iteration" {
    const bytes = "GBMP\xf4\x01" ++ "ABCD\x02\x00\x00\x00hi" ++ "EFGH\x00\x00\x00\x00";
    const h = try readHeader(bytes, "GBMP");
    try std.testing.expectEqual(@as(u16, 500), h.version);
    var it = iterate(bytes);
    const a = (try it.next()).?;
    try std.testing.expect(a.is("ABCD"));
    try std.testing.expectEqualStrings("hi", a.data);
    const b = (try it.next()).?;
    try std.testing.expect(b.is("EFGH"));
    try std.testing.expectEqual(@as(?Chunk, null), try it.next());
}

test "truncated chunk is an error" {
    const bytes = "GBMP\xf4\x01" ++ "ABCD\x09\x00\x00\x00hi";
    var it = iterate(bytes);
    try std.testing.expectError(error.Truncated, it.next());
}
