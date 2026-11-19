//! HTTP/1.1 + WebSocket echo over TCP, optionally TLS (GnuTLS).
//! Serves the test page, a small JSON config, a POST /report sink for
//! browser soak results, and the WebSocket echo at /ws.
const std = @import("std");
const c = @import("c");
const util = @import("util.zig");
const log = std.log.scoped(.tcp);
const Allocator = std.mem.Allocator;

const index_html = @embedFile("index.html");
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const max_ws_payload = 1 << 20;

pub const Stats = struct {
    ws_total: u64 = 0,
    ws_msgs: u64 = 0,
    ws_bytes: u64 = 0,
    reports: u64 = 0,
};

pub const Server = struct {
    gpa: Allocator,
    fd: c_int,
    cred: c.gnutls_certificate_credentials_t = null,
    clients: std.ArrayList(*Client) = .empty,
    config_json: []u8,
    stats: Stats = .{},
    report_fd: c_int = -1,

    pub fn init(gpa: Allocator, port: u16, tls_files: ?[2][:0]const u8, config_json: []u8, report_path: ?[:0]const u8) !*Server {
        const self = try gpa.create(Server);
        self.* = .{ .gpa = gpa, .fd = -1, .config_json = config_json };
        if (tls_files) |f| {
            if (c.gnutls_certificate_allocate_credentials(&self.cred) != 0) return error.Tls;
            const rv = c.gnutls_certificate_set_x509_key_file(self.cred, f[0].ptr, f[1].ptr, c.GNUTLS_X509_FMT_PEM);
            if (rv != 0) return error.Tls;
        }
        if (report_path) |p| {
            self.report_fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o644));
        }
        self.fd = try util.bindAny(c.SOCK_STREAM, port);
        if (c.listen(self.fd, 128) != 0) return error.Listen;
        return self;
    }

    pub fn onAccept(self: *Server) void {
        while (true) {
            const fd = c.accept4(self.fd, null, null, c.SOCK_NONBLOCK);
            if (fd < 0) return;
            var one: c_int = 1;
            _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &one, @sizeOf(c_int));
            const cl = self.gpa.create(Client) catch {
                _ = c.close(fd);
                return;
            };
            cl.* = .{ .server = self, .fd = fd };
            if (self.cred != null) {
                if (c.gnutls_init(&cl.tls, c.GNUTLS_SERVER | c.GNUTLS_NONBLOCK) != 0 or
                    c.gnutls_set_default_priority(cl.tls) != 0 or
                    c.gnutls_credentials_set(cl.tls, c.GNUTLS_CRD_CERTIFICATE, self.cred) != 0)
                {
                    cl.dead = true;
                } else {
                    c.gnutls_transport_set_int2(cl.tls, fd, fd);
                    cl.handshaking = true;
                }
            }
            self.clients.append(self.gpa, cl) catch {
                cl.destroy();
                return;
            };
        }
    }

    /// pollfd events wanted for a client.
    pub fn events(cl: *Client) c_short {
        var ev: c_short = c.POLLIN;
        if (cl.out.items.len > 0 or cl.tls_send_pending > 0) ev |= c.POLLOUT;
        if (cl.tls != null and cl.handshaking and c.gnutls_record_get_direction(cl.tls) == 1) ev |= c.POLLOUT;
        return ev;
    }

    pub fn sweep(self: *Server) void {
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const cl = self.clients.items[i];
            if (cl.dead) {
                _ = self.clients.swapRemove(i);
                cl.destroy();
            } else i += 1;
        }
    }

    pub fn wsClients(self: *Server) usize {
        var n: usize = 0;
        for (self.clients.items) |cl| {
            if (cl.mode == .ws) n += 1;
        }
        return n;
    }

    fn writeReport(self: *Server, body: []const u8) void {
        self.stats.reports += 1;
        log.info("report: {s}", .{body});
        if (self.report_fd < 0) return;
        var hdr: [32]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "{d} ", .{util.wallSeconds()}) catch return;
        _ = c.write(self.report_fd, h.ptr, h.len);
        _ = c.write(self.report_fd, body.ptr, body.len);
        _ = c.write(self.report_fd, "\n", 1);
    }
};

pub const Client = struct {
    server: *Server,
    fd: c_int,
    tls: c.gnutls_session_t = null,
    handshaking: bool = false,
    tls_send_pending: usize = 0,
    in: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    mode: enum { http, ws } = .http,
    close_after_flush: bool = false,
    dead: bool = false,

    fn destroy(cl: *Client) void {
        const gpa = cl.server.gpa;
        if (cl.tls != null) c.gnutls_deinit(cl.tls);
        _ = c.close(cl.fd);
        cl.in.deinit(gpa);
        cl.out.deinit(gpa);
        gpa.destroy(cl);
    }

    pub fn onEvents(cl: *Client, revents: c_short) void {
        if (cl.dead) return;
        if (cl.handshaking) {
            const rv = c.gnutls_handshake(cl.tls);
            if (rv == c.GNUTLS_E_AGAIN or rv == c.GNUTLS_E_INTERRUPTED) return;
            if (rv < 0) {
                log.info("tls handshake failed: {s}", .{c.gnutls_strerror(rv)});
                cl.dead = true;
                return;
            }
            cl.handshaking = false;
        }
        if (revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) cl.readAll();
        if (!cl.dead) cl.flush();
    }

    fn readAll(cl: *Client) void {
        const gpa = cl.server.gpa;
        var buf: [16384]u8 = undefined;
        while (true) {
            const n: isize = if (cl.tls != null) blk: {
                const r = c.gnutls_record_recv(cl.tls, &buf, buf.len);
                if (r == c.GNUTLS_E_AGAIN or r == c.GNUTLS_E_INTERRUPTED) break;
                break :blk if (r < 0) -1 else r;
            } else blk: {
                const r = c.read(cl.fd, &buf, buf.len);
                if (r < 0 and (std.c._errno().* == c.EAGAIN or std.c._errno().* == c.EINTR)) break;
                break :blk r;
            };
            if (n <= 0) {
                cl.dead = true;
                return;
            }
            cl.in.appendSlice(gpa, buf[0..@intCast(n)]) catch {
                cl.dead = true;
                return;
            };
            if (cl.in.items.len > 4 * max_ws_payload) {
                cl.dead = true;
                return;
            }
        }
        cl.process() catch {
            cl.dead = true;
        };
    }

    fn flush(cl: *Client) void {
        while (cl.out.items.len > 0) {
            var n: isize = 0;
            if (cl.tls != null) {
                const r = if (cl.tls_send_pending > 0)
                    c.gnutls_record_send(cl.tls, null, 0)
                else
                    c.gnutls_record_send(cl.tls, cl.out.items.ptr, @min(cl.out.items.len, 16384));
                if (r == c.GNUTLS_E_AGAIN or r == c.GNUTLS_E_INTERRUPTED) {
                    if (cl.tls_send_pending == 0) cl.tls_send_pending = @min(cl.out.items.len, 16384);
                    return;
                }
                cl.tls_send_pending = 0;
                n = if (r < 0) -1 else r;
            } else {
                n = c.send(cl.fd, cl.out.items.ptr, cl.out.items.len, c.MSG_NOSIGNAL);
                if (n < 0 and std.c._errno().* == c.EAGAIN) return;
            }
            if (n <= 0) {
                cl.dead = true;
                return;
            }
            const k: usize = @intCast(n);
            std.mem.copyForwards(u8, cl.out.items, cl.out.items[k..]);
            cl.out.shrinkRetainingCapacity(cl.out.items.len - k);
        }
        if (cl.close_after_flush) cl.dead = true;
    }

    fn consume(cl: *Client, n: usize) void {
        std.mem.copyForwards(u8, cl.in.items, cl.in.items[n..]);
        cl.in.shrinkRetainingCapacity(cl.in.items.len - n);
    }

    fn process(cl: *Client) !void {
        while (!cl.dead and !cl.close_after_flush) {
            const progressed = switch (cl.mode) {
                .http => try cl.processHttp(),
                .ws => try cl.processWs(),
            };
            if (!progressed) return;
        }
    }

    fn processHttp(cl: *Client) !bool {
        const gpa = cl.server.gpa;
        const end = std.mem.indexOf(u8, cl.in.items, "\r\n\r\n") orelse {
            if (cl.in.items.len > 16384) cl.dead = true;
            return false;
        };
        const head = cl.in.items[0..end];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const reqline = lines.next() orelse return error.BadRequest;
        var parts = std.mem.tokenizeScalar(u8, reqline, ' ');
        const method = parts.next() orelse return error.BadRequest;
        const target = parts.next() orelse return error.BadRequest;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

        var ws_key: ?[]const u8 = null;
        var upgrade_ws = false;
        var content_length: usize = 0;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const k = std.mem.trim(u8, line[0..colon], " ");
            const v = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(k, "sec-websocket-key")) ws_key = v;
            if (std.ascii.eqlIgnoreCase(k, "upgrade") and std.ascii.eqlIgnoreCase(v, "websocket")) upgrade_ws = true;
            if (std.ascii.eqlIgnoreCase(k, "content-length")) content_length = std.fmt.parseInt(usize, v, 10) catch 0;
        }
        if (content_length > 65536) return error.BadRequest;
        const total = end + 4 + content_length;
        if (cl.in.items.len < total) return false;
        const body = cl.in.items[end + 4 .. total];

        if (std.mem.eql(u8, path, "/ws") and upgrade_ws and ws_key != null) {
            var sha = std.crypto.hash.Sha1.init(.{});
            sha.update(ws_key.?);
            sha.update(ws_guid);
            var digest: [20]u8 = undefined;
            sha.final(&digest);
            var accept: [28]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&accept, &digest);
            try cl.out.print(gpa, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
            cl.consume(total);
            cl.mode = .ws;
            cl.server.stats.ws_total += 1;
            log.info("websocket client connected", .{});
            return true;
        }

        if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))) {
            try cl.respond(200, "text/html; charset=utf-8", index_html);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/config")) {
            try cl.respond(200, "application/json", cl.server.config_json);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/report")) {
            cl.server.writeReport(body);
            try cl.respond(204, "text/plain", "");
        } else {
            try cl.respond(404, "text/plain", "not found\n");
        }
        cl.consume(total);
        return true;
    }

    fn respond(cl: *Client, status: u16, ctype: []const u8, body: []const u8) !void {
        const gpa = cl.server.gpa;
        const reason = switch (status) {
            200 => "OK",
            204 => "No Content",
            else => "Not Found",
        };
        try cl.out.print(gpa, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n", .{ status, reason, ctype, body.len });
        try cl.out.appendSlice(gpa, body);
    }

    fn processWs(cl: *Client) !bool {
        const gpa = cl.server.gpa;
        const b = cl.in.items;
        if (b.len < 2) return false;
        const fin_op = b[0];
        const opcode = fin_op & 0x0f;
        const masked = b[1] & 0x80 != 0;
        var len: u64 = b[1] & 0x7f;
        var off: usize = 2;
        if (len == 126) {
            if (b.len < 4) return false;
            len = std.mem.readInt(u16, b[2..4], .big);
            off = 4;
        } else if (len == 127) {
            if (b.len < 10) return false;
            len = std.mem.readInt(u64, b[2..10], .big);
            off = 10;
        }
        if (len > max_ws_payload or !masked) return error.BadFrame;
        if (b.len < off + 4 + len) return false;
        const mask = b[off..][0..4].*;
        off += 4;
        const payload = b[off..][0..@intCast(len)];
        for (payload, 0..) |*p, i| p.* ^= mask[i % 4];

        switch (opcode) {
            0x8 => { // close: echo it and hang up
                try cl.frame(0x88, payload);
                cl.close_after_flush = true;
            },
            0x9 => try cl.frame(0x8A, payload), // ping -> pong
            0xA => {},
            else => {
                cl.server.stats.ws_msgs += 1;
                cl.server.stats.ws_bytes += payload.len;
                try cl.frame(fin_op, payload); // echo text/binary/continuation as-is
            },
        }
        cl.consume(off + payload.len);
        _ = gpa;
        return true;
    }

    fn frame(cl: *Client, first: u8, payload: []const u8) !void {
        const gpa = cl.server.gpa;
        try cl.out.append(gpa, first);
        if (payload.len < 126) {
            try cl.out.append(gpa, @intCast(payload.len));
        } else if (payload.len < 65536) {
            try cl.out.append(gpa, 126);
            var l: [2]u8 = undefined;
            std.mem.writeInt(u16, &l, @intCast(payload.len), .big);
            try cl.out.appendSlice(gpa, &l);
        } else {
            try cl.out.append(gpa, 127);
            var l: [8]u8 = undefined;
            std.mem.writeInt(u64, &l, payload.len, .big);
            try cl.out.appendSlice(gpa, &l);
        }
        try cl.out.appendSlice(gpa, payload);
    }
};
