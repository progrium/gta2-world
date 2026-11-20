//! `.gxt` text tables: the game's on-screen text (messages, briefs, names),
//! from the public GTA2 GXT format description, checked against the
//! player's own `e.gxt`. Used only by the client (script-messages.md 2.1:
//! a script names text by number, and the number's decimal digits are the
//! key, so message 500 is the key "500").
//!
//! Layout, little endian:
//!
//!   "GBL" and a language letter ('E', 'F', 'G', 'I', 'S', ...), u16 version
//!   then chunks of (4-byte type, u32 size, data):
//!     TKEY  12-byte entries: u32 byte offset into TDAT, 8-byte key (zero padded)
//!     TDAT  16-bit characters, each string ending in a 0
//!
//! The parser borrows the file's bytes; the strings it returns point into
//! them and are 16-bit little-endian code units without the terminator.

const std = @import("std");

pub const Error = error{ BadHeader, Truncated, MissingChunk, BadEntry };

pub const key_len = 8;
const entry_len = 4 + key_len;

pub const Table = struct {
    /// The language letter from the header ('E' for English).
    language: u8,
    version: u16,
    /// TKEY's entries.
    keys: []const u8,
    /// TDAT.
    data: []const u8,
    /// Keys in ascending byte order (binary search); otherwise linear.
    sorted: bool,

    pub fn count(t: *const Table) usize {
        return t.keys.len / entry_len;
    }

    /// Key of entry `i`, without its padding.
    pub fn keyAt(t: *const Table, i: usize) []const u8 {
        const k = t.keys[i * entry_len + 4 ..][0..key_len];
        return k[0 .. std.mem.indexOfScalar(u8, k, 0) orelse key_len];
    }

    fn textAt(t: *const Table, i: usize) []const u8 {
        const off = std.mem.readInt(u32, t.keys[i * entry_len ..][0..4], .little);
        if (off >= t.data.len) return &.{};
        const rest = t.data[off..];
        var n: usize = 0;
        while (n + 1 < rest.len and (rest[n] != 0 or rest[n + 1] != 0)) n += 2;
        return rest[0..n];
    }

    /// The text for `key` (case sensitive, as stored), or null.
    pub fn get(t: *const Table, key: []const u8) ?[]const u8 {
        if (t.sorted) {
            var lo: usize = 0;
            var hi: usize = t.count();
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                switch (std.mem.order(u8, t.keyAt(mid), key)) {
                    .eq => return t.textAt(mid),
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                }
            }
            return null;
        }
        for (0..t.count()) |i| if (std.mem.eql(u8, t.keyAt(i), key)) return t.textAt(i);
        return null;
    }

    /// The text a script's message number names (its decimal digits).
    pub fn getId(t: *const Table, id: u32) ?[]const u8 {
        var buf: [10]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable;
        return t.get(key);
    }
};

pub fn parse(bytes: []const u8) Error!Table {
    if (bytes.len < 6 or !std.mem.eql(u8, bytes[0..3], "GBL")) return error.BadHeader;
    var t: Table = .{ .language = bytes[3], .version = std.mem.readInt(u16, bytes[4..6], .little), .keys = &.{}, .data = &.{}, .sorted = true };
    var have_keys = false;
    var have_data = false;
    var o: usize = 6;
    while (o + 8 <= bytes.len) {
        const tag = bytes[o..][0..4];
        const size = std.mem.readInt(u32, bytes[o + 4 ..][0..4], .little);
        if (size > bytes.len - o - 8) return error.Truncated;
        const body = bytes[o + 8 ..][0..size];
        if (std.mem.eql(u8, tag, "TKEY")) {
            if (size % entry_len != 0) return error.BadEntry;
            t.keys = body;
            have_keys = true;
        } else if (std.mem.eql(u8, tag, "TDAT")) {
            t.data = body;
            have_data = true;
        }
        o += 8 + size;
    }
    if (!have_keys or !have_data) return error.MissingChunk;
    var i: usize = 1;
    while (i < t.count()) : (i += 1) {
        if (std.mem.order(u8, t.keyAt(i - 1), t.keyAt(i)) != .lt) {
            t.sorted = false;
            break;
        }
    }
    return t;
}

// ------------------------------------------------------------------ tests

/// Builds a small `.gxt` in memory, for tests (no game data).
pub fn build(gpa: std.mem.Allocator, language: u8, entries: []const [2][]const u8) ![]u8 {
    var data_len: usize = 0;
    for (entries) |e| data_len += (e[1].len + 1) * 2;
    const keys_len = entries.len * entry_len;
    const out = try gpa.alloc(u8, 6 + 8 + keys_len + 8 + data_len);
    @memcpy(out[0..3], "GBL");
    out[3] = language;
    std.mem.writeInt(u16, out[4..6], 100, .little);
    @memcpy(out[6..10], "TKEY");
    std.mem.writeInt(u32, out[10..14], @intCast(keys_len), .little);
    const data_at = 14 + keys_len + 8;
    @memcpy(out[14 + keys_len ..][0..4], "TDAT");
    std.mem.writeInt(u32, out[14 + keys_len + 4 ..][0..4], @intCast(data_len), .little);
    var off: usize = 0;
    for (entries, 0..) |e, i| {
        const k = out[14 + i * entry_len ..][0..entry_len];
        std.mem.writeInt(u32, k[0..4], @intCast(off), .little);
        @memset(k[4..], 0);
        @memcpy(k[4..][0..e[0].len], e[0]);
        for (e[1]) |ch| {
            std.mem.writeInt(u16, out[data_at + off ..][0..2], ch, .little);
            off += 2;
        }
        std.mem.writeInt(u16, out[data_at + off ..][0..2], 0, .little);
        off += 2;
    }
    return out;
}

fn ascii(buf: []u8, units: []const u8) []const u8 {
    for (0..units.len / 2) |i| buf[i] = units[i * 2];
    return buf[0 .. units.len / 2];
}

test "keys look up their text, numbers by their digits" {
    const gpa = std.testing.allocator;
    const bytes = try build(gpa, 'E', &.{ .{ "1001", "Hello #there#" }, .{ "500", "Five hundred" }, .{ "mis_fail", "MISSION FAILED!" } });
    defer gpa.free(bytes);
    const t = try parse(bytes);
    try std.testing.expectEqual(@as(u8, 'E'), t.language);
    try std.testing.expectEqual(@as(usize, 3), t.count());
    try std.testing.expect(t.sorted);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Five hundred", ascii(&buf, t.getId(500).?));
    try std.testing.expectEqualStrings("Hello #there#", ascii(&buf, t.get("1001").?));
    try std.testing.expectEqualStrings("MISSION FAILED!", ascii(&buf, t.get("mis_fail").?));
    try std.testing.expect(t.getId(501) == null);
    try std.testing.expect(t.get("MIS_FAIL") == null);
}

test "unsorted keys still found; bad files refused" {
    const gpa = std.testing.allocator;
    const bytes = try build(gpa, 'F', &.{ .{ "b", "two" }, .{ "a", "one" } });
    defer gpa.free(bytes);
    const t = try parse(bytes);
    try std.testing.expect(!t.sorted);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("one", ascii(&buf, t.get("a").?));
    try std.testing.expectError(error.BadHeader, parse("GBMP\x00\x00"));
    try std.testing.expectError(error.Truncated, parse(bytes[0 .. bytes.len - 1]));
    try std.testing.expectError(error.MissingChunk, parse(bytes[0..6]));
}
