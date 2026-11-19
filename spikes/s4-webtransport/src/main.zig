//! Spike S4: WebTransport (datagrams + streams) and WebSocket echo server.
//!
//!   s4-server --cert cert.pem --key key.pem [--port 4433] [--http-port 8080]
//!             [--tls-http] [--report reports.log] [--no-cert-hash] [--loss PCT] [--verbose]
//!
//! UDP --port serves HTTP/3 + WebTransport at any path.
//! TCP --http-port serves the test page, /config, /report and /ws.
const std = @import("std");
const c = @import("c");
const util = @import("util.zig");
const quic = @import("quic.zig");
const tcp = @import("tcp.zig");

pub const std_options: std.Options = .{ .log_level = .info, .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const t = util.wallSeconds();
    const line = std.fmt.bufPrint(&buf, "{d} [{s}] {s}: " ++ fmt ++ "\n", .{ t, @tagName(level), @tagName(scope) } ++ args) catch return;
    _ = c.write(2, line.ptr, line.len);
}

const usage =
    \\usage: s4-server --cert FILE --key FILE [options]
    \\  --port N          UDP port for WebTransport (default 4433)
    \\  --http-port N     TCP port for page + WebSocket (default 8080)
    \\  --tls-http        serve the TCP side over TLS with the same cert
    \\  --report FILE     append browser soak reports to FILE
    \\  --no-cert-hash    do not offer serverCertificateHashes (CA-signed cert)
    \\  --loss PCT        test knob: drop PCT% of UDP packets each way
    \\  --verbose         log more
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var cert: ?[:0]const u8 = null;
    var key: ?[:0]const u8 = null;
    var report: ?[:0]const u8 = null;
    var port: u16 = 4433;
    var http_port: u16 = 8080;
    var tls_http = false;
    var offer_hash = true;
    var verbose = false;
    var loss: f64 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--cert")) {
            cert = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--key")) {
            key = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--report")) {
            report = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--port")) {
            port = try std.fmt.parseInt(u16, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--http-port")) {
            http_port = try std.fmt.parseInt(u16, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--loss")) {
            loss = (try std.fmt.parseFloat(f64, next)) / 100.0;
            i += 1;
        } else if (std.mem.eql(u8, a, "--tls-http")) {
            tls_http = true;
        } else if (std.mem.eql(u8, a, "--no-cert-hash")) {
            offer_hash = false;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else {
            _ = c.write(2, usage.ptr, usage.len);
            std.process.exit(2);
        }
    }
    if (cert == null or key == null) {
        _ = c.write(2, usage.ptr, usage.len);
        std.process.exit(2);
    }
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);

    var hash_b64: [44]u8 = undefined;
    const hash = try certHash(cert.?, &hash_b64);
    std.log.info("cert sha-256 (for serverCertificateHashes): {s}", .{hash});
    const config = try std.fmt.allocPrint(gpa, "{{\"wtPort\":{d},\"certHash\":{s}{s}{s}}}", .{
        port,
        if (offer_hash) "\"" else "",
        if (offer_hash) hash else "null",
        if (offer_hash) "\"" else "",
    });

    const qs = try quic.Server.init(gpa, port, cert.?, key.?, verbose);
    qs.loss = loss;
    if (loss > 0) std.log.warn("dropping {d:.1}% of UDP packets each way (--loss)", .{loss * 100});
    const ts = try tcp.Server.init(gpa, http_port, if (tls_http) .{ cert.?, key.? } else null, config, report);
    std.log.info("webtransport on udp :{d}, page + websocket on {s}://:{d}/", .{ port, if (tls_http) "https" else "http", http_port });

    var pfds: std.ArrayList(c.struct_pollfd) = .empty;
    var next_stats = util.now() + 30 * std.time.ns_per_s;
    var deadline: u64 = std.math.maxInt(u64);
    while (true) {
        pfds.clearRetainingCapacity();
        try pfds.append(gpa, .{ .fd = qs.fd, .events = c.POLLIN, .revents = 0 });
        try pfds.append(gpa, .{ .fd = ts.fd, .events = c.POLLIN, .revents = 0 });
        for (ts.clients.items) |cl| try pfds.append(gpa, .{ .fd = cl.fd, .events = tcp.Server.events(cl), .revents = 0 });

        const t = util.now();
        const wake = @min(deadline, next_stats);
        const timeout_ms: c_int = if (wake <= t) 0 else @intCast(@min((wake - t) / std.time.ns_per_ms + 1, 1000));
        _ = c.poll(pfds.items.ptr, pfds.items.len, timeout_ms);

        if (pfds.items[0].revents != 0) qs.onReadable();
        if (pfds.items[1].revents != 0) ts.onAccept();
        for (pfds.items[2..], 0..) |p, k| {
            if (p.revents != 0 and k < ts.clients.items.len) ts.clients.items[k].onEvents(p.revents);
        }
        ts.sweep();
        deadline = qs.onTimers();

        if (util.now() >= next_stats) {
            next_stats = util.now() + 30 * std.time.ns_per_s;
            const s = qs.stats;
            std.log.info("stats: quic conns={d} (total {d}) sessions={d} wt_streams={d} dgram rx={d} tx={d} drop={d} stream rx={d}B tx={d}B | ws clients={d} (total {d}) msgs={d} | reports={d}", .{
                qs.liveConns(), s.conns_total, s.sessions_total, s.wt_streams_total, s.dgrams_rx, s.dgrams_tx, s.dgrams_dropped, s.stream_bytes_rx, s.stream_bytes_tx, ts.wsClients(), ts.stats.ws_total, ts.stats.ws_msgs, ts.stats.reports,
            });
        }
    }
}

/// SHA-256 of the DER certificate, base64. Chrome's serverCertificateHashes
/// accepts this for self-signed ECDSA certs valid for at most 14 days.
fn certHash(path: [:0]const u8, out: *[44]u8) ![]const u8 {
    var pem: c.gnutls_datum_t = .{};
    if (c.gnutls_load_file(path.ptr, &pem) != 0) return error.CertLoad;
    defer c.gnutls_free.?(pem.data);
    var crt: c.gnutls_x509_crt_t = null;
    if (c.gnutls_x509_crt_init(&crt) != 0) return error.CertLoad;
    defer c.gnutls_x509_crt_deinit(crt);
    if (c.gnutls_x509_crt_import(crt, &pem, c.GNUTLS_X509_FMT_PEM) != 0) return error.CertLoad;
    var der: c.gnutls_datum_t = .{};
    if (c.gnutls_x509_crt_export2(crt, c.GNUTLS_X509_FMT_DER, &der) != 0) return error.CertLoad;
    defer c.gnutls_free.?(der.data);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(der.data[0..der.size], &digest, .{});
    return std.base64.standard.Encoder.encode(out, &digest);
}

test {
    _ = util;
}
