//! gta2-server: the dedicated server (workstream D).
//!
//!   gta2-server serve  --data DIR --cert FILE --key FILE [options]
//!   gta2-server replay FILE --data DIR
//!   gta2-server maps   --data DIR
//!   gta2-server bot    --url ws://HOST:PORT/s/ID/ws --map FILE.gmp [options]
//!
//! One process hosts many sessions, each a single-threaded sim stepped from
//! one shared 30 Hz timer, behind two transports that carry the same I3
//! channels: WebTransport (UDP, ngtcp2 + GnuTLS + a thin HTTP/3 layer) and
//! the WebSocket fallback (TCP, optionally TLS).
const std = @import("std");
const c = @import("c");
const ifc = @import("interfaces");
const util = @import("util.zig");
const net = @import("net.zig");
const quic = @import("quic.zig");
const tcp = @import("tcp.zig");
const maps = @import("maps.zig");
const replay = @import("replay.zig");
const manager = @import("manager.zig");
const snapshot = @import("snapshot.zig");
const bot = @import("bot.zig");
const abi = ifc.abi;
const wire = ifc.wire;

/// The sim this binary hosts: `abi.Stub` until `sim/` lands (build with
/// `-Dsim=real` then).
pub const Sim = @import("sim_impl").Sim;
const Mgr = manager.Manager(Sim);

comptime {
    abi.checkSim(Sim);
}

pub const std_options: std.Options = .{ .log_level = .info, .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const t = util.wallSeconds();
    const line = std.fmt.bufPrint(&buf, "{d} [{s}] {s}: " ++ fmt ++ "\n", .{ t, @tagName(level), @tagName(scope) } ++ args) catch return;
    _ = c.write(2, line.ptr, line.len);
}

const usage =
    \\usage:
    \\  gta2-server serve --data DIR --cert FILE --key FILE [options]
    \\      --data DIR          directory with the operator's own .gmp files
    \\      --port N            UDP port for WebTransport (default 4433)
    \\      --http-port N       TCP port for WebSocket + HTTP API (default 8080)
    \\      --tls-http          serve the TCP side over TLS with the same cert
    \\      --redirect-port N   plain-HTTP port for ACME challenges + redirect to https (e.g. 80)
    \\      --acme-webroot DIR  serve /.well-known/acme-challenge/ from DIR (certbot --webroot)
    \\      --no-cert-hash      do not offer serverCertificateHashes in /config (CA-signed cert)
    \\      --replay-dir DIR    record every session's inputs to DIR/<session>-<time>.g2wr
    \\      --no-create         do not create sessions on first join (only POST /sessions)
    \\      --budget BYTES      snapshot byte budget per client (default 187)
    \\      --interest BLOCKS   interest radius in blocks, 0 = everything (default 40)
    \\      --idle-close SECS   close a session this long after its last player (default 60)
    \\      --seed N            fixed sim seed for every session (tests)
    \\      --loss PCT          test knob: drop PCT% of UDP packets each way
    \\      --verbose
    \\  gta2-server replay FILE --data DIR     re-run a recorded session, compare hashes
    \\  gta2-server maps --data DIR            list installed maps and their hashes
    \\  gta2-server synth-map OUT.gmp          write a synthetic test city (CI; no game data needed)
    \\  gta2-server bot --url ws://H:P/s/ID/ws --map FILE.gmp [--bots N] [--seconds S] [--players-per-bot K]
    \\
;

fn die(msg: []const u8) noreturn {
    _ = c.write(2, msg.ptr, msg.len);
    std.process.exit(2);
}

var sig_hup: std.atomic.Value(bool) = .init(false);
var sig_term: std.atomic.Value(bool) = .init(false);

fn onSignal(sig: c_int) callconv(.c) void {
    if (sig == c.SIGHUP) sig_hup.store(true, .release) else sig_term.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) die(usage);
    const cmd = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, cmd, "serve")) return serve(gpa, rest);
    if (std.mem.eql(u8, cmd, "replay")) return replayCmd(gpa, rest);
    if (std.mem.eql(u8, cmd, "maps")) return mapsCmd(gpa, rest);
    if (std.mem.eql(u8, cmd, "synth-map")) return synthMap(gpa, rest);
    if (std.mem.eql(u8, cmd, "bot")) {
        const code = bot.run(Sim, gpa, rest) catch |e| {
            std.log.err("bot: {}", .{e});
            std.process.exit(2);
        };
        std.process.exit(code);
    }
    die(usage);
}

fn loadRegistry(gpa: std.mem.Allocator, dir: ?[]const u8) !*maps.Registry {
    const reg = try gpa.create(maps.Registry);
    reg.* = .init(gpa);
    const d = dir orelse die("--data DIR is required: point it at your own GTA2 data directory\n");
    const n = reg.scanDir(d) catch |e| {
        std.log.err("--data {s}: {}", .{ d, e });
        std.process.exit(2);
    };
    if (n == 0) std.log.warn("no .gmp files in {s}; every join will be refused", .{d});
    return reg;
}

fn mapsCmd(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    var data: ?[]const u8 = null;
    if (args.len == 2 and std.mem.eql(u8, args[0], "--data")) data = args[1] else die(usage);
    const reg = try loadRegistry(gpa, data);
    for (reg.maps.items) |m| {
        var hx: [64]u8 = undefined;
        std.debug.print("{s:<16} {s} {d} bytes\n", .{ m.name, util.hex(&hx, &m.hash), m.size });
    }
}

/// A small synthetic city for CI and demos: pavement everywhere, a road
/// grid with lane arrows every 16 blocks, and solid buildings between.
fn synthMap(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 1) die(usage);
    const formats = @import("formats");
    const gmp = formats.gmp;
    var b = try formats.synth.MapBuilder.init(gpa);
    defer b.deinit();
    const lid: gmp.Face = .{ .tile = 1, .bit10 = false, .bit11 = false, .flat = false, .flip = false, .rotation = 0 };
    const wall: gmp.Face = .{ .tile = 2, .bit10 = true, .bit11 = true, .flat = false, .flip = false, .rotation = 0 };
    for (0..256) |y| for (0..256) |x| {
        const road_x = x % 16 < 2; // north-south road
        const road_y = y % 16 < 2; // east-west road
        var blk: gmp.Block = .{ .lid = lid, .slope_type = 2 }; // pavement
        if (road_x or road_y) {
            blk.slope_type = 1; // road
            if (road_x and !road_y) blk.arrows = if (x % 16 == 0) 8 else 4; // +y / -y lanes
            if (road_y and !road_x) blk.arrows = if (y % 16 == 0) 1 else 2; // -x / +x lanes
        }
        b.set(x, y, 0, blk);
        const in_block = x % 16 >= 4 and x % 16 < 14 and y % 16 >= 4 and y % 16 < 14;
        const edge = x < 1 or y < 1 or x > 254 or y > 254;
        if (in_block and (x / 16 + y / 16) % 3 != 0 or edge) {
            b.set(x, y, 1, .{ .left = wall, .right = wall, .top = wall, .bottom = wall, .lid = lid, .slope_type = 0 });
        }
    };
    const bytes = try b.write(.dmap);
    defer gpa.free(bytes);
    const f = try util.OutFile.create(args[0]);
    defer f.close();
    try f.writeAll(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    var hx: [64]u8 = undefined;
    std.debug.print("{s}: {d} bytes, sha256 {s}\n", .{ args[0], bytes.len, util.hex(&hx, &hash) });
}

fn replayCmd(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    var file: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--data") and i + 1 < args.len) {
            data = args[i + 1];
            i += 1;
        } else file = args[i];
    }
    const path = file orelse die(usage);
    const reg = try loadRegistry(gpa, data);
    const bytes = try util.readFile(gpa, path, 1 << 31);
    defer gpa.free(bytes);
    const r = try replay.Reader.init(bytes);
    const m = reg.byHash(&r.header.map_hash) orelse die("the replay's map is not in --data\n");
    const grid = try reg.grid(m);
    const t0 = util.now();
    const res = replay.run(Sim, gpa, bytes, grid) catch |e| switch (e) {
        error.LayoutMismatch => die("the replay was recorded by a different sim build (layout_hash differs)\n"),
        else => return e,
    };
    const dt = util.now() - t0;
    std.debug.print("session {s} on {s}, {d} ticks ({d:.1} min of play) re-run in {d} ms, final hash {x:0>16}\n", .{
        r.header.session, m.name, res.ticks, @as(f64, @floatFromInt(res.ticks)) / 1800.0, dt / std.time.ns_per_ms, res.final_hash,
    });
    if (res.first_mismatch) |t| {
        std.debug.print("MISMATCH at tick {d}: recorded {x:0>16}, re-run {x:0>16}\n", .{ t, res.expected, res.got });
        std.process.exit(1);
    }
    std.debug.print("every tick matches\n", .{});
}

const Api = struct {
    gpa: std.mem.Allocator,
    mgr: *Mgr,
    reg: *maps.Registry,
    config_json: []const u8,
    qs: *quic.Server,
    ts: *tcp.Server,

    fn handle(p: *anyopaque, req: tcp.Request, resp: *tcp.Response) anyerror!void {
        const self: *Api = @ptrCast(@alignCast(p));
        const gpa = self.gpa;
        const get = std.mem.eql(u8, req.method, "GET");
        const post = std.mem.eql(u8, req.method, "POST");
        if (get and std.mem.eql(u8, req.path, "/")) {
            resp.content_type = "text/plain; charset=utf-8";
            try resp.body.print(gpa, "gta2-world server\nsim config {s}, layout_hash {x:0>16}, I3 protocol {d}\nendpoints: /healthz /metrics /config /maps /sessions, WebTransport https://HOST:PORT/s/ID, WebSocket /s/ID/ws\n", .{ Sim.config.name, Sim.layout_hash, wire.protocol_version });
        } else if (get and std.mem.eql(u8, req.path, "/healthz")) {
            resp.content_type = "text/plain";
            try resp.body.appendSlice(gpa, if (self.mgr.shutting_down) "shutting down\n" else "ok\n");
            if (self.mgr.shutting_down) resp.status = 503;
        } else if (get and std.mem.eql(u8, req.path, "/metrics")) {
            resp.content_type = "text/plain; version=0.0.4";
            try self.mgr.writeMetrics(&resp.body);
            const q = self.qs.stats;
            try resp.body.print(gpa,
                \\# TYPE gta2_quic_connections gauge
                \\gta2_quic_connections {d}
                \\gta2_quic_connections_total {d}
                \\gta2_quic_wt_sessions_total {d}
                \\gta2_quic_datagrams_rx_total {d}
                \\gta2_quic_datagrams_tx_total {d}
                \\gta2_quic_datagrams_dropped_total {d}
                \\gta2_ws_connections {d}
                \\gta2_ws_connections_total {d}
                \\gta2_ws_datagrams_dropped_total {d}
                \\gta2_http_requests_total {d}
                \\
            , .{ self.qs.liveConns(), q.conns_total, q.sessions_total, q.dgrams_rx, q.dgrams_tx, q.dgrams_dropped, self.ts.wsClients(), self.ts.stats.ws_total, self.ts.stats.ws_dgrams_dropped, self.ts.stats.http_requests });
        } else if (get and std.mem.eql(u8, req.path, "/config")) {
            try resp.body.appendSlice(gpa, self.config_json);
        } else if (get and std.mem.eql(u8, req.path, "/maps")) {
            try resp.body.appendSlice(gpa, "[");
            for (self.reg.maps.items, 0..) |m, i| {
                var hx: [64]u8 = undefined;
                try resp.body.print(gpa, "{s}{{\"name\":\"{s}\",\"sha256\":\"{s}\"}}", .{ if (i > 0) "," else "", m.name, util.hex(&hx, &m.hash) });
            }
            try resp.body.appendSlice(gpa, "]");
        } else if (get and std.mem.eql(u8, req.path, "/sessions")) {
            try self.mgr.writeSessionsJson(&resp.body);
        } else if (post and std.mem.eql(u8, req.path, "/sessions")) {
            // POST /sessions?map=NAME[&id=ID]
            var map_name: []const u8 = "";
            var want_id: ?[]const u8 = null;
            var it = std.mem.tokenizeScalar(u8, req.query, '&');
            while (it.next()) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                if (std.mem.eql(u8, kv[0..eq], "map")) map_name = kv[eq + 1 ..];
                if (std.mem.eql(u8, kv[0..eq], "id")) want_id = kv[eq + 1 ..];
            }
            const m = self.reg.byName(map_name) orelse {
                resp.status = 404;
                try resp.body.print(gpa, "{{\"error\":\"no installed map named '{s}'\"}}", .{map_name[0..@min(map_name.len, 32)]});
                return;
            };
            var idbuf: [12]u8 = undefined;
            const id = want_id orelse Mgr.newSessionId(&idbuf);
            if (!util.validSessionId(id)) {
                resp.status = 400;
                try resp.body.appendSlice(gpa, "{\"error\":\"bad session id\"}");
                return;
            }
            if (self.mgr.find(id) != null) {
                resp.status = 409;
                try resp.body.appendSlice(gpa, "{\"error\":\"session exists\"}");
                return;
            }
            const s = self.mgr.createSession(id, m) catch |e| {
                resp.status = 503;
                try resp.body.print(gpa, "{{\"error\":\"{s}\"}}", .{@errorName(e)});
                return;
            };
            resp.status = 201;
            try resp.body.print(gpa, "{{\"id\":\"{s}\",\"map\":\"{s}\",\"path\":\"/s/{s}\"}}", .{ s.name, m.name, s.name });
        } else {
            resp.status = 404;
            resp.content_type = "text/plain";
            try resp.body.appendSlice(gpa, "not found\n");
        }
    }
};

fn serve(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    var cert: ?[:0]const u8 = null;
    var key: ?[:0]const u8 = null;
    var data: ?[]const u8 = null;
    var port: u16 = 4433;
    var http_port: u16 = 8080;
    var redirect_port: ?u16 = null;
    var acme_webroot: ?[]const u8 = null;
    var tls_http = false;
    var offer_hash = true;
    var verbose = false;
    var loss: f64 = 0;
    var opts: manager.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        var used_next = true;
        if (std.mem.eql(u8, a, "--cert")) {
            cert = next;
        } else if (std.mem.eql(u8, a, "--key")) {
            key = next;
        } else if (std.mem.eql(u8, a, "--data")) {
            data = next;
        } else if (std.mem.eql(u8, a, "--port")) {
            port = try std.fmt.parseInt(u16, next, 10);
        } else if (std.mem.eql(u8, a, "--http-port")) {
            http_port = try std.fmt.parseInt(u16, next, 10);
        } else if (std.mem.eql(u8, a, "--redirect-port")) {
            redirect_port = try std.fmt.parseInt(u16, next, 10);
        } else if (std.mem.eql(u8, a, "--acme-webroot")) {
            acme_webroot = next;
        } else if (std.mem.eql(u8, a, "--replay-dir")) {
            opts.replay_dir = next;
        } else if (std.mem.eql(u8, a, "--budget")) {
            opts.settings.policy.budget = @min(try std.fmt.parseInt(usize, next, 10), wire.max_datagram);
        } else if (std.mem.eql(u8, a, "--interest")) {
            opts.settings.policy.interest_radius = try std.fmt.parseInt(i32, next, 10);
        } else if (std.mem.eql(u8, a, "--idle-close")) {
            opts.idle_close_ns = try std.fmt.parseInt(u64, next, 10) * std.time.ns_per_s;
        } else if (std.mem.eql(u8, a, "--seed")) {
            opts.seed = try std.fmt.parseInt(u64, next, 0);
        } else if (std.mem.eql(u8, a, "--loss")) {
            loss = (try std.fmt.parseFloat(f64, next)) / 100.0;
        } else {
            used_next = false;
            if (std.mem.eql(u8, a, "--tls-http")) {
                tls_http = true;
            } else if (std.mem.eql(u8, a, "--no-cert-hash")) {
                offer_hash = false;
            } else if (std.mem.eql(u8, a, "--no-create")) {
                opts.create_on_join = false;
            } else if (std.mem.eql(u8, a, "--verbose")) {
                verbose = true;
            } else die(usage);
        }
        if (used_next) {
            if (i + 1 >= args.len) die(usage);
            i += 1;
        }
    }
    if (cert == null or key == null) die(usage);
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    _ = c.signal(c.SIGHUP, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGINT, onSignal);

    const reg = try loadRegistry(gpa, data);
    for (reg.maps.items) |m| {
        var hx: [64]u8 = undefined;
        std.log.info("map {s}: {s}", .{ m.name, util.hex(&hx, &m.hash) });
    }
    if (snapshot.Replicator(Sim).fallback_columns > 0)
        std.log.warn("{d} replicated component(s) use the 32-bit word codec; give the sim a ComponentType()", .{snapshot.Replicator(Sim).fallback_columns});

    const mgr = try Mgr.init(gpa, reg, opts);
    const hub = mgr.hub();

    var hash_b64: [44]u8 = undefined;
    const hash = try certHash(cert.?, &hash_b64);
    std.log.info("cert sha-256 (for serverCertificateHashes): {s}", .{hash});
    const config_json = try std.fmt.allocPrint(gpa, "{{\"wtPort\":{d},\"certHash\":{s}{s}{s},\"protocol\":{d},\"abi\":{d},\"layoutHash\":\"{x:0>16}\",\"config\":\"{s}\",\"maxPlayers\":{d}}}", .{
        port,                                if (offer_hash) "\"" else "", if (offer_hash) hash else "null", if (offer_hash) "\"" else "",
        wire.protocol_version,               abi.abi_version,              Sim.layout_hash,                   Sim.config.name,
        Sim.config.max_players,
    });

    const qs = try quic.Server.init(gpa, hub, port, cert.?, key.?, verbose);
    qs.loss = loss;
    if (loss > 0) std.log.warn("dropping {d:.1}% of UDP packets each way (--loss)", .{loss * 100});
    var api: Api = undefined;
    const ts = try tcp.Server.init(gpa, hub, .{ .ptr = &api, .handle = Api.handle }, .main, http_port, if (tls_http) .{ cert.?, key.? } else null, acme_webroot);
    api = .{ .gpa = gpa, .mgr = mgr, .reg = reg, .config_json = config_json, .qs = qs, .ts = ts };
    const rs: ?*tcp.Server = if (redirect_port) |rp| try tcp.Server.init(gpa, hub, null, .redirect, rp, null, acme_webroot) else null;
    std.log.info("sim {s} (layout {x:0>16}); webtransport on udp :{d}; websocket + api on {s}://:{d}/{s}", .{
        Sim.config.name, Sim.layout_hash, port, if (tls_http) "https" else "http", http_port, if (rs != null) " (+ redirect/acme)" else "",
    });

    var pfds: std.ArrayList(c.struct_pollfd) = .empty;
    var next_stats = util.now() + 30 * std.time.ns_per_s;
    var quic_deadline: u64 = std.math.maxInt(u64);
    var shutdown_at: ?u64 = null;
    while (true) {
        if (sig_hup.swap(false, .acq_rel)) {
            std.log.info("SIGHUP: reloading certificate", .{});
            qs.reloadCert(cert.?, key.?) catch |e| std.log.err("quic cert reload: {}", .{e});
            if (tls_http) ts.reloadCert(cert.?, key.?) catch |e| std.log.err("tcp cert reload: {}", .{e});
        }
        if (sig_term.swap(false, .acq_rel) and shutdown_at == null) {
            std.log.info("shutting down: telling clients, exiting in 2 s", .{});
            mgr.beginShutdown();
            shutdown_at = util.now() + 2 * std.time.ns_per_s;
        }
        if (shutdown_at) |t| if (util.now() >= t) {
            for (mgr.sessions.items) |s| if (s.replay) |r| r.flush();
            std.log.info("bye", .{});
            return;
        };

        pfds.clearRetainingCapacity();
        try pfds.append(gpa, .{ .fd = qs.fd, .events = c.POLLIN, .revents = 0 });
        try pfds.append(gpa, .{ .fd = ts.fd, .events = c.POLLIN, .revents = 0 });
        const n_fixed: usize = if (rs) |r| blk: {
            try pfds.append(gpa, .{ .fd = r.fd, .events = c.POLLIN, .revents = 0 });
            break :blk 3;
        } else 2;
        for (ts.clients.items) |cl| try pfds.append(gpa, .{ .fd = cl.fd, .events = tcp.Server.events(cl), .revents = 0 });
        if (rs) |r| for (r.clients.items) |cl| try pfds.append(gpa, .{ .fd = cl.fd, .events = tcp.Server.events(cl), .revents = 0 });

        const t = util.now();
        const wake = @min(@min(quic_deadline, next_stats), mgr.nextDeadline());
        const timeout_ms: c_int = if (wake <= t) 0 else @intCast(@min((wake - t + std.time.ns_per_ms - 1) / std.time.ns_per_ms, 1000));
        _ = c.poll(pfds.items.ptr, pfds.items.len, timeout_ms);

        if (pfds.items[0].revents != 0) qs.onReadable();
        if (pfds.items[1].revents != 0) ts.onAccept();
        if (rs) |r| if (pfds.items[2].revents != 0) r.onAccept();
        const n_ts = ts.clients.items.len;
        for (pfds.items[n_fixed..], 0..) |p, k| {
            if (p.revents == 0) continue;
            if (k < n_ts) {
                ts.clients.items[k].onEvents(p.revents);
            } else if (rs) |r| {
                if (k - n_ts < r.clients.items.len) r.clients.items[k - n_ts].onEvents(p.revents);
            }
        }

        _ = mgr.advance(util.now());

        qs.flushAll();
        ts.flushAll();
        ts.sweep();
        if (rs) |r| {
            r.flushAll();
            r.sweep();
        }
        quic_deadline = qs.onTimers();

        if (util.now() >= next_stats) {
            next_stats = util.now() + 30 * std.time.ns_per_s;
            const s = qs.stats;
            std.log.info("transport: quic conns={d} (total {d}) wt sessions total={d} dgram rx={d} tx={d} drop={d} | ws clients={d} (total {d})", .{
                qs.liveConns(), s.conns_total, s.sessions_total, s.dgrams_rx, s.dgrams_tx, s.dgrams_dropped, ts.wsClients(), ts.stats.ws_total,
            });
            mgr.logStats();
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

/// A flat test grid: one layer of pavement at z = 0 with a wall ring.
fn flatGrid(g: *abi.Grid) void {
    @memset(std.mem.asBytes(g), 0);
    for (0..abi.map_y) |y| for (0..abi.map_x) |x| {
        g.blocks[0][y][x] = @intFromEnum(abi.Shape.solid) | (@as(u16, @intFromEnum(abi.Ground.pavement)) << 9);
        if (x < 2 or y < 2 or x > 253 or y > 253) g.blocks[1][y][x] = @intFromEnum(abi.Shape.solid);
    };
}

test "the hosted sim replicates exactly through the I3 codecs" {
    const gpa = std.testing.allocator;
    const R = snapshot.Replicator(Sim);
    const grid = try gpa.create(abi.Grid);
    defer gpa.destroy(grid);
    flatGrid(grid);
    const sim = try gpa.create(Sim);
    defer gpa.destroy(sim);
    sim.init(grid, .{ .seed = 77, .mode = .authoritative });
    var frames: [Sim.config.max_players]ifc.input.Frame = undefined;
    var cl = try R.Client.init(gpa);
    defer cl.deinit();
    var m = try R.Mirror.init(gpa);
    defer m.deinit();
    var players: [4]wire.SnapshotPlayer = undefined;
    const buf = try gpa.alloc(u8, wire.max_stream_message);
    defer gpa.free(buf);
    var prng = std.Random.DefaultPrng.init(5);
    var ack_seq: u16 = 0;
    var ack_bits: u32 = 0;
    var seq: u16 = 0;
    const policy: snapshot.Policy = .{ .budget = wire.max_datagram, .interest_radius = 0 };
    for (0..400) |i| {
        const step = i > 0 and i < 340;
        if (step) {
            for (&frames, 0..) |*f, k| {
                f.* = ifc.input.Frame.neutral(ifc.input.seqOf(sim.tick()));
                f.throttle = @intCast(@as(i32, @intCast((i * 3 + k * 17) % 200)) - 100);
                f.steer = @intCast(@as(i32, @intCast((i + k * 5) % 120)) - 60);
                if ((i + k) % 45 == 0) f.buttons = ifc.input.Button.enter_exit;
                if ((i + k) % 13 == 0) f.buttons |= ifc.input.Button.fire;
            }
            var cmds: [4]abi.Command = undefined;
            var nc: usize = 0;
            if (i == 1) for (0..4) |k| {
                cmds[nc] = .{ .op = .join, .slot = @intCast(k * 3), .arg = 0 };
                nc += 1;
            };
            if (i == 200) {
                cmds[0] = .{ .op = .leave, .slot = 3, .arg = 0 };
                nc = 1;
            }
            sim.step(&frames, cmds[0..nc]);
        }
        const baseline = i == 0;
        var w: wire.Writer = .{ .buf = if (baseline) buf else buf[0..wire.max_datagram] };
        _ = try cl.build(sim.stateBytes(), .{ .seq = seq, .tick = sim.tick(), .echo_time = 0, .hold_ms = 0, .players = &.{} }, &.{}, policy, baseline, w.buf.len, &w, 0);
        seq +%= 1;
        const lossy = step;
        if (baseline or !lossy or prng.random().uintLessThan(u8, 10) >= 2) {
            const a = try m.apply(w.written(), &players);
            if (!a.stale) {
                ack_bits = if (baseline) 1 else if (snapshot.seqNewer(a.seq, ack_seq)) (if (a.seq -% ack_seq >= 32) 1 else (ack_bits << @intCast(a.seq -% ack_seq)) | 1) else ack_bits;
                ack_seq = a.seq;
            }
        }
        if (!lossy or prng.random().uintLessThan(u8, 10) >= 2) _ = cl.onAck(ack_seq, ack_bits, 1);
    }
    // After quiet, lossless rounds the mirror equals the server, bit for bit.
    const state = sim.stateBytes();
    var compared: u32 = 0;
    inline for (R.kinds) |k| {
        var idx: u32 = 0;
        while (idx < k.count) : (idx += 1) {
            const g = k.base + idx;
            const live = R.alive(state, k, idx);
            try std.testing.expectEqual(live, m.live[m.cur][g]);
            if (live) {
                var off: u32 = 0;
                inline for (k.comps) |col| {
                    try std.testing.expectEqualSlices(u8, R.compBytes(state, col, idx), m.vals[m.cur][R.baseOffsetOfGlobal(g) + off ..][0..col.stride]);
                    off += col.stride;
                }
                compared += 1;
            }
        }
    }
    // dm16: players plus ambient peds and parked cars; the stub: players only.
    try std.testing.expect(compared >= (if (Sim.config.ambient_peds > 0) 100 else 3));
    try std.testing.expectEqual(@as(u32, 0), R.fallback_columns);
}

test {
    _ = util;
    _ = maps;
    _ = replay;
    _ = snapshot;
    _ = @import("session.zig");
    _ = manager;
}
