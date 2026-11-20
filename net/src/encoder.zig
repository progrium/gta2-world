//! Server side of I3 snapshots: per-client delta encoding against per-entity
//! acknowledged bases, filled by priority up to a byte budget.
//!
//! `History` is shared by every client of a session: the server's state bytes
//! at each of the last 64 snapshot points. A base value is read straight out
//! of the state the client acknowledged, so the encoder keeps no per-client
//! copies of values, only a few bytes of bookkeeping per entity.
//!
//! `ClientEncoder` is one per connection. Reliability rules (I3):
//! - a `create` is resent until a snapshot containing it is acked;
//! - a `remove` is resent until a snapshot containing it is acked;
//! - an update names the newest acked snapshot that held the entity as its
//!   base (`base_age`); with no base younger than 63 seqs it becomes a create.

const std = @import("std");
const itf = @import("interfaces");
const abi = itf.abi;
const wire = itf.wire;
const schema = @import("schema.zig");

pub const history_len = 64;
/// Most records one snapshot can hold (1100 bytes, 3 bytes per remove).
pub const max_records = 400;

pub fn History(comptime S: type) type {
    return struct {
        const Self = @This();
        states: []u8,
        /// Global snapshot number held in each ring slot.
        g_of: [history_len]u32 = @splat(0xFFFF_FFFF),
        tick_of: [history_len]u32 = @splat(0),
        next_g: u32 = 0,

        pub fn init(gpa: std.mem.Allocator) !Self {
            return .{ .states = try gpa.alloc(u8, history_len * S.state_size) };
        }
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.states);
        }

        /// Record the current server state as the next snapshot point.
        /// Returns its global number.
        pub fn push(self: *Self, sim: *const S) u32 {
            const g = self.next_g;
            const slot = g % history_len;
            _ = sim.save(self.states[slot * S.state_size ..][0..S.state_size]);
            self.g_of[slot] = g;
            self.tick_of[slot] = sim.tick();
            self.next_g += 1;
            return g;
        }

        pub fn get(self: *const Self, g: u32) ?[]const u8 {
            const slot = g % history_len;
            if (self.g_of[slot] != g) return null;
            return self.states[slot * S.state_size ..][0..S.state_size];
        }
    };
}

pub const Options = struct {
    /// Bytes per snapshot, on average. 64 kbit/s at 20 Hz (M2 bot soak, soak-results.md).
    budget: u32 = 400,
    /// Unused budget carries over, up to this many snapshots' worth.
    carry: u32 = 2,
    /// Interest radius in blocks; entities beyond it are removed. Larger
    /// leave radius gives hysteresis.
    interest_enter: abi.Fx = 28 * abi.fx_one,
    interest_leave: abi.Fx = 32 * abi.fx_one,
};

pub const Stats = struct {
    snapshots: u64 = 0,
    bytes: u64 = 0,
    records: u64 = 0,
    creates: u64 = 0,
    updates: u64 = 0,
    removes: u64 = 0,
    /// Candidates that wanted to go out but did not fit the budget.
    deferred: u64 = 0,
    /// Sum over snapshots of the age (in snapshots) of the stalest pending
    /// update; a measure of how starved the budget is.
    staleness_sum: u64 = 0,
    max_bytes: u32 = 0,
};

pub fn ClientEncoder(comptime S: type) type {
    const Sc = schema.Schema(S);
    const N = Sc.total;
    return struct {
        const Self = @This();
        pub const Schema = Sc;

        const Status = enum(u8) { absent, creating, known, removing };
        const Ent = struct {
            status: Status = .absent,
            has_base: bool = false,
            gen: u16 = 0,
            base_seq: u16 = 0,
            /// snapshots since this entity last went out while it had changes
            waiting: u16 = 0,
            prio: u32 = 0,
        };
        const Rec = struct { flat: u16, op: wire.RecordOp, gen: u16 };
        const Sent = struct {
            seq: u16 = 0,
            g: u32 = 0,
            valid: bool = false,
            acked: bool = false,
            n: u16 = 0,
        };
        const Cand = struct {
            flat: u16,
            op: wire.RecordOp,
            size: u16,
            prio: u64,
        };

        opts: Options,
        ents: []Ent,
        sent: [history_len]Sent = @splat(.{}),
        recs: [][max_records]Rec,
        cands: []Cand,
        chosen: []Cand,
        next_seq: u16 = 1,
        credit: u32,
        /// Player slots this connection owns (always sent first).
        own_slots: [wire.max_local_players]u8 = @splat(0xFF),
        stats: Stats = .{},
        scratch_val: [Sc.max_value_size]u8 = undefined,
        scratch_base: [Sc.max_value_size]u8 = undefined,

        pub fn init(gpa: std.mem.Allocator, opts: Options) !Self {
            const ents = try gpa.alloc(Ent, N);
            @memset(ents, .{});
            return .{
                .opts = opts,
                .ents = ents,
                .recs = try gpa.alloc([max_records]Rec, history_len),
                .cands = try gpa.alloc(Cand, N),
                .chosen = try gpa.alloc(Cand, N),
                .credit = opts.budget,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.ents);
            gpa.free(self.recs);
            gpa.free(self.cands);
            gpa.free(self.chosen);
        }

        /// Process the ack fields of an input datagram.
        pub fn ack(self: *Self, ack_seq: u16, ack_bits: u32) void {
            var b = ack_bits;
            var i: u16 = 0;
            while (b != 0) : (i += 1) {
                if (b & 1 != 0) self.ackOne(ack_seq -% i);
                b >>= 1;
            }
        }

        fn ackOne(self: *Self, seq: u16) void {
            const sl = &self.sent[seq % history_len];
            if (!sl.valid or sl.seq != seq or sl.acked) return;
            sl.acked = true;
            for (self.recs[seq % history_len][0..sl.n]) |r| {
                const e = &self.ents[r.flat];
                switch (r.op) {
                    .create, .update => {
                        if (e.gen != r.gen) continue;
                        if (e.status != .creating and e.status != .known) continue;
                        e.status = .known;
                        // Newer base only (serial-number compare).
                        if (!e.has_base or seqNewer(seq, e.base_seq)) {
                            e.base_seq = seq;
                            e.has_base = true;
                        }
                    },
                    .remove => if (e.status == .removing) {
                        e.status = .absent;
                        e.has_base = false;
                    },
                    _ => {},
                }
            }
        }

        fn seqNewer(a: u16, b: u16) bool {
            return @as(i16, @bitCast(a -% b)) > 0;
        }

        /// Encode the next snapshot for this client into `out` from the
        /// server state at history point `g`. `center` is the client's
        /// point of interest (its player's position). Returns the bytes.
        pub fn encode(
            self: *Self,
            hist: anytype,
            g: u32,
            header: wire.SnapshotHeader,
            interest: ?schema.Pos,
            out: []u8,
            as_baseline: bool,
        ) ![]const u8 {
            const state = hist.get(g) orelse return error.NoState;
            var h = header;
            h.seq = self.next_seq;
            const seq = self.next_seq;

            // Budget for this snapshot.
            const limit: usize = if (as_baseline) out.len else @min(@min(self.credit, out.len), wire.max_datagram);

            var w: wire.Writer = .{ .buf = out[0..limit] };
            try h.encode(&w, as_baseline);
            const header_len = w.pos;

            // 1. Gather candidates.
            var nc: usize = 0;
            var stalest: u16 = 0;
            for (0..Sc.num_kinds) |k| {
                const cap = Sc.desc[k].capacity;
                var i: u32 = 0;
                while (i < cap) : (i += 1) {
                    const f = Sc.flat(k, i);
                    const e = &self.ents[f];
                    const alive = Sc.alive(state, k, i);
                    const g_now = Sc.gen(state, k, i);
                    const own = self.isOwn(state, k, i);
                    var want = alive;
                    var dist: abi.Fx = 0;
                    if (want and !own and k != Sc.player_kind) {
                        if (interest) |c| if (Sc.transform(state, k, i)) |t| {
                            dist = chebyshev(t.x - c.x, t.y - c.y);
                            const r = if (e.status == .known or e.status == .creating) self.opts.interest_leave else self.opts.interest_enter;
                            if (dist > r) want = false;
                        };
                    }
                    if (want) {
                        if (e.status == .absent or e.status == .removing or e.gen != g_now) {
                            e.status = .creating;
                            e.gen = g_now;
                            e.has_base = false;
                        }
                        if (e.status == .known and (!e.has_base or self.baseAge(seq, e.base_seq) > wire.max_base_age or hist.get(self.sent[e.base_seq % history_len].g) == null)) {
                            e.status = .creating;
                            e.has_base = false;
                        }
                        Sc.readValue(state, k, i, &self.scratch_val);
                        var op: wire.RecordOp = .create;
                        var mask: u32 = 0;
                        if (e.status == .known) {
                            const base = hist.get(self.sent[e.base_seq % history_len].g).?;
                            Sc.readValue(base, k, i, &self.scratch_base);
                            mask = Sc.diffMask(k, &self.scratch_base, &self.scratch_val);
                            if (mask == 0) {
                                e.waiting = 0;
                                continue;
                            }
                            op = .update;
                        } else {
                            @memset(self.scratch_base[0..Sc.desc[k].value_size], 0);
                            mask = Sc.diffMask(k, &self.scratch_base, &self.scratch_val);
                        }
                        // Exact payload size.
                        var tmp: [1100]u8 = undefined;
                        var tw: wire.Writer = .{ .buf = &tmp };
                        Sc.encodePayload(k, &tw, mask, &self.scratch_base, &self.scratch_val) catch continue;
                        const hdr: usize = 3 + 1 + (if (op == .create) @as(usize, 2) else 0) + varintLen(mask);
                        const size: usize = hdr + tw.pos;
                        if (op == .update) {
                            e.waiting +|= 1;
                            stalest = @max(stalest, e.waiting);
                        }
                        e.prio +|= self.weight(state, k, i, dist, own);
                        const p: u64 = if (own) std.math.maxInt(u64) else if (op == .create) (@as(u64, 1) << 40) - @as(u64, @intCast(dist)) else e.prio;
                        self.cands[nc] = .{ .flat = @intCast(f), .op = op, .size = @intCast(size), .prio = p };
                        nc += 1;
                    } else {
                        if (e.status == .creating or e.status == .known) e.status = .removing;
                        if (e.status == .removing) {
                            self.cands[nc] = .{ .flat = @intCast(f), .op = .remove, .size = 3 + 1, .prio = (@as(u64, 1) << 41) };
                            nc += 1;
                        }
                    }
                }
            }

            // 2. Choose by priority within the budget.
            std.sort.pdq(Cand, self.cands[0..nc], {}, struct {
                fn lt(_: void, a: Cand, b: Cand) bool {
                    return a.prio > b.prio;
                }
            }.lt);
            var room: usize = limit - header_len;
            var nch: usize = 0;
            var skipped: usize = 0;
            for (self.cands[0..nc]) |c| {
                if (c.size <= room and nch < max_records) {
                    room -= c.size;
                    self.chosen[nch] = c;
                    nch += 1;
                } else {
                    skipped += 1;
                    if (room < 4) {
                        skipped += 0;
                    }
                }
            }
            self.stats.deferred += skipped;

            // 3. Encode in ascending handle order.
            std.sort.pdq(Cand, self.chosen[0..nch], {}, struct {
                fn lt(_: void, a: Cand, b: Cand) bool {
                    return Sc.handleOfFlat(a.flat) < Sc.handleOfFlat(b.flat);
                }
            }.lt);
            const sl = &self.sent[seq % history_len];
            sl.* = .{ .seq = seq, .g = g, .valid = true, .acked = false, .n = 0 };
            const recs = &self.recs[seq % history_len];
            var prev: ?u16 = null;
            for (self.chosen[0..nch]) |c| {
                const ef = Sc.fromFlat(c.flat);
                const e = &self.ents[c.flat];
                const hnd = Sc.handleOfFlat(c.flat);
                switch (c.op) {
                    .remove => {
                        try wire.encodeRecordHeader(&w, prev, .{ .handle = hnd, .op = .remove });
                        self.stats.removes += 1;
                    },
                    .create, .update => {
                        Sc.readValue(state, ef.k, ef.i, &self.scratch_val);
                        var age: u6 = 0;
                        if (c.op == .update) {
                            const base = hist.get(self.sent[e.base_seq % history_len].g).?;
                            Sc.readValue(base, ef.k, ef.i, &self.scratch_base);
                            age = @intCast(self.baseAge(seq, e.base_seq));
                            self.stats.updates += 1;
                        } else {
                            @memset(self.scratch_base[0..Sc.desc[ef.k].value_size], 0);
                            self.stats.creates += 1;
                        }
                        const mask = Sc.diffMask(ef.k, &self.scratch_base, &self.scratch_val);
                        try wire.encodeRecordHeader(&w, prev, .{ .handle = hnd, .op = c.op, .base_age = age, .generation = e.gen, .mask = mask });
                        try Sc.encodePayload(ef.k, &w, mask, &self.scratch_base, &self.scratch_val);
                        e.prio = 0;
                        e.waiting = 0;
                    },
                    _ => unreachable,
                }
                recs[sl.n] = .{ .flat = c.flat, .op = c.op, .gen = e.gen };
                sl.n += 1;
                prev = hnd;
            }

            self.next_seq +%= 1;
            if (self.next_seq == 0) self.next_seq = 1;
            if (!as_baseline) {
                self.credit = @min(self.credit - @as(u32, @intCast(w.pos)) + self.opts.budget, self.opts.budget * (1 + self.opts.carry));
                self.credit = @max(self.credit, 64);
            }
            self.stats.snapshots += 1;
            self.stats.bytes += w.pos;
            self.stats.records += nch;
            self.stats.staleness_sum += stalest;
            if (!as_baseline) self.stats.max_bytes = @max(self.stats.max_bytes, @as(u32, @intCast(w.pos)));
            return w.written();
        }

        fn baseAge(_: *const Self, seq: u16, base_seq: u16) u16 {
            return seq -% base_seq;
        }

        fn isOwn(self: *const Self, state: []const u8, k: usize, i: u32) bool {
            if (k == Sc.player_kind) {
                for (self.own_slots) |s| if (s == i) return true;
                return false;
            }
            const id = Sc.entityId(state, k, i);
            for (self.own_slots) |s| {
                if (s == 0xFF) continue;
                const row = playerRowAt(state, s);
                if (row.ped.raw == id.raw or row.car.raw == id.raw) return true;
            }
            return false;
        }

        fn playerRowAt(state: []const u8, slot: u32) abi.PlayerRow {
            return schema.readAt(abi.PlayerRow, state, Sc.desc[Sc.player_kind].col_off[0] + slot * @sizeOf(abi.PlayerRow));
        }

        /// Position of this client's first own player's entity.
        pub fn center(self: *const Self, state: []const u8) ?schema.Pos {
            for (self.own_slots) |s| {
                if (s == 0xFF) continue;
                const row = playerRowAt(state, s);
                const id = if (!row.car.isNone()) row.car else row.ped;
                if (id.isNone()) continue;
                const k = Sc.kindIndex(id.kind()) orelse continue;
                if (Sc.transform(state, k, id.index())) |t| return .{ .x = t.x, .y = t.y };
            }
            return null;
        }

        /// Priority gained per snapshot while an entity has unsent changes:
        /// near and fast entities go out every time, distant slow ones less.
        fn weight(_: *const Self, state: []const u8, k: usize, i: u32, dist: abi.Fx, own: bool) u32 {
            if (own) return 1 << 20;
            if (k == Sc.player_kind) return 64;
            // Falls off with the square of distance: within the client's
            // predict radius (~6 blocks) an entity outweighs one at the edge
            // of interest by about 25x, so near cars go out nearly every time.
            const d: u32 = @intCast(@max(dist, 0) >> 14); // quarter blocks
            var w: u32 = 4096 / (4 + d * d / 64);
            // Slow or parked things change little; halve them.
            if (Sc.velocity(state, k, i)) |v| {
                const sp = @max(@abs(v.vx), @abs(v.vy));
                if (sp < 1024) w /= 2;
            }
            return @max(w, 4);
        }
    };
}

fn chebyshev(dx: abi.Fx, dy: abi.Fx) abi.Fx {
    return @intCast(@max(@abs(@as(i64, dx)), @abs(@as(i64, dy))));
}

fn varintLen(v: u64) usize {
    var n: usize = 1;
    var x = v >> 7;
    while (x != 0) : (x >>= 7) n += 1;
    return n;
}
