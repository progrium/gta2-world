const std = @import("std");
const c = @import("c");

/// Monotonic clock in nanoseconds. ngtcp2 timestamps use this clock.
pub fn now() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

/// Wall clock, seconds since the epoch (for log lines only).
pub fn wallSeconds() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @intCast(ts.tv_sec);
}

pub fn randomBytes(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.getrandom(buf[off..].ptr, buf.len - off, 0);
        if (n > 0) off += @intCast(n);
    }
}

pub const Varint = struct { value: u64, len: usize };

/// QUIC variable-length integer (RFC 9000 section 16).
pub fn readVarint(buf: []const u8) ?Varint {
    if (buf.len == 0) return null;
    const len: usize = @as(usize, 1) << @intCast(buf[0] >> 6);
    if (buf.len < len) return null;
    var v: u64 = buf[0] & 0x3f;
    for (buf[1..len]) |b| v = (v << 8) | b;
    return .{ .value = v, .len = len };
}

pub fn putVarint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u64) !void {
    if (v < 64) {
        try out.append(gpa, @intCast(v));
    } else if (v < 16384) {
        try out.appendSlice(gpa, &.{ @intCast(0x40 | (v >> 8)), @intCast(v & 0xff) });
    } else if (v < 1 << 30) {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @intCast(v | (0b10 << 30)), .big);
        try out.appendSlice(gpa, &b);
    } else {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v | (@as(u64, 0b11) << 62), .big);
        try out.appendSlice(gpa, &b);
    }
}

/// QPACK/HPACK prefixed integer (RFC 7541 section 5.1). `first` holds the
/// high bits that precede the N-bit prefix.
pub fn putPrefixInt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), first: u8, comptime n: u4, v: u64) !void {
    const max: u64 = (@as(u64, 1) << n) - 1;
    if (v < max) return out.append(gpa, first | @as(u8, @intCast(v)));
    try out.append(gpa, first | @as(u8, @intCast(max)));
    var rest = v - max;
    while (rest >= 128) : (rest >>= 7) try out.append(gpa, @as(u8, @intCast(rest & 0x7f)) | 0x80);
    try out.append(gpa, @intCast(rest));
}

test "varint roundtrip" {
    const gpa = std.testing.allocator;
    for ([_]u64{ 0, 63, 64, 0x41, 0x54, 16383, 16384, 1 << 29, 0x2b603742, 1 << 40 }) |v| {
        var l: std.ArrayList(u8) = .empty;
        defer l.deinit(gpa);
        try putVarint(gpa, &l, v);
        const r = readVarint(l.items).?;
        try std.testing.expectEqual(v, r.value);
        try std.testing.expectEqual(l.items.len, r.len);
    }
}

/// Bind a nonblocking socket on all interfaces: dual-stack IPv6 when the
/// host has it, plain IPv4 otherwise.
pub fn bindAny(sock_type: c_int, port: u16) !c_int {
    var fd = c.socket(c.AF_INET6, sock_type | c.SOCK_NONBLOCK, 0);
    var one: c_int = 1;
    if (fd >= 0) {
        var zero: c_int = 0;
        _ = c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_V6ONLY, &zero, @sizeOf(c_int));
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa: c.struct_sockaddr_in6 = std.mem.zeroes(c.struct_sockaddr_in6);
        sa.sin6_family = c.AF_INET6;
        sa.sin6_port = c.htons(port);
        if (c.bind(fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in6)) == 0) return fd;
        _ = c.close(fd);
    }
    fd = c.socket(c.AF_INET, sock_type | c.SOCK_NONBLOCK, 0);
    if (fd < 0) return error.Socket;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
    var sa4: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    sa4.sin_family = c.AF_INET;
    sa4.sin_port = c.htons(port);
    if (c.bind(fd, @ptrCast(&sa4), @sizeOf(c.struct_sockaddr_in)) != 0) return error.Bind;
    return fd;
}
