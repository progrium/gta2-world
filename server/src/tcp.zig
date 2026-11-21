//! HTTP/1.1 + WebSocket over TCP, optionally TLS (GnuTLS). Carried
//! forward from spike S4.
//!
//! - `/s/<session>/ws` is the I3 WebSocket fallback: each binary message is
//!   one channel byte (0 datagram, 1 stream) and one I3 message.
//! - `/.well-known/acme-challenge/*` is served from `--acme-webroot`, so
//!   certbot can renew without stopping the server.
//! - Everything else goes to the `Api` (metrics, sessions, maps, config).
//!
//! A second instance in `redirect` mode listens on port 80: ACME challenges
//! plus a redirect to https.
const std = @import("std");
const c = @import("c");
const util = @import("util.zig");
const net = @import("net.zig");
const log = std.log.scoped(.tcp);
const Allocator = std.mem.Allocator;

const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const max_ws_payload = 1 << 20;
/// A WebSocket client whose unsent output exceeds this gets no datagrams
/// until it drains (they are unreliable anyway).
const ws_dgram_backlog = 256 * 1024;
/// ... and is dropped if it exceeds this.
const ws_max_backlog = 8 * 1024 * 1024;

pub const Stats = struct {
    ws_total: u64 = 0,
    ws_msgs: u64 = 0,
    ws_bytes: u64 = 0,
    ws_dgrams_dropped: u64 = 0,
    http_requests: u64 = 0,
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    host: []const u8,
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    body: std.ArrayList(u8) = .empty,
};

/// HTTP routes other than WebSocket and ACME. Implemented in main.zig.
pub const Api = struct {
    ptr: *anyopaque,
    handle: *const fn (*anyopaque, Request, *Response) anyerror!void,
};

pub const Mode = enum { main, redirect };

pub const Server = struct {
    gpa: Allocator,
    fd: c_int,
    cred: c.gnutls_certificate_credentials_t = null,
    clients: std.ArrayList(*Client) = .empty,
    stats: Stats = .{},
    hub: net.Hub,
    api: ?Api,
    mode: Mode,
    acme_webroot: ?[]const u8,

    pub fn init(gpa: Allocator, hub: net.Hub, api: ?Api, mode: Mode, port: u16, tls_files: ?[2][:0]const u8, acme_webroot: ?[]const u8) !*Server {
        const self = try gpa.create(Server);
        self.* = .{ .gpa = gpa, .fd = -1, .hub = hub, .api = api, .mode = mode, .acme_webroot = acme_webroot };
        if (tls_files) |f| try self.reloadCert(f[0], f[1]);
        self.fd = try util.bindAny(c.SOCK_STREAM, port);
        if (c.listen(self.fd, 128) != 0) return error.Listen;
        return self;
    }

    /// New connections use the new cert; old credentials are never freed
    /// because live TLS sessions may still point at them.
    pub fn reloadCert(self: *Server, cert: [:0]const u8, key: [:0]const u8) !void {
        var cred: c.gnutls_certificate_credentials_t = null;
        if (c.gnutls_certificate_allocate_credentials(&cred) != 0) return error.Tls;
        const rv = c.gnutls_certificate_set_x509_key_file(cred, cert.ptr, key.ptr, c.GNUTLS_X509_FMT_PEM);
        if (rv != 0) {
            log.err("loading {s}/{s}: {s}", .{ cert, key, c.gnutls_strerror(rv) });
            return error.Tls;
        }
        self.cred = cred;
    }

    /// Write what sessions queued since the last poll.
    pub fn flushAll(self: *Server) void {
        for (self.clients.items) |cl| if (!cl.dead and !cl.handshaking and cl.out.items.len > 0) cl.flush();
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
    peer: net.PeerId = 0,

    const link_vt: net.Link.VTable = .{ .sendDatagram = linkDatagram, .sendStream = linkStream, .close = linkClose, .maxDatagram = linkMax };

    fn from(p: *anyopaque) *Client {
        return @ptrCast(@alignCast(p));
    }
    fn linkDatagram(p: *anyopaque, body: []const u8) void {
        const cl = from(p);
        if (cl.dead or cl.close_after_flush) return;
        if (cl.out.items.len > ws_dgram_backlog) {
            cl.server.stats.ws_dgrams_dropped += 1;
            return;
        }
        cl.frameParts(0x82, &.{0}, body) catch {
            cl.dead = true;
        };
    }
    fn linkStream(p: *anyopaque, body: []const u8) void {
        const cl = from(p);
        if (cl.dead or cl.close_after_flush) return;
        cl.frameParts(0x82, &.{1}, body) catch {
            cl.dead = true;
        };
        if (cl.out.items.len > ws_max_backlog) {
            log.info("websocket client too far behind; dropping it", .{});
            cl.dead = true;
        }
    }
    fn linkClose(p: *anyopaque) void {
        const cl = from(p);
        if (cl.dead or cl.close_after_flush) return;
        cl.frame(0x88, &.{ 0x03, 0xE8 }) catch {}; // 1000 normal closure
        cl.close_after_flush = true;
    }
    fn linkMax(_: *anyopaque) usize {
        return 1100;
    }

    fn destroy(cl: *Client) void {
        const gpa = cl.server.gpa;
        if (cl.peer != 0) cl.server.hub.closed(cl.peer);
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
                // Process what arrived before the EOF (a final bye), then go.
                cl.process() catch {};
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
        var host: []const u8 = "";
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const k = std.mem.trim(u8, line[0..colon], " ");
            const v = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(k, "sec-websocket-key")) ws_key = v;
            if (std.ascii.eqlIgnoreCase(k, "upgrade") and std.ascii.eqlIgnoreCase(v, "websocket")) upgrade_ws = true;
            if (std.ascii.eqlIgnoreCase(k, "content-length")) content_length = std.fmt.parseInt(usize, v, 10) catch 0;
            if (std.ascii.eqlIgnoreCase(k, "host")) host = v;
        }
        if (content_length > 65536) return error.BadRequest;
        const total = end + 4 + content_length;
        if (cl.in.items.len < total) return false;
        const body = cl.in.items[end + 4 .. total];
        const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else "";
        cl.server.stats.http_requests += 1;

        const ws_session = util.sessionFromPath(path, "/ws");
        if (cl.server.mode == .main and ws_session != null and upgrade_ws and ws_key != null) {
            var sha = std.crypto.hash.Sha1.init(.{});
            sha.update(ws_key.?);
            sha.update(ws_guid);
            var digest: [20]u8 = undefined;
            sha.final(&digest);
            var accept: [28]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&accept, &digest);
            try cl.out.print(gpa, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
            const sess = try gpa.dupe(u8, ws_session.?);
            defer gpa.free(sess);
            cl.consume(total);
            cl.mode = .ws;
            cl.server.stats.ws_total += 1;
            cl.peer = cl.server.hub.opened(.{ .ptr = cl, .vt = &link_vt }, sess, .websocket);
            return true;
        }

        const acme_prefix = "/.well-known/acme-challenge/";
        if (std.mem.startsWith(u8, path, acme_prefix) and cl.server.acme_webroot != null) {
            const token = path[acme_prefix.len..];
            if (token.len > 0 and token.len < 256 and for (token) |ch| {
                if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) break false;
            } else true) {
                const file = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ cl.server.acme_webroot.?, acme_prefix, token });
                defer gpa.free(file);
                if (util.readFile(gpa, file, 65536)) |data| {
                    defer gpa.free(data);
                    try cl.respond(200, "text/plain", data);
                } else |_| try cl.respond(404, "text/plain", "not found\n");
            } else try cl.respond(404, "text/plain", "not found\n");
        } else if (cl.server.mode == .redirect) {
            const h = host[0 .. std.mem.indexOfScalar(u8, host, ':') orelse host.len];
            try cl.out.print(gpa, "HTTP/1.1 301 Moved Permanently\r\nLocation: https://{s}{s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ h, target });
            cl.close_after_flush = true;
        } else if (std.mem.eql(u8, method, "OPTIONS")) {
            try cl.respond(204, "text/plain", "");
        } else if (cl.server.api) |api| {
            var resp: Response = .{};
            defer resp.body.deinit(gpa);
            api.handle(api.ptr, .{ .method = method, .path = path, .query = query, .body = body, .host = host }, &resp) catch |e| {
                resp.status = 500;
                resp.content_type = "text/plain";
                resp.body.clearRetainingCapacity();
                try resp.body.print(gpa, "error: {s}\n", .{@errorName(e)});
            };
            try cl.respond(resp.status, resp.content_type, resp.body.items);
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
            201 => "Created",
            204 => "No Content",
            400 => "Bad Request",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            503 => "Service Unavailable",
            else => "Error",
        };
        try cl.out.print(gpa, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n" ++
            "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: content-type\r\n" ++
            "Connection: keep-alive\r\n\r\n", .{ status, reason, ctype, body.len });
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

        // Copy out: the hub may queue output or close us while we hold it.
        const msg = try gpa.dupe(u8, payload);
        defer gpa.free(msg);
        cl.consume(off + payload.len);
        switch (opcode) {
            0x8 => { // close: answer and hang up
                try cl.frame(0x88, msg[0..@min(msg.len, 2)]);
                cl.close_after_flush = true;
            },
            0x9 => try cl.frame(0x8A, msg), // ping -> pong
            0xA => {},
            0x2 => {
                // I3 requires one whole message per WebSocket message.
                if (fin_op & 0x80 == 0) return error.BadFrame;
                cl.server.stats.ws_msgs += 1;
                cl.server.stats.ws_bytes += msg.len;
                if (msg.len < 1 or cl.peer == 0) return true;
                switch (msg[0]) {
                    0 => cl.server.hub.datagram(cl.peer, msg[1..]),
                    1 => cl.server.hub.stream(cl.peer, msg[1..]),
                    else => {},
                }
            },
            else => return error.BadFrame, // text and continuation frames are not I3
        }
        return true;
    }

    fn frameParts(cl: *Client, first: u8, a: []const u8, b: []const u8) !void {
        const gpa = cl.server.gpa;
        const n = a.len + b.len;
        try cl.out.append(gpa, first);
        if (n < 126) {
            try cl.out.append(gpa, @intCast(n));
        } else if (n < 65536) {
            try cl.out.append(gpa, 126);
            var l: [2]u8 = undefined;
            std.mem.writeInt(u16, &l, @intCast(n), .big);
            try cl.out.appendSlice(gpa, &l);
        } else {
            try cl.out.append(gpa, 127);
            var l: [8]u8 = undefined;
            std.mem.writeInt(u64, &l, n, .big);
            try cl.out.appendSlice(gpa, &l);
        }
        try cl.out.appendSlice(gpa, a);
        try cl.out.appendSlice(gpa, b);
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
