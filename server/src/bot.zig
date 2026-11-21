//! Headless bot clients over the WebSocket fallback (plain ws:// only).
//!
//!   gta2-server bot --url ws://127.0.0.1:8080/s/test/ws --map wil.gmp
//!                   [--bots 4] [--seconds 20] [--players-per-bot 1]
//!
//! Each bot speaks I3 exactly as a browser would: hello, welcome, baseline,
//! then 30 Hz input datagrams with acks and 8-frame redundancy, steering its
//! clock from `slack_q`. Snapshots are decoded with the same per-entity
//! base rules as the encoder (`Replicator.Mirror`), so a run that ends with
//! zero decode errors means the stream is consistent end to end. Used for
//! local soak tests and the M1 headless check; the exit code is nonzero if
//! any bot failed.

const std = @import("std");
const c = @import("c");
const ifc = @import("interfaces");
const util = @import("util.zig");
const snapshot = @import("snapshot.zig");
const abi = ifc.abi;
const wire = ifc.wire;
const input = ifc.input;
const log = std.log.scoped(.bot);

pub fn run(comptime Sim: type, gpa: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    var url: []const u8 = "ws://127.0.0.1:8080/s/bots/ws";
    var map_hash: ?[32]u8 = null;
    var bots: usize = 2;
    var seconds: u64 = 10;
    var per_bot: usize = 1;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--url")) {
            url = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--map")) {
            const bytes = try util.readFile(gpa, next, 64 << 20);
            defer gpa.free(bytes);
            var h: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
            map_hash = h;
            i += 1;
        } else if (std.mem.eql(u8, a, "--map-hash")) {
            var h: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&h, next);
            map_hash = h;
            i += 1;
        } else if (std.mem.eql(u8, a, "--bots")) {
            bots = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--seconds")) {
            seconds = try std.fmt.parseInt(u64, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--players-per-bot")) {
            per_bot = @min(try std.fmt.parseInt(usize, next, 10), wire.max_local_players);
            i += 1;
        } else return error.BadArgs;
    }
    const mh = map_hash orelse return error.NeedMap;
    const target = try parseUrl(url);

    const B = Bot(Sim);
    var list: std.ArrayList(*B) = .empty;
    defer {
        for (list.items) |b| b.deinit();
        list.deinit(gpa);
    }
    for (0..bots) |n| {
        const b = try B.create(gpa, target, mh, n, per_bot);
        try list.append(gpa, b);
    }

    const t_end = util.now() + seconds * std.time.ns_per_s;
    var next_tick = util.now();
    var pfds: std.ArrayList(c.struct_pollfd) = .empty;
    defer pfds.deinit(gpa);
    while (util.now() < t_end) {
        pfds.clearRetainingCapacity();
        for (list.items) |b| try pfds.append(gpa, .{ .fd = b.fd, .events = c.POLLIN, .revents = 0 });
        const now = util.now();
        const wait: c_int = if (next_tick <= now) 0 else @intCast((next_tick - now) / std.time.ns_per_ms + 1);
        _ = c.poll(pfds.items.ptr, pfds.items.len, wait);
        for (pfds.items, list.items) |p, b| if (p.revents != 0) b.onReadable();
        if (util.now() >= next_tick) {
            next_tick += std.time.ns_per_s / abi.tick_hz;
            for (list.items) |b| b.tick();
        }
    }
    var failed: u8 = 0;
    for (list.items) |b| {
        b.sendBye();
        if (!b.report()) failed = 1;
    }
    return failed;
}

const Target = struct { host: [64]u8, host_len: usize, port: u16, path: []const u8 };

fn parseUrl(url: []const u8) !Target {
    if (!std.mem.startsWith(u8, url, "ws://")) return error.OnlyPlainWs;
    const rest = url[5..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadUrl;
    const hostport = rest[0..slash];
    var t: Target = .{ .host = undefined, .host_len = 0, .port = 80, .path = rest[slash..] };
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':');
    const host = if (colon) |cc| hostport[0..cc] else hostport;
    if (colon) |cc| t.port = try std.fmt.parseInt(u16, hostport[cc + 1 ..], 10);
    const h = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    if (h.len >= t.host.len) return error.BadUrl;
    @memcpy(t.host[0..h.len], h);
    t.host[h.len] = 0;
    t.host_len = h.len;
    return t;
}

fn Bot(comptime Sim: type) type {
    const R = snapshot.Replicator(Sim);
    return struct {
        const Self = @This();
        gpa: std.mem.Allocator,
        n: usize,
        fd: c_int,
        inbuf: std.ArrayList(u8) = .empty,
        upgraded: bool = false,
        welcomed: bool = false,
        have_baseline: bool = false,
        rejected: ?[]u8 = null,
        closed: bool = false,
        slots: [wire.max_local_players]u8 = undefined,
        n_slots: usize = 0,
        mirror: R.Mirror,
        // clock
        client_tick: u32 = 0,
        buffer_ticks: u8 = 2,
        frames: [64]input.Frame = undefined,
        /// Next tick without a generated frame, and the first one generated.
        next_gen: u32 = 0,
        first_gen: u32 = 0,
        input_ack: [wire.max_local_players]u32 = @splat(0),
        slack: i8 = 0,
        // acks
        ack_seq: u16 = 0,
        ack_bits: u32 = 0,
        // stats
        snapshots: u64 = 0,
        stale: u64 = 0,
        records: u64 = 0,
        decode_errors: u64 = 0,
        inputs_sent: u64 = 0,
        rtt_ms: u32 = 0,
        events: u64 = 0,
        kills: u64 = 0,
        deaths: u64 = 0,
        explosions: u64 = 0,
        rounds: u64 = 0,
        player_infos: u64 = 0,
        rng: std.Random.DefaultPrng,
        t_start: u64,
        pendingHello: [512]u8 = undefined,
        pendingHelloLen: usize = 0,
        frameScratch: [wire.max_local_players][wire.max_redundancy]input.Frame = undefined,

        fn create(gpa: std.mem.Allocator, t: Target, map_hash: [32]u8, n: usize, players: usize) !*Self {
            const self = try gpa.create(Self);
            self.* = .{ .gpa = gpa, .n = n, .fd = -1, .mirror = try R.Mirror.init(gpa), .rng = .init(n * 7919 + 1), .t_start = util.now() };
            self.fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
            if (self.fd < 0) return error.Socket;
            var sa: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
            sa.sin_family = c.AF_INET;
            sa.sin_port = c.htons(t.port);
            if (c.inet_pton(c.AF_INET, @ptrCast(&t.host), &sa.sin_addr) != 1) return error.BadHost;
            if (c.connect(self.fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0) return error.ConnectFailed;
            var one: c_int = 1;
            _ = c.setsockopt(self.fd, c.IPPROTO_TCP, c.TCP_NODELAY, &one, @sizeOf(c_int));
            var req: std.ArrayList(u8) = .empty;
            defer req.deinit(gpa);
            try req.print(gpa, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ t.path, t.host[0..t.host_len], t.port });
            try self.sendRaw(req.items);
            // hello
            var names_buf: [wire.max_local_players][16]u8 = undefined;
            var names: [wire.max_local_players][]const u8 = undefined;
            for (0..players) |k| names[k] = try std.fmt.bufPrint(&names_buf[k], "bot{d}.{d}", .{ n, k });
            var buf: [512]u8 = undefined;
            var w: wire.Writer = .{ .buf = &buf };
            try (wire.Hello{ .layout_hash = Sim.layout_hash, .map_hash = map_hash, .transport = .websocket, .names = names[0..players] }).encode(&w);
            self.pendingHello = undefined;
            @memcpy(self.pendingHello[0..w.pos], w.written());
            self.pendingHelloLen = w.pos;
            return self;
        }
        fn deinit(self: *Self) void {
            _ = c.close(self.fd);
            self.mirror.deinit();
            self.inbuf.deinit(self.gpa);
            if (self.rejected) |r| self.gpa.free(r);
            self.gpa.destroy(self);
        }

        fn sendRaw(self: *Self, b: []const u8) !void {
            var off: usize = 0;
            while (off < b.len) {
                const n = c.send(self.fd, b[off..].ptr, b.len - off, c.MSG_NOSIGNAL);
                if (n <= 0) return error.SendFailed;
                off += @intCast(n);
            }
        }

        /// Client frames are masked (RFC 6455); a zero mask keeps it simple.
        fn sendWs(self: *Self, chan: u8, body: []const u8) void {
            var hdr: [16]u8 = undefined;
            const n = body.len + 1;
            var hl: usize = 2;
            hdr[0] = 0x82;
            if (n < 126) {
                hdr[1] = 0x80 | @as(u8, @intCast(n));
            } else {
                hdr[1] = 0x80 | 126;
                std.mem.writeInt(u16, hdr[2..4], @intCast(n), .big);
                hl = 4;
            }
            @memset(hdr[hl..][0..4], 0);
            hl += 4;
            hdr[hl] = chan;
            hl += 1;
            self.sendRaw(hdr[0..hl]) catch {
                self.closed = true;
            };
            self.sendRaw(body) catch {
                self.closed = true;
            };
        }

        fn onReadable(self: *Self) void {
            var buf: [65536]u8 = undefined;
            const n = c.recv(self.fd, &buf, buf.len, 0);
            if (n <= 0) {
                self.closed = true;
                return;
            }
            self.inbuf.appendSlice(self.gpa, buf[0..@intCast(n)]) catch return;
            if (!self.upgraded) {
                const end = std.mem.indexOf(u8, self.inbuf.items, "\r\n\r\n") orelse return;
                if (!std.mem.startsWith(u8, self.inbuf.items, "HTTP/1.1 101")) {
                    self.closed = true;
                    return;
                }
                self.consume(end + 4);
                self.upgraded = true;
                self.sendWs(1, self.pendingHello[0..self.pendingHelloLen]);
            }
            while (self.inbuf.items.len >= 2) {
                const b = self.inbuf.items;
                const op = b[0] & 0x0f;
                var len: usize = b[1] & 0x7f;
                var off: usize = 2;
                if (len == 126) {
                    if (b.len < 4) return;
                    len = std.mem.readInt(u16, b[2..4], .big);
                    off = 4;
                } else if (len == 127) {
                    if (b.len < 10) return;
                    len = @intCast(std.mem.readInt(u64, b[2..10], .big));
                    off = 10;
                }
                if (b.len < off + len) return;
                const payload = self.gpa.dupe(u8, b[off..][0..len]) catch return;
                defer self.gpa.free(payload);
                self.consume(off + len);
                if (op == 0x8) {
                    self.closed = true;
                    return;
                }
                if (op != 0x2 or payload.len < 1) continue;
                if (payload[0] == 0) self.onDatagram(payload[1..]) else self.onStream(payload[1..]);
            }
        }

        fn consume(self: *Self, n: usize) void {
            std.mem.copyForwards(u8, self.inbuf.items, self.inbuf.items[n..]);
            self.inbuf.shrinkRetainingCapacity(self.inbuf.items.len - n);
        }

        fn onStream(self: *Self, body: []const u8) void {
            if (body.len == 0) return;
            var r: wire.Reader = .{ .buf = body };
            switch (@as(wire.Msg, @enumFromInt(body[0]))) {
                .welcome => {
                    const m = wire.Welcome.decode(&r) catch return;
                    self.welcomed = true;
                    self.n_slots = m.slots.len;
                    @memcpy(self.slots[0..m.slots.len], m.slots);
                    self.buffer_ticks = m.input_buffer_ticks;
                    self.client_tick = m.server_tick + m.input_buffer_ticks + 1;
                    self.next_gen = self.client_tick;
                    self.first_gen = self.client_tick;
                    for (0..self.n_slots) |k| self.input_ack[k] = m.server_tick;
                },
                .reject => {
                    const m = wire.Reject.decode(&r) catch return;
                    self.rejected = self.gpa.dupe(u8, m.message) catch null;
                    log.err("bot {d}: rejected ({s}): {s}", .{ self.n, @tagName(m.code), m.message });
                },
                .baseline => self.onSnapshot(body, true),
                .player_info => self.player_infos += 1,
                .event => {
                    self.events += 1;
                    const e = wire.Event.decode(&r) catch return;
                    const own = self.n_slots > 0;
                    switch (e.kind) {
                        .kill => if (own) {
                            if (e.a == self.slots[0] and e.b != e.a) self.kills += 1;
                            if (e.b == self.slots[0]) self.deaths += 1;
                        },
                        .explosion => self.explosions += 1,
                        .round_end => self.rounds += 1,
                        else => {},
                    }
                },
                else => {},
            }
        }

        fn onDatagram(self: *Self, body: []const u8) void {
            if (body.len == 0 or body[0] != @intFromEnum(wire.Msg.snapshot)) return;
            self.onSnapshot(body, false);
        }

        fn onSnapshot(self: *Self, body: []const u8, baseline: bool) void {
            var players: [wire.max_local_players]wire.SnapshotPlayer = undefined;
            const a = self.mirror.apply(body, &players) catch |e| {
                self.decode_errors += 1;
                if (self.decode_errors < 5) log.err("bot {d}: snapshot decode: {}", .{ self.n, e });
                return;
            };
            if (baseline) self.have_baseline = true;
            if (a.stale) {
                self.stale += 1;
                return;
            }
            self.snapshots += 1;
            self.records += a.records;
            // ack
            if (self.ack_bits == 0) {
                self.ack_seq = a.seq;
                self.ack_bits = 1;
            } else {
                const d = a.seq -% self.ack_seq;
                self.ack_bits = if (d >= 32) 1 else (self.ack_bits << @intCast(d)) | 1;
                self.ack_seq = a.seq;
            }
            var r: wire.Reader = .{ .buf = body };
            const hd = wire.SnapshotHeader.decode(&r, &players) catch return;
            const h = hd.header;
            const now16 = util.nowMs16();
            if (h.echo_time != 0) self.rtt_ms = now16 -% h.echo_time -% h.hold_ms;
            for (h.players) |p| for (self.slots[0..self.n_slots], 0..) |s, k| if (s == p.slot) {
                self.input_ack[k] = p.input_ack;
                self.slack = p.slack_q;
            };
            // Clock steering (S3): keep slack near the server's buffer.
            const want: i32 = @as(i32, self.buffer_ticks) * 4;
            if (!baseline) {
                if (self.slack < want - 2) self.client_tick +%= 1 else if (self.slack > want + 6) self.client_tick -%= 1;
                // Never fall behind the server.
                if (@as(i32, @bitCast(self.client_tick -% h.tick)) < 1) self.client_tick = h.tick + self.buffer_ticks;
            }
        }

        fn tick(self: *Self) void {
            if (self.closed or !self.welcomed or !self.have_baseline) return;
            const t = self.client_tick;
            self.client_tick +%= 1;
            // Every tick up to t gets exactly one frame, even when clock
            // steering jumps ahead; a gap would make the server drop the
            // whole datagram (seq must match position).
            const target = self.nearestEnemy();
            while (@as(i32, @bitCast(t -% self.next_gen)) >= 0) : (self.next_gen +%= 1) {
                var f = input.Frame.neutral(input.seqOf(self.next_gen));
                if (target) |tg| {
                    // Fight: run at the nearest other player in direct mode,
                    // fire when close, switch weapons now and then.
                    f.buttons = input.Button.direct | input.Button.run;
                    f.aim = tg.aim;
                    f.throttle = if (tg.dist < 2.5) 0 else 110;
                    if (tg.dist < 9 and self.rng.random().uintLessThan(u8, 3) != 0) f.buttons |= input.Button.fire;
                    if (self.rng.random().uintLessThan(u16, 400) == 0) f.buttons |= input.Button.weapon_next;
                } else {
                    // Wander: mostly forward, steer drifting.
                    f.throttle = 100;
                    f.steer = @intCast(@as(i32, self.rng.random().intRangeAtMost(i8, -40, 40)));
                    if (self.rng.random().uintLessThan(u8, 30) == 0) f.buttons = input.Button.fire;
                }
                self.frames[self.next_gen % 64] = f;
            }

            var players: [wire.max_local_players]wire.InputPlayer = undefined;
            for (0..self.n_slots) |k| {
                const newest = t;
                const since = newest -% self.input_ack[k];
                const generated = newest -% self.first_gen +% 1;
                const count: u32 = @intCast(@max(1, @min(@min(since, generated), wire.max_redundancy)));
                var frames: []const input.Frame = undefined;
                // frames[] ring is per bot, shared by its local players (same input).
                const start = newest -% (count - 1);
                var tmp = &self.frameScratch[k];
                for (0..count) |j| tmp[j] = self.frames[(start +% @as(u32, @intCast(j))) % 64];
                frames = tmp[0..count];
                players[k] = .{ .slot = self.slots[k], .newest_tick = newest, .frames = frames };
            }
            var buf: [400]u8 = undefined;
            var w: wire.Writer = .{ .buf = &buf };
            wire.encodeInput(&w, .{ .ack_seq = self.ack_seq, .ack_bits = self.ack_bits, .send_time = util.nowMs16(), .players = @intCast(self.n_slots) }, players[0..self.n_slots]) catch return;
            self.sendWs(0, w.written());
            self.inputs_sent += 1;
        }
        fn pedPos(self: *Self, slot: u8) ?[2]f64 {
            const row = self.mirror.component(abi.PlayerRow, 15, slot, 0xFFFF) orelse return null;
            if (row.ped.isNone()) return null;
            const t = self.mirror.component(abi.Transform, row.ped.kind(), row.ped.index(), 1) orelse return null;
            return .{ @as(f64, @floatFromInt(t.x)) / 65536.0, @as(f64, @floatFromInt(t.y)) / 65536.0 };
        }

        /// Aim heading and distance to the nearest other player on foot.
        const Enemy = struct { aim: u16, dist: f64 };
        fn nearestEnemy(self: *Self) ?Enemy {
            if (self.n_slots == 0) return null;
            const me = self.pedPos(self.slots[0]) orelse return null;
            var best: ?Enemy = null;
            var slot: u8 = 0;
            while (slot < 16) : (slot += 1) {
                var mine = false;
                for (self.slots[0..self.n_slots]) |s| mine = mine or s == slot;
                if (mine) continue;
                const p = self.pedPos(slot) orelse continue;
                const dx = p[0] - me[0];
                const dy = p[1] - me[1];
                const d = @sqrt(dx * dx + dy * dy);
                if (best != null and best.?.dist <= d) continue;
                const a = std.math.atan2(dy, dx); // -pi..pi, 0 = +x
                const turns = a / (2 * std.math.pi);
                const units: i64 = @intFromFloat(@round(turns * 65536.0));
                best = .{ .aim = @truncate(@as(u64, @bitCast(units))), .dist = d };
            }
            return best;
        }

        fn sendBye(self: *Self) void {
            if (self.closed) return;
            self.sendWs(1, &.{ @intFromEnum(wire.Msg.bye), 0 });
        }

        /// Prints a summary; returns false if this bot failed.
        fn report(self: *Self) bool {
            var pos: [2]f64 = .{ -1, -1 };
            if (self.n_slots > 0) {
                // own ped position from the mirror, via the player row
                if (self.mirror.component(abi.PlayerRow, 15, self.slots[0], 0xFFFF)) |row| {
                    if (!row.ped.isNone()) if (self.mirror.component(abi.Transform, row.ped.kind(), row.ped.index(), 1)) |t| {
                        pos = .{ @as(f64, @floatFromInt(t.x)) / 65536.0, @as(f64, @floatFromInt(t.y)) / 65536.0 };
                    };
                }
            }
            const ok = self.welcomed and self.have_baseline and self.decode_errors == 0 and self.snapshots > 0 and self.rejected == null;
            const lag = self.client_tick -% self.input_ack[0];
            std.debug.print("bot {d}: {s} slots={any} snapshots={d} stale={d} records={d} live={d} decode_errors={d} inputs={d} rtt={d}ms slack_q={d} ack_lag={d} events={d} kills={d} deaths={d} explosions={d} rounds={d} infos={d} pos=({d:.2},{d:.2})\n", .{
                self.n,                       if (ok) "ok" else "FAILED", self.slots[0..self.n_slots], self.snapshots, self.stale, self.records, self.mirror.liveCount(), self.decode_errors, self.inputs_sent, self.rtt_ms, self.slack, lag, self.events, self.kills, self.deaths, self.explosions, self.rounds, self.player_infos, pos[0], pos[1],
            });
            return ok;
        }
    };
}
