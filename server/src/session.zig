//! One game session: one sim, its player slots, and the clients attached
//! to it. Single-threaded; the manager steps every session from one shared
//! 30 Hz timer.
//!
//! Input buffering (I3 "Input datagram", design doc "Server"): each slot
//! has a 64-tick ring of frames keyed by tick. The step for tick T uses the
//! frame for T if it has arrived; otherwise it repeats the slot's previous
//! controls with the new seq. How early each frame arrived is measured in
//! quarter ticks and reported back as `slack_q`, which the client uses to
//! steer its clock so frames arrive `input_buffer_ticks` early.

const std = @import("std");
const ifc = @import("interfaces");
const net = @import("net.zig");
const maps = @import("maps.zig");
const replay = @import("replay.zig");
const snapshot = @import("snapshot.zig");
const util = @import("util.zig");
const abi = ifc.abi;
const wire = ifc.wire;
const input = ifc.input;
const Frame = input.Frame;
const log = std.log.scoped(.session);

pub const tick_ns: u64 = std.time.ns_per_s / abi.tick_hz;
pub const resume_window_ns: u64 = 10 * std.time.ns_per_s;
pub const client_timeout_ns: u64 = 5 * std.time.ns_per_s;
const ring_len = 64;
const slack_window = abi.tick_hz; // one second of ticks

pub const Settings = struct {
    input_buffer_ticks: u8 = 2,
    snapshot_hz: u8 = 20,
    policy: snapshot.Policy = .{},
};

pub fn Session(comptime Sim: type) type {
    return struct {
        const Self = @This();
        pub const Rep = snapshot.Replicator(Sim);
        pub const max_players = Sim.config.max_players;

        pub const SlotState = enum { free, active, orphaned };

        const Buffered = struct {
            tick: u32 = 0,
            valid: bool = false,
            frame: Frame = Frame.neutral(0),
            slack_q: i16 = 0,
        };

        pub const Slot = struct {
            state: SlotState = .free,
            client: ?*Client = null,
            name: [wire.max_name_len]u8 = undefined,
            name_len: u8 = 0,
            token: [16]u8 = @splat(0),
            orphan_deadline_ns: u64 = 0,
            ring: [ring_len]Buffered = @splat(.{}),
            last: Frame = Frame.neutral(0),
            input_ack: u32 = 0,
            slack: [slack_window]i8 = @splat(0),
            // metrics
            frames_rx: u64 = 0,
            repeats: u64 = 0,
            newest_seen: u32 = 0,

            pub fn nameSlice(s: *const Slot) []const u8 {
                return s.name[0..s.name_len];
            }
            fn slackMin(s: *const Slot) i8 {
                var m: i8 = 127;
                for (s.slack) |v| m = @min(m, v);
                return m;
            }
        };

        pub const Client = struct {
            peer: net.PeerId,
            link: net.Link,
            transport: net.TransportKind,
            id: u32,
            token: [16]u8,
            slots: std.ArrayList(u8) = .empty,
            rep: Rep.Client,
            need_baseline: bool = true,
            echo_time: u16 = 0,
            echo_recv_ns: u64 = 0,
            last_rx_ns: u64,
            connected_ns: u64,
            // uplink loss estimate: input datagrams seen vs. client ticks covered
            inputs_rx: u64 = 0,
            inputs_expected: u64 = 0,
            last_newest: ?u32 = null,
            bytes_rx: u64 = 0,
            bytes_tx: u64 = 0,
            dead: bool = false,
        };

        gpa: std.mem.Allocator,
        name: []const u8,
        map: *maps.Map,
        grid: *const abi.Grid,
        sim: *Sim,
        seed: u64,
        settings: Settings,
        slots: [max_players]Slot = @splat(.{}),
        clients: std.ArrayList(*Client) = .empty,
        cmds: std.ArrayList(abi.Command) = .empty,
        replay: ?*replay.Writer = null,
        created_ns: u64,
        empty_since_ns: ?u64,
        last_step_ns: u64,
        /// Shared scratch for baselines, owned by the manager.
        scratch: []u8,
        // metrics
        steps: u64 = 0,
        step_ns_last: u64 = 0,
        step_ns_max: u64 = 0,
        step_ns_sum: u64 = 0,
        step_count_window: u64 = 0,
        step_ns_window: u64 = 0,
        snapshot_ns_sum: u64 = 0,

        pub fn create(gpa: std.mem.Allocator, name: []const u8, map: *maps.Map, grid: *const abi.Grid, seed: u64, settings: Settings, scratch: []u8, replay_dir: ?[]const u8, now_ns: u64) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const sim = try gpa.create(Sim);
            errdefer gpa.destroy(sim);
            sim.init(grid, .{ .seed = seed, .mode = .authoritative });
            self.* = .{
                .gpa = gpa,
                .name = try gpa.dupe(u8, name),
                .map = map,
                .grid = grid,
                .sim = sim,
                .seed = seed,
                .settings = settings,
                .created_ns = now_ns,
                .empty_since_ns = now_ns,
                .last_step_ns = now_ns,
                .scratch = scratch,
            };
            map.sessions += 1;
            if (replay_dir) |dir| {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}-{d}.g2wr", .{ dir, name, util.wallSeconds() });
                defer gpa.free(path);
                self.replay = replay.Writer.create(gpa, path, .{
                    .layout_hash = Sim.layout_hash,
                    .map_hash = map.hash,
                    .seed = seed,
                    .max_players = max_players,
                    .config_name = Sim.config.name,
                    .session = name,
                    .started = util.wallSeconds(),
                }) catch |e| blk: {
                    log.warn("{s}: replay capture disabled: {}", .{ name, e });
                    break :blk null;
                };
                if (self.replay != null) log.info("{s}: recording to {s}", .{ name, path });
            }
            return self;
        }

        pub fn destroy(self: *Self) void {
            for (self.clients.items) |cl| {
                cl.link.close();
                self.freeClient(cl);
            }
            self.clients.deinit(self.gpa);
            self.cmds.deinit(self.gpa);
            if (self.replay) |r| r.close();
            self.map.sessions -= 1;
            self.gpa.destroy(self.sim);
            self.gpa.free(self.name);
            self.gpa.destroy(self);
        }

        fn freeClient(self: *Self, cl: *Client) void {
            cl.slots.deinit(self.gpa);
            cl.rep.deinit();
            self.gpa.destroy(cl);
        }

        pub fn playerCount(self: *const Self) u32 {
            var n: u32 = 0;
            for (self.slots) |s| {
                if (s.state != .free) n += 1;
            }
            return n;
        }

        fn freeSlots(self: *const Self) u32 {
            return max_players - self.playerCount();
        }

        // ------------------------------------------------------------------
        // Joining

        pub const JoinError = error{ SessionFull, ResumeExpired, OutOfMemory };

        /// Attach a connection that sent a valid `hello`. Sends `welcome`
        /// and `player_info`s; the baseline follows after the next step,
        /// once the join commands have spawned the players.
        pub fn join(self: *Self, peer: net.PeerId, link: net.Link, transport: net.TransportKind, client_id: u32, hello: wire.Hello, now_ns: u64) JoinError!*Client {
            const zero: [16]u8 = @splat(0);
            var resumed: [wire.max_local_players]u8 = undefined;
            var n_resumed: usize = 0;
            if (!std.mem.eql(u8, &hello.resume_token, &zero)) {
                for (&self.slots, 0..) |*s, i| {
                    if (s.state == .orphaned and std.mem.eql(u8, &s.token, &hello.resume_token) and now_ns < s.orphan_deadline_ns and n_resumed < resumed.len) {
                        resumed[n_resumed] = @intCast(i);
                        n_resumed += 1;
                    }
                }
                if (n_resumed == 0) return error.ResumeExpired;
            } else if (self.freeSlots() < hello.names.len) return error.SessionFull;

            const cl = try self.gpa.create(Client);
            errdefer self.gpa.destroy(cl);
            cl.* = .{ .peer = peer, .link = link, .transport = transport, .id = client_id, .token = undefined, .rep = try Rep.Client.init(self.gpa), .last_rx_ns = now_ns, .connected_ns = now_ns };
            util.randomBytes(&cl.token);
            try self.clients.append(self.gpa, cl);

            if (n_resumed > 0) {
                for (resumed[0..n_resumed]) |si| {
                    const s = &self.slots[si];
                    s.state = .active;
                    s.client = cl;
                    s.token = cl.token;
                    try cl.slots.append(self.gpa, si);
                    self.resetInput(s);
                    self.setConnected(si, true);
                }
                log.info("{s}: client {d} resumed {d} slot(s)", .{ self.name, client_id, n_resumed });
            } else {
                for (hello.names) |nm| {
                    const si = self.takeSlot(cl, nm) orelse break;
                    try cl.slots.append(self.gpa, si);
                }
                log.info("{s}: client {d} joined over {s} with {d} player(s)", .{ self.name, client_id, @tagName(transport), cl.slots.items.len });
            }
            self.empty_since_ns = null;

            var buf: [512]u8 = undefined;
            var w: wire.Writer = .{ .buf = &buf };
            (wire.Welcome{
                .client_id = client_id,
                .resume_token = cl.token,
                .server_tick = self.sim.tick(),
                .snapshot_hz = self.settings.snapshot_hz,
                .input_buffer_ticks = self.settings.input_buffer_ticks,
                .max_players = max_players,
                .config_name = Sim.config.name,
                .slots = cl.slots.items,
            }).encode(&w) catch unreachable;
            self.sendStream(cl, w.written());
            for (&self.slots, 0..) |*s, i| {
                if (s.state == .free) continue;
                self.sendPlayerInfo(cl, @intCast(i));
            }
            return cl;
        }

        fn takeSlot(self: *Self, cl: *Client, name: []const u8) ?u8 {
            for (&self.slots, 0..) |*s, i| {
                if (s.state != .free) continue;
                s.* = .{ .state = .active, .client = cl, .token = cl.token };
                const n = @min(name.len, wire.max_name_len);
                @memcpy(s.name[0..n], name[0..n]);
                s.name_len = @intCast(n);
                self.resetInput(s);
                const slot: u8 = @intCast(i);
                self.cmds.append(self.gpa, .{ .op = .join, .slot = slot, .arg = 0 }) catch return null;
                self.broadcastPlayerInfo(slot, cl);
                self.broadcastEvent(.{ .tick = self.sim.tick(), .kind = .player_joined, .a = slot }, null);
                return slot;
            }
            return null;
        }

        fn resetInput(self: *Self, s: *Slot) void {
            s.ring = @splat(.{});
            s.input_ack = self.sim.tick() -% 1;
            s.slack = @splat(@intCast(@as(i32, self.settings.input_buffer_ticks) * 4));
            s.last = Frame.neutral(0);
        }

        fn setConnected(self: *Self, slot: u8, on: bool) void {
            // The connected flag lives in sim state, owned by the sim; the
            // stub and sim/ set it on join. Nothing to do here beyond
            // player_info, which tells clients.
            _ = on;
            self.broadcastPlayerInfo(slot, null);
        }

        /// Frees a slot and queues the sim's leave command.
        fn leaveSlot(self: *Self, slot: u8, why: []const u8) void {
            const s = &self.slots[slot];
            if (s.state == .free) return;
            log.info("{s}: slot {d} ({s}) left: {s}", .{ self.name, slot, s.nameSlice(), why });
            s.* = .{};
            self.cmds.append(self.gpa, .{ .op = .leave, .slot = slot, .arg = 0 }) catch {};
            self.broadcastPlayerInfo(slot, null);
            self.broadcastEvent(.{ .tick = self.sim.tick(), .kind = .player_left, .a = slot }, null);
        }

        // ------------------------------------------------------------------
        // Messages from a client

        pub fn onStream(self: *Self, cl: *Client, body: []const u8, now_ns: u64) void {
            cl.bytes_rx += body.len;
            if (body.len == 0) return self.protocolError(cl);
            var r: wire.Reader = .{ .buf = body };
            switch (@as(wire.Msg, @enumFromInt(body[0]))) {
                .add_local => {
                    _ = r.int(u8) catch unreachable;
                    const local_index = r.int(u8) catch return self.protocolError(cl);
                    const name = r.str(wire.max_name_len) catch return self.protocolError(cl);
                    var slot: u8 = 0xFF;
                    if (cl.slots.items.len < wire.max_local_players) {
                        if (self.takeSlot(cl, name)) |s| {
                            slot = s;
                            cl.slots.append(self.gpa, s) catch {};
                        }
                    }
                    const out = [_]u8{ @intFromEnum(wire.Msg.local_added), local_index, slot };
                    self.sendStream(cl, &out);
                },
                .remove_local => {
                    _ = r.int(u8) catch unreachable;
                    const slot = r.int(u8) catch return self.protocolError(cl);
                    for (cl.slots.items, 0..) |s, i| if (s == slot) {
                        _ = cl.slots.orderedRemove(i);
                        self.leaveSlot(slot, "remove_local");
                        break;
                    };
                },
                .chat => {
                    const m = wire.Chat.decode(&r) catch return self.protocolError(cl);
                    if (std.mem.indexOfScalar(u8, cl.slots.items, m.slot) == null) return;
                    var buf: [256]u8 = undefined;
                    var w: wire.Writer = .{ .buf = &buf };
                    (wire.Chat{ .slot = m.slot, .text = m.text }).encode(&w, true) catch return;
                    for (self.clients.items) |o| self.sendStream(o, w.written());
                },
                .bye => {
                    cl.dead = true;
                    for (cl.slots.items) |s| self.leaveSlot(s, "bye");
                    cl.slots.clearRetainingCapacity();
                    cl.link.close();
                },
                else => self.protocolError(cl),
            }
            _ = now_ns;
        }

        fn protocolError(self: *Self, cl: *Client) void {
            var buf: [64]u8 = undefined;
            var w: wire.Writer = .{ .buf = &buf };
            (wire.Reject{ .code = .bad_message, .message = "protocol error" }).encode(&w) catch {};
            self.sendStream(cl, w.written());
            self.dropClient(cl, "protocol error", false);
        }

        pub fn onDatagram(self: *Self, cl: *Client, body: []const u8, now_ns: u64) void {
            if (body.len == 0 or body[0] != @intFromEnum(wire.Msg.input)) return;
            cl.bytes_rx += body.len;
            var r: wire.Reader = .{ .buf = body };
            var players: [wire.max_local_players]wire.InputPlayer = undefined;
            var frames: [wire.max_local_players][wire.max_redundancy]Frame = undefined;
            const d = wire.decodeInput(&r, &players, &frames) catch return; // malformed: dropped silently
            cl.last_rx_ns = now_ns;
            cl.echo_time = d.header.send_time;
            cl.echo_recv_ns = now_ns;
            if (d.header.ack_bits != 0) _ = cl.rep.onAck(d.header.ack_seq, d.header.ack_bits, now_ns);

            const cur = self.sim.tick();
            const frac4: i64 = @intCast(@min(3, (now_ns -| self.last_step_ns) * 4 / tick_ns));
            const now_q: i64 = @as(i64, cur) * 4 + frac4;
            for (d.players, 0..) |p, pi| {
                if (std.mem.indexOfScalar(u8, cl.slots.items, p.slot) == null) continue;
                const s = &self.slots[p.slot];
                if (s.state != .active) continue;
                if (pi == 0) {
                    cl.inputs_rx += 1;
                    if (cl.last_newest) |ln| {
                        const adv = p.newest_tick -% ln;
                        if (adv > 0 and adv < 300) cl.inputs_expected += adv;
                    } else cl.inputs_expected += 1;
                    if (cl.last_newest == null or @as(i32, @bitCast(p.newest_tick -% cl.last_newest.?)) > 0) cl.last_newest = p.newest_tick;
                }
                for (p.frames, 0..) |f, k| {
                    const t = p.newest_tick -% @as(u32, @intCast(p.frames.len - 1 - k));
                    const ahead: i32 = @bitCast(t -% cur);
                    if (ahead < 0 or ahead >= ring_len) continue; // stepped already, or absurdly early
                    const e = &s.ring[t % ring_len];
                    if (e.valid and e.tick == t) continue; // redundant copy
                    const slack = @as(i64, t) * 4 + 4 - now_q;
                    e.* = .{ .tick = t, .valid = true, .frame = f.sanitize(), .slack_q = @intCast(std.math.clamp(slack, -128, 127)) };
                    s.frames_rx += 1;
                    if (@as(i32, @bitCast(t -% s.newest_seen)) > 0) s.newest_seen = t;
                }
                self.advanceAck(s);
            }
        }

        fn advanceAck(self: *Self, s: *Slot) void {
            const stepped = self.sim.tick() -% 1;
            if (@as(i32, @bitCast(stepped -% s.input_ack)) > 0) s.input_ack = stepped;
            while (true) {
                const nt = s.input_ack +% 1;
                const e = &s.ring[nt % ring_len];
                if (!(e.valid and e.tick == nt)) break;
                s.input_ack = nt;
            }
        }

        /// The transport went away without a bye. Slots stay in the world
        /// for the resume window.
        pub fn onLost(self: *Self, cl: *Client, now_ns: u64, why: []const u8) void {
            for (cl.slots.items) |si| {
                const s = &self.slots[si];
                if (s.state != .active) continue;
                s.state = .orphaned;
                s.client = null;
                s.orphan_deadline_ns = now_ns + resume_window_ns;
                self.setConnected(si, false);
            }
            log.info("{s}: client {d} lost ({s}); {d} slot(s) held for resume", .{ self.name, cl.id, why, cl.slots.items.len });
            self.removeClient(cl);
        }

        fn dropClient(self: *Self, cl: *Client, why: []const u8, orphan: bool) void {
            cl.link.close();
            if (orphan) return self.onLost(cl, util.now(), why);
            for (cl.slots.items) |s| self.leaveSlot(s, why);
            self.removeClient(cl);
        }

        fn removeClient(self: *Self, cl: *Client) void {
            for (self.clients.items, 0..) |o, i| if (o == cl) {
                _ = self.clients.swapRemove(i);
                break;
            };
            self.freeClient(cl);
        }

        /// Finds the client for a peer.
        pub fn clientOf(self: *Self, peer: net.PeerId) ?*Client {
            for (self.clients.items) |cl| if (cl.peer == peer) return cl;
            return null;
        }

        // ------------------------------------------------------------------
        // The tick

        /// Steps the sim once. `send_snapshot` is true on the ticks where
        /// the 20 Hz snapshot schedule falls.
        pub fn tick(self: *Self, now_ns: u64, send_snapshot: bool) void {
            const t0 = util.now();
            const T = self.sim.tick();

            // Housekeeping first, so commands land in this step.
            var i: usize = 0;
            while (i < self.clients.items.len) {
                const cl = self.clients.items[i];
                if (now_ns > cl.last_rx_ns + client_timeout_ns) {
                    cl.link.close();
                    self.onLost(cl, now_ns, "no datagrams for 5 s");
                    continue;
                }
                i += 1;
            }
            for (&self.slots, 0..) |*s, si| {
                if (s.state == .orphaned and now_ns >= s.orphan_deadline_ns) self.leaveSlot(@intCast(si), "resume window passed");
            }

            var frames: [max_players]Frame = undefined;
            var present: [max_players]bool = @splat(false);
            for (&self.slots, 0..) |*s, si| {
                const seq = input.seqOf(T);
                frames[si] = Frame.neutral(seq);
                if (s.state == .free) continue;
                present[si] = true;
                const e = &s.ring[T % ring_len];
                var sample: i16 = undefined;
                if (s.state == .active and e.valid and e.tick == T) {
                    frames[si] = e.frame;
                    sample = e.slack_q;
                    e.valid = false;
                } else {
                    // Missing: repeat the previous controls (orphans stop).
                    if (s.state == .active) {
                        var f = s.last;
                        f.seq = seq;
                        frames[si] = f;
                        s.repeats += 1;
                    }
                    sample = -4;
                }
                s.slack[T % slack_window] = @intCast(std.math.clamp(sample, -128, 127));
                s.last = frames[si];
            }
            const cmds = self.cmds.items;
            self.sim.step(&frames, cmds);
            const h = if (self.replay != null) self.sim.hash() else 0;
            if (self.replay) |rw| rw.tick(T, cmds, &frames, &present, h);
            self.cmds.clearRetainingCapacity();
            self.last_step_ns = now_ns;
            for (&self.slots) |*s| if (s.state == .active) self.advanceAck(s);

            const t1 = util.now();
            self.steps += 1;
            self.step_ns_last = t1 - t0;
            self.step_ns_max = @max(self.step_ns_max, self.step_ns_last);
            self.step_ns_sum += self.step_ns_last;
            self.step_ns_window += self.step_ns_last;
            self.step_count_window += 1;

            for (self.clients.items) |cl| {
                if (cl.need_baseline) {
                    self.sendBaseline(cl, now_ns);
                } else if (send_snapshot and cl.rep.baseline_acked) {
                    self.sendSnapshot(cl, now_ns);
                }
            }
            self.snapshot_ns_sum += util.now() - t1;
            if (self.replay) |rw| if (self.steps % abi.tick_hz == 0) rw.flush();

            if (self.clients.items.len == 0 and self.playerCount() == 0) {
                if (self.empty_since_ns == null) self.empty_since_ns = now_ns;
            } else self.empty_since_ns = null;
        }

        fn header(self: *Self, cl: *Client, players: *[wire.max_local_players]wire.SnapshotPlayer, now_ns: u64) wire.SnapshotHeader {
            var n: usize = 0;
            for (cl.slots.items) |si| {
                const s = &self.slots[si];
                players[n] = .{ .slot = si, .input_ack = s.input_ack, .slack_q = s.slackMin() };
                n += 1;
            }
            const hold: u64 = if (cl.echo_recv_ns == 0) 0 else (now_ns -| cl.echo_recv_ns) / std.time.ns_per_ms;
            const seq = cl.rep.next_seq;
            cl.rep.next_seq +%= 1;
            return .{ .seq = seq, .tick = self.sim.tick(), .echo_time = cl.echo_time, .hold_ms = @intCast(@min(hold, 0xFFFF)), .players = players[0..n] };
        }

        fn centres(self: *Self, cl: *Client, out: *[wire.max_local_players][2]i32) [][2]i32 {
            var n: usize = 0;
            for (cl.slots.items) |si| {
                if (Rep.playerCentre(self.sim.stateBytes(), si)) |p| {
                    out[n] = p;
                    n += 1;
                }
            }
            return out[0..n];
        }

        fn sendBaseline(self: *Self, cl: *Client, now_ns: u64) void {
            var players: [wire.max_local_players]wire.SnapshotPlayer = undefined;
            var cbuf: [wire.max_local_players][2]i32 = undefined;
            const hdr = self.header(cl, &players, now_ns);
            var w: wire.Writer = .{ .buf = self.scratch };
            const n = cl.rep.build(self.sim.stateBytes(), hdr, self.centres(cl, &cbuf), self.settings.policy, true, self.scratch.len, &w, now_ns) catch |e| {
                log.err("{s}: baseline for client {d} failed: {}", .{ self.name, cl.id, e });
                return;
            };
            cl.need_baseline = false;
            self.sendStream(cl, w.written());
            log.info("{s}: baseline to client {d}: {d} records, {d} bytes", .{ self.name, cl.id, n, w.pos });
        }

        fn sendSnapshot(self: *Self, cl: *Client, now_ns: u64) void {
            var players: [wire.max_local_players]wire.SnapshotPlayer = undefined;
            var cbuf: [wire.max_local_players][2]i32 = undefined;
            var buf: [wire.max_datagram]u8 = undefined;
            const max = @min(buf.len, cl.link.maxDatagram());
            const hdr = self.header(cl, &players, now_ns);
            var w: wire.Writer = .{ .buf = buf[0..max] };
            _ = cl.rep.build(self.sim.stateBytes(), hdr, self.centres(cl, &cbuf), self.settings.policy, false, max, &w, now_ns) catch |e| {
                log.warn("{s}: snapshot for client {d} failed: {}", .{ self.name, cl.id, e });
                return;
            };
            cl.bytes_tx += w.pos;
            cl.link.sendDatagram(w.written());
        }

        // ------------------------------------------------------------------
        // Reliable fan-out

        fn sendStream(self: *Self, cl: *Client, body: []const u8) void {
            _ = self;
            cl.bytes_tx += body.len;
            cl.link.sendStream(body);
        }

        fn sendPlayerInfo(self: *Self, cl: *Client, slot: u8) void {
            const s = &self.slots[slot];
            var buf: [64]u8 = undefined;
            var w: wire.Writer = .{ .buf = &buf };
            const flags: u8 = if (s.state == .free) 0 else wire.PlayerInfo.flag_present;
            (wire.PlayerInfo{ .slot = slot, .flags = flags, .name = s.nameSlice() }).encode(&w) catch return;
            self.sendStream(cl, w.written());
        }

        fn broadcastPlayerInfo(self: *Self, slot: u8, except: ?*Client) void {
            for (self.clients.items) |cl| if (cl != except) self.sendPlayerInfo(cl, slot);
        }

        fn broadcastEvent(self: *Self, ev: wire.Event, except: ?*Client) void {
            var buf: [64]u8 = undefined;
            var w: wire.Writer = .{ .buf = &buf };
            ev.encode(&w) catch return;
            for (self.clients.items) |cl| if (cl != except) self.sendStream(cl, w.written());
        }

        pub fn shutdown(self: *Self) void {
            const msg = [_]u8{ @intFromEnum(wire.Msg.bye), @intFromEnum(wire.ByeReason.shutting_down) };
            for (self.clients.items) |cl| {
                self.sendStream(cl, &msg);
                cl.link.close();
            }
        }

        /// Average step time over the metrics window, then resets it.
        pub const StepStats = struct { avg_ns: u64, max_ns: u64 };
        pub fn takeStepStats(self: *Self) StepStats {
            const avg = if (self.step_count_window == 0) 0 else self.step_ns_window / self.step_count_window;
            const r: StepStats = .{ .avg_ns = avg, .max_ns = self.step_ns_max };
            self.step_ns_window = 0;
            self.step_count_window = 0;
            self.step_ns_max = 0;
            return r;
        }
    };
}
