//! Client side of I3 snapshots: decode records against the per-entity bases
//! the client kept, remember decoded values for the last 64 seqs, track the
//! ack fields, and write records into a sim with `replicaPut`/`replicaRemove`.
//!
//! A snapshot older than the newest one applied is dropped and not acked, so
//! the server never treats a stale create or remove as delivered. A snapshot
//! whose update names a base the client no longer has is dropped and not
//! acked either; the server falls back to an older base or a create.

const std = @import("std");
const itf = @import("interfaces");
const abi = itf.abi;
const wire = itf.wire;
const schema = @import("schema.zig");
const enc = @import("encoder.zig");

pub const history_len = enc.history_len;
pub const max_records = enc.max_records;

pub fn Decoder(comptime S: type) type {
    const Sc = schema.Schema(S);
    const V = Sc.max_value_size;
    return struct {
        const Self = @This();
        pub const Schema = Sc;

        pub const Rec = struct {
            handle: u16,
            op: wire.RecordOp,
            gen: u16,
            kind: u8,
            index: u16,
            /// Mask of components the record carried (not the full value).
            mask: u32,
        };

        const Slot = struct {
            seq: u16 = 0,
            valid: bool = false,
            n: u16 = 0,
        };

        pub const Snapshot = struct {
            header: wire.SnapshotHeader,
            baseline: bool,
            recs: []const Rec,
            /// value of record r is vals[r * V ..][0..value_size]
            vals: []const u8,

            pub fn value(s: *const Snapshot, r: usize) []const u8 {
                return s.vals[r * V ..][0..V];
            }
        };

        slots: [history_len]Slot = @splat(.{}),
        recs: [][max_records]Rec,
        vals: []u8,
        players: [wire.max_local_players]wire.SnapshotPlayer = undefined,
        newest: u16 = 0,
        have_newest: bool = false,
        ack_bits: u32 = 0,
        stats: struct { received: u64 = 0, stale: u64 = 0, missing_base: u64 = 0, bad: u64 = 0 } = .{},

        pub fn init(gpa: std.mem.Allocator) !Self {
            return .{
                .recs = try gpa.alloc([max_records]Rec, history_len),
                .vals = try gpa.alloc(u8, history_len * max_records * V),
            };
        }
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.recs);
            gpa.free(self.vals);
        }

        pub fn reset(self: *Self) void {
            self.slots = @splat(.{});
            self.have_newest = false;
            self.ack_bits = 0;
        }

        /// Ack fields for the next input datagram.
        pub fn ackFields(self: *const Self) struct { ack_seq: u16, ack_bits: u32 } {
            return .{ .ack_seq = self.newest, .ack_bits = self.ack_bits };
        }

        fn seqNewer(a: u16, b: u16) bool {
            return @as(i16, @bitCast(a -% b)) > 0;
        }

        /// Decode one snapshot or baseline body. Returns null for a stale
        /// snapshot (older than or equal to the newest), or an error for a
        /// malformed one or one with a missing base; neither is acked.
        pub fn decode(self: *Self, bytes: []const u8) !?Snapshot {
            var r: wire.Reader = .{ .buf = bytes };
            const hd = try wire.SnapshotHeader.decode(&r, &self.players);
            const seq = hd.header.seq;
            if (hd.baseline) self.reset();
            if (self.have_newest and !seqNewer(seq, self.newest)) {
                self.stats.stale += 1;
                return null;
            }
            const si = seq % history_len;
            const sl = &self.slots[si];
            sl.* = .{ .seq = seq, .valid = false, .n = 0 };
            const recs = &self.recs[si];
            const vals = self.vals[si * max_records * V ..][0 .. max_records * V];

            var prev: ?u16 = null;
            var zero: [V]u8 = @splat(0);
            while (!r.done()) {
                if (sl.n == max_records) return error.BadMessage;
                const h = try wire.decodeRecordHeader(&r, prev);
                prev = h.handle;
                const kind: u4 = @truncate(h.handle >> 12);
                const index: u16 = h.handle & 0xFFF;
                const k = Sc.kindIndex(kind) orelse return error.BadMessage;
                if (index >= Sc.desc[k].capacity) return error.BadMessage;
                const out = vals[@as(usize, sl.n) * V ..][0..V];
                var gen: u16 = h.generation;
                switch (h.op) {
                    .create => try Sc.decodePayload(k, &r, h.mask, &zero, out),
                    .update => {
                        const base_seq = seq -% @as(u16, h.base_age);
                        const b = self.find(base_seq, h.handle) orelse {
                            self.stats.missing_base += 1;
                            return error.MissingBase;
                        };
                        gen = b.gen;
                        try Sc.decodePayload(k, &r, h.mask, b.val, out);
                    },
                    .remove => {},
                    _ => return error.BadMessage,
                }
                recs[sl.n] = .{ .handle = h.handle, .op = h.op, .gen = gen, .kind = @intCast(k), .index = index, .mask = h.mask };
                sl.n += 1;
            }
            sl.valid = true;

            // Ack bookkeeping.
            if (!self.have_newest) {
                self.newest = seq;
                self.ack_bits = 1;
                self.have_newest = true;
            } else {
                const shift = seq -% self.newest;
                self.ack_bits = if (shift >= 32) 1 else (self.ack_bits << @intCast(shift)) | 1;
                self.newest = seq;
            }
            self.stats.received += 1;
            return .{ .header = hd.header, .baseline = hd.baseline, .recs = recs[0..sl.n], .vals = vals };
        }

        fn find(self: *Self, seq: u16, handle: u16) ?struct { gen: u16, val: []const u8 } {
            const si = seq % history_len;
            const sl = &self.slots[si];
            if (!sl.valid or sl.seq != seq) return null;
            const recs = self.recs[si][0..sl.n];
            // Records are sorted by handle.
            var lo: usize = 0;
            var hi: usize = recs.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (recs[mid].handle < handle) lo = mid + 1 else hi = mid;
            }
            if (lo == recs.len or recs[lo].handle != handle or recs[lo].op == .remove) return null;
            return .{ .gen = recs[lo].gen, .val = self.vals[si * max_records * V + lo * V ..][0..V] };
        }

        /// Write a decoded snapshot into a sim (whose state the caller has
        /// rewound to the snapshot's tick). Calls `visit(ctx, k, i, op)` for
        /// each record after it is applied.
        pub fn apply(snap: *const Snapshot, sim: *S, ctx: anytype, comptime visit: ?fn (@TypeOf(ctx), usize, u32, wire.RecordOp) void) void {
            for (snap.recs, 0..) |rec, ri| {
                const k: usize = rec.kind;
                const i: u32 = rec.index;
                if (k == Sc.player_kind) {
                    const row = sim.playerRow(i);
                    switch (rec.op) {
                        .remove => row.* = .{ .ped = .none, .car = .none, .kills = 0, .deaths = 0, .score = 0, .respawn_timer = 0, .flags = 0 },
                        else => row.* = schema.readAt(abi.PlayerRow, snap.value(ri), 0),
                    }
                } else {
                    const state: []u8 = @constCast(sim.stateBytes());
                    switch (rec.op) {
                        .remove => sim.replicaRemove(Sc.entityId(state, k, i)),
                        else => {
                            const id: abi.EntityId = .{ .raw = i | (@as(u32, Sc.desc[k].kind) << 12) | (@as(u32, rec.gen) << 16) };
                            if (!sim.replicaPut(id)) continue;
                            Sc.writeValue(@constCast(sim.stateBytes()), k, i, snap.value(ri));
                        },
                    }
                }
                if (visit) |v| v(ctx, k, i, rec.op);
            }
        }
    };
}
