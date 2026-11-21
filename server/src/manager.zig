//! The session manager: sessions by link id, many per process, all stepped
//! from one shared 30 Hz timer. Implements `net.Hub` for the transports.
//!
//! A session is created on demand: the first `hello` for an unknown
//! `/s/<id>` creates it on the map whose SHA-256 the hello names, if the
//! operator has installed that map. `POST /sessions?map=NAME` creates one
//! up front with a fresh id. A session closes 60 s after its last player
//! leaves (or 60 s after creation if nobody joins).

const std = @import("std");
const ifc = @import("interfaces");
const net = @import("net.zig");
const maps = @import("maps.zig");
const util = @import("util.zig");
const session = @import("session.zig");
const abi = ifc.abi;
const wire = ifc.wire;
const log = std.log.scoped(.manager);

pub const Options = struct {
    replay_dir: ?[]const u8 = null,
    /// Create sessions for unknown ids on the first hello.
    create_on_join: bool = true,
    idle_close_ns: u64 = 60 * std.time.ns_per_s,
    max_sessions: u32 = 256,
    settings: session.Settings = .{},
    /// Fixed seed for every session (tests); otherwise random per session.
    seed: ?u64 = null,
};

pub fn Manager(comptime Sim: type) type {
    return struct {
        const Self = @This();
        pub const S = session.Session(Sim);

        const Peer = struct {
            link: net.Link,
            transport: net.TransportKind,
            session_name: [64]u8,
            session_len: u8,
            session: ?*S = null,
            opened_ns: u64,
            rejected: bool = false,
        };

        gpa: std.mem.Allocator,
        registry: *maps.Registry,
        opts: Options,
        sessions: std.ArrayList(*S) = .empty,
        peers: std.AutoHashMapUnmanaged(net.PeerId, Peer) = .empty,
        next_peer: net.PeerId = 1,
        next_client: u32 = 1,
        scratch: []u8,
        // timer
        t0_ns: u64,
        global_tick: u64 = 0,
        late_ticks: u64 = 0,
        skipped_ticks: u64 = 0,
        shutting_down: bool = false,
        // counters
        sessions_total: u64 = 0,
        joins_total: u64 = 0,
        rejects_total: [9]u64 = @splat(0),

        pub fn init(gpa: std.mem.Allocator, registry: *maps.Registry, opts: Options) !*Self {
            const self = try gpa.create(Self);
            self.* = .{ .gpa = gpa, .registry = registry, .opts = opts, .scratch = try gpa.alloc(u8, wire.max_stream_message), .t0_ns = util.now() };
            return self;
        }

        pub fn hub(self: *Self) net.Hub {
            return .{ .ptr = self, .vt = &hub_vt };
        }

        const hub_vt: net.Hub.VTable = .{
            .opened = hubOpened,
            .stream = hubStream,
            .datagram = hubDatagram,
            .closed = hubClosed,
        };

        fn fromPtr(p: *anyopaque) *Self {
            return @ptrCast(@alignCast(p));
        }

        fn hubOpened(p: *anyopaque, link: net.Link, name: []const u8, t: net.TransportKind) net.PeerId {
            const self = fromPtr(p);
            const id = self.next_peer;
            self.next_peer += 1;
            var peer: Peer = .{ .link = link, .transport = t, .session_name = undefined, .session_len = @intCast(@min(name.len, 64)), .opened_ns = util.now() };
            @memcpy(peer.session_name[0..peer.session_len], name[0..peer.session_len]);
            self.peers.put(self.gpa, id, peer) catch {
                link.close();
                return 0;
            };
            return id;
        }

        fn hubStream(p: *anyopaque, id: net.PeerId, body: []const u8) void {
            const self = fromPtr(p);
            const peer = self.peers.getPtr(id) orelse return;
            if (peer.rejected) return;
            const now = util.now();
            if (peer.session) |s| {
                if (s.clientOf(id)) |cl| return s.onStream(cl, body, now);
                return;
            }
            self.onHello(id, peer, body, now);
        }

        fn hubDatagram(p: *anyopaque, id: net.PeerId, body: []const u8) void {
            const self = fromPtr(p);
            const peer = self.peers.getPtr(id) orelse return;
            const s = peer.session orelse return;
            const cl = s.clientOf(id) orelse return;
            s.onDatagram(cl, body, util.now());
        }

        fn hubClosed(p: *anyopaque, id: net.PeerId) void {
            const self = fromPtr(p);
            const kv = self.peers.fetchRemove(id) orelse return;
            if (kv.value.session) |s| {
                if (s.clientOf(id)) |cl| s.onLost(cl, util.now(), "connection closed");
            }
        }

        fn reject(self: *Self, peer: *Peer, code: wire.RejectCode, msg: []const u8) void {
            var buf: [256]u8 = undefined;
            var w: wire.Writer = .{ .buf = &buf };
            (wire.Reject{ .code = code, .message = msg }).encode(&w) catch {};
            peer.link.sendStream(w.written());
            peer.link.close();
            peer.rejected = true;
            const ci = @intFromEnum(code);
            if (ci < self.rejects_total.len) self.rejects_total[ci] += 1;
            log.info("reject {s} ({s}) for session {s}", .{ @tagName(code), msg, peer.session_name[0..peer.session_len] });
        }

        fn onHello(self: *Self, id: net.PeerId, peer: *Peer, body: []const u8, now: u64) void {
            if (self.shutting_down) return self.reject(peer, .shutting_down, "The server is restarting. Try again in a minute.");
            var names: [wire.max_local_players][]const u8 = undefined;
            var r: wire.Reader = .{ .buf = body };
            const hello = wire.Hello.decode(&r, &names) catch return self.reject(peer, .bad_message, "Expected hello.");
            if (hello.protocol != wire.protocol_version)
                return self.reject(peer, .protocol_mismatch, "This game version does not match the server. Reload the page.");
            if (hello.abi != abi.abi_version or hello.layout_hash != Sim.layout_hash)
                return self.reject(peer, .layout_mismatch, "This game build does not match the server. Reload the page.");

            const name = peer.session_name[0..peer.session_len];
            var sess = self.find(name);
            if (sess) |s| {
                if (!std.mem.eql(u8, &s.map.hash, &hello.map_hash))
                    return self.reject(peer, .map_mismatch, "Your map file differs from the one this session uses.");
            } else {
                if (!self.opts.create_on_join) return self.reject(peer, .session_not_found, "No such session.");
                const m = self.registry.byHash(&hello.map_hash) orelse
                    return self.reject(peer, .map_mismatch, "This server does not have your map file installed.");
                sess = self.createSession(name, m) catch |e| switch (e) {
                    error.TooManySessions => return self.reject(peer, .session_full, "The server is full. Try again later."),
                    else => return self.reject(peer, .session_not_found, "Could not start the session."),
                };
            }
            const s = sess.?;
            const cid = self.next_client;
            self.next_client += 1;
            _ = s.join(id, peer.link, peer.transport, cid, hello, now) catch |e| switch (e) {
                error.SessionFull => return self.reject(peer, .session_full, "This session is full."),
                error.ResumeExpired => return self.reject(peer, .resume_expired, "Too late to resume."),
                error.OutOfMemory => return self.reject(peer, .shutting_down, "Server out of memory."),
            };
            peer.session = s;
            self.joins_total += 1;
        }

        pub fn find(self: *Self, name: []const u8) ?*S {
            for (self.sessions.items) |s| if (std.mem.eql(u8, s.name, name)) return s;
            return null;
        }

        pub fn createSession(self: *Self, name: []const u8, m: *maps.Map) !*S {
            if (self.sessions.items.len >= self.opts.max_sessions) return error.TooManySessions;
            const grid = try self.registry.grid(m);
            var seed: u64 = undefined;
            if (self.opts.seed) |sd| seed = sd else util.randomBytes(std.mem.asBytes(&seed));
            const s = try S.create(self.gpa, name, m, grid, seed, self.opts.settings, self.scratch, self.opts.replay_dir, util.now());
            try self.sessions.append(self.gpa, s);
            self.sessions_total += 1;
            log.info("session {s} created on {s} (seed {x})", .{ name, m.name, seed });
            return s;
        }

        /// A fresh random session id, for `POST /sessions`.
        pub fn newSessionId(out: *[12]u8) []const u8 {
            const alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
            var rnd: [12]u8 = undefined;
            util.randomBytes(&rnd);
            for (out, rnd) |*o, b| o.* = alphabet[b % alphabet.len];
            return out;
        }

        // ------------------------------------------------------------------
        // The shared timer

        fn tickTime(self: *const Self, n: u64) u64 {
            return self.t0_ns + n * std.time.ns_per_s / abi.tick_hz;
        }

        /// Monotonic ns at which the next tick is due.
        pub fn nextDeadline(self: *const Self) u64 {
            return self.tickTime(self.global_tick + 1);
        }

        /// Runs every tick that is due. Returns how many ran.
        pub fn advance(self: *Self, now: u64) u32 {
            var ran: u32 = 0;
            while (now >= self.tickTime(self.global_tick + 1)) {
                // If we fell far behind (suspended VM, debugger), skip
                // ahead instead of stepping a burst.
                if (now > self.tickTime(self.global_tick + 1 + 5)) {
                    const behind = (now - self.t0_ns) * abi.tick_hz / std.time.ns_per_s;
                    self.skipped_ticks += behind - self.global_tick - 1;
                    log.warn("timer fell {d} ticks behind; skipping ahead", .{behind - self.global_tick - 1});
                    self.global_tick = behind - 1;
                }
                if (ran > 0) self.late_ticks += 1;
                self.global_tick += 1;
                self.stepAll(now);
                ran += 1;
            }
            return ran;
        }

        fn stepAll(self: *Self, now: u64) void {
            // 20 Hz snapshots from 30 Hz ticks: send on two ticks of three.
            const send = (self.global_tick * self.opts.settings.snapshot_hz) / abi.tick_hz !=
                ((self.global_tick - 1) * self.opts.settings.snapshot_hz) / abi.tick_hz;
            var i: usize = 0;
            while (i < self.sessions.items.len) {
                const s = self.sessions.items[i];
                s.tick(now, send);
                if (s.empty_since_ns) |t| if (now - t >= self.opts.idle_close_ns) {
                    log.info("session {s} closed after {d} s empty ({d} ticks)", .{ s.name, self.opts.idle_close_ns / std.time.ns_per_s, s.steps });
                    _ = self.sessions.swapRemove(i);
                    self.detachPeers(s);
                    s.destroy();
                    continue;
                };
                i += 1;
            }
        }

        fn detachPeers(self: *Self, s: *S) void {
            var it = self.peers.valueIterator();
            while (it.next()) |p| if (p.session == s) {
                p.session = null;
                p.rejected = true;
            };
        }

        pub fn beginShutdown(self: *Self) void {
            self.shutting_down = true;
            for (self.sessions.items) |s| s.shutdown();
        }

        // ------------------------------------------------------------------
        // Observability

        pub fn writeMetrics(self: *Self, out: *std.ArrayList(u8)) !void {
            const gpa = self.gpa;
            try out.print(gpa,
                \\# TYPE gta2_sessions gauge
                \\gta2_sessions {d}
                \\# TYPE gta2_sessions_total counter
                \\gta2_sessions_total {d}
                \\# TYPE gta2_joins_total counter
                \\gta2_joins_total {d}
                \\# TYPE gta2_peers gauge
                \\gta2_peers {d}
                \\# TYPE gta2_ticks_total counter
                \\gta2_ticks_total {d}
                \\# TYPE gta2_late_ticks_total counter
                \\gta2_late_ticks_total {d}
                \\# TYPE gta2_skipped_ticks_total counter
                \\gta2_skipped_ticks_total {d}
                \\
            , .{ self.sessions.items.len, self.sessions_total, self.joins_total, self.peers.count(), self.global_tick, self.late_ticks, self.skipped_ticks });
            try out.print(gpa, "# TYPE gta2_rejects_total counter\n", .{});
            for (self.rejects_total, 0..) |n, code| if (code > 0) {
                try out.print(gpa, "gta2_rejects_total{{code=\"{d}\"}} {d}\n", .{ code, n });
            };
            try out.print(gpa,
                \\# TYPE gta2_session_players gauge
                \\# TYPE gta2_session_tick gauge
                \\# TYPE gta2_session_step_seconds gauge
                \\# TYPE gta2_session_step_seconds_total counter
                \\# TYPE gta2_session_snapshot_seconds_total counter
                \\# TYPE gta2_client_rtt_seconds gauge
                \\# TYPE gta2_client_snapshots_total counter
                \\# TYPE gta2_client_snapshots_lost_total counter
                \\# TYPE gta2_client_inputs_total counter
                \\# TYPE gta2_client_inputs_expected_total counter
                \\# TYPE gta2_client_bytes_tx_total counter
                \\# TYPE gta2_client_bytes_rx_total counter
                \\# TYPE gta2_client_snapshot_records_deferred_total counter
                \\# TYPE gta2_slot_frames_repeated_total counter
                \\# TYPE gta2_slot_frames_total counter
                \\# TYPE gta2_slot_slack_quarter_ticks gauge
                \\
            , .{});
            for (self.sessions.items) |s| {
                const l = s.name;
                try out.print(gpa, "gta2_session_players{{session=\"{s}\",map=\"{s}\"}} {d}\n", .{ l, s.map.name, s.playerCount() });
                try out.print(gpa, "gta2_session_tick{{session=\"{s}\"}} {d}\n", .{ l, s.sim.tick() });
                try out.print(gpa, "gta2_session_step_seconds{{session=\"{s}\",stat=\"last\"}} {d:.9}\n", .{ l, nsToS(s.step_ns_last) });
                try out.print(gpa, "gta2_session_step_seconds{{session=\"{s}\",stat=\"max\"}} {d:.9}\n", .{ l, nsToS(s.step_ns_max) });
                try out.print(gpa, "gta2_session_step_seconds_total{{session=\"{s}\"}} {d:.9}\n", .{ l, nsToS(s.step_ns_sum) });
                try out.print(gpa, "gta2_session_snapshot_seconds_total{{session=\"{s}\"}} {d:.9}\n", .{ l, nsToS(s.snapshot_ns_sum) });
                for (s.clients.items) |cl| {
                    const st = cl.rep.stats;
                    try out.print(gpa, "gta2_client_rtt_seconds{{session=\"{s}\",client=\"{d}\",transport=\"{s}\"}} {d:.6}\n", .{ l, cl.id, @tagName(cl.transport), nsToS(st.last_rtt_ns) });
                    try out.print(gpa, "gta2_client_snapshots_total{{session=\"{s}\",client=\"{d}\"}} {d}\n", .{ l, cl.id, st.snapshots });
                    try out.print(gpa, "gta2_client_snapshots_lost_total{{session=\"{s}\",client=\"{d}\"}} {d}\n", .{ l, cl.id, st.lost });
                    try out.print(gpa, "gta2_client_snapshot_records_deferred_total{{session=\"{s}\",client=\"{d}\"}} {d}\n", .{ l, cl.id, st.deferred });
                    try out.print(gpa, "gta2_client_inputs_total{{session=\"{s}\",client=\"{d}\"}} {d}\n", .{ l, cl.id, cl.inputs_rx });
                    try out.print(gpa, "gta2_client_inputs_expected_total{{session=\"{s}\",client=\"{d}\"}} {d}\n", .{ l, cl.id, cl.inputs_expected });
                    try out.print(gpa, "gta2_client_bytes_tx_total{{session=\"{s}\",client=\"{d}\"}} {d}\n", .{ l, cl.id, cl.bytes_tx });
                    try out.print(gpa, "gta2_client_bytes_rx_total{{session=\"{s}\",client=\"{d}\"}} {d}\n", .{ l, cl.id, cl.bytes_rx });
                }
                for (s.slots, 0..) |sl, si| {
                    if (sl.state == .free) continue;
                    try out.print(gpa, "gta2_slot_frames_total{{session=\"{s}\",slot=\"{d}\"}} {d}\n", .{ l, si, sl.frames_rx });
                    try out.print(gpa, "gta2_slot_frames_repeated_total{{session=\"{s}\",slot=\"{d}\"}} {d}\n", .{ l, si, sl.repeats });
                    var mn: i32 = 127;
                    for (sl.slack) |v| mn = @min(mn, v);
                    try out.print(gpa, "gta2_slot_slack_quarter_ticks{{session=\"{s}\",slot=\"{d}\"}} {d}\n", .{ l, si, mn });
                }
            }
        }

        /// One log line per session, every 30 s.
        pub fn logStats(self: *Self) void {
            log.info("{d} session(s), {d} peer(s), tick {d}, late {d}, skipped {d}", .{ self.sessions.items.len, self.peers.count(), self.global_tick, self.late_ticks, self.skipped_ticks });
            for (self.sessions.items) |s| {
                const st = s.takeStepStats();
                log.info("  {s} [{s}] players={d} clients={d} tick={d} step avg={d}us max={d}us", .{ s.name, s.map.name, s.playerCount(), s.clients.items.len, s.sim.tick(), st.avg_ns / 1000, st.max_ns / 1000 });
                for (s.clients.items) |cl| {
                    const r = cl.rep.stats;
                    const up_loss = if (cl.inputs_expected == 0) 0 else 100 - @min(100, cl.inputs_rx * 100 / cl.inputs_expected);
                    const down_loss = if (r.snapshots == 0) 0 else r.lost * 100 / r.snapshots;
                    log.info("    client {d} {s} rtt={d}ms loss up~{d}% down~{d}% tx={d}B rx={d}B", .{ cl.id, @tagName(cl.transport), r.last_rtt_ns / std.time.ns_per_ms, up_loss, down_loss, cl.bytes_tx, cl.bytes_rx });
                }
            }
        }

        pub fn writeSessionsJson(self: *Self, out: *std.ArrayList(u8)) !void {
            try out.appendSlice(self.gpa, "[");
            for (self.sessions.items, 0..) |s, i| {
                if (i > 0) try out.appendSlice(self.gpa, ",");
                try out.print(self.gpa, "{{\"id\":\"{s}\",\"map\":\"{s}\",\"players\":{d},\"maxPlayers\":{d},\"tick\":{d}}}", .{ s.name, s.map.name, s.playerCount(), S.max_players, s.sim.tick() });
            }
            try out.appendSlice(self.gpa, "]");
        }
    };
}

fn nsToS(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e9;
}
