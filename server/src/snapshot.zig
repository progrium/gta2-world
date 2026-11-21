//! Snapshot encoding (I3 "Snapshot datagram" and "baseline").
//!
//! Server policy, not wire format, lives here: which entities a client is
//! sent (interest), in what order (priority) and how many (byte budget).
//! The wire format itself (record headers, component deltas) comes from
//! interfaces/zig/src/wire.zig.
//!
//! What gets replicated is read from the sim's I1 `views()` table at
//! comptime, so this file works unchanged with `abi.Stub` and with `sim/`:
//!
//! - every kind with a `slot` and `generation` column is an entity table;
//! - its replicated components are the ones the sim lists in
//!   `pub const replicated = .{ .{ abi.Kind.car, .{ Transform, ... } }, ... }`
//!   (sim/ does), or else every component column of the kind minus
//!   `Predicted` (client-owned); always in ascending ComponentId order;
//! - player rows are kind 15 with one component, the `PlayerRow`.
//!
//! Component codecs are `wire.encodeComponent` on the component's type. The
//! frozen types are known from abi; sim-owned ones (Collider, Vehicle, ...)
//! are found in the sim's `replicated` list by their `id`. Without one, the
//! column is sent as a run of 32-bit words, which matches the I3 codec only
//! for components made of 32-bit fields; `fallback_columns` counts those.
//!
//! Per-entity bases follow I3: each client has its own table of what it has
//! acked. Creates and removes are resent until a snapshot containing them
//! is acked; updates name the newest acked snapshot holding the entity.

const std = @import("std");
const ifc = @import("interfaces");
const abi = ifc.abi;
const wire = ifc.wire;
const Special = abi.ColumnDesc.Special;

pub const history_len = 64;

pub const Policy = struct {
    /// Bytes per snapshot datagram, I3 payload. 64 kbit/s at 20 Hz (M2 bot soak, net/soak-results.md).
    budget: usize = 400,
    /// Entities farther than this (blocks, Chebyshev) from every one of the
    /// client's players are not sent. 0 = no interest filter.
    interest_radius: i32 = 40,
    /// Re-send an unchanged entity once its base is this many seqs old, so
    /// the base never ages past 63 and turns into a create.
    refresh_age: u16 = 40,
};

pub const Col = struct {
    id: u16,
    offset: u32,
    stride: u32,
};

pub const KindInfo = struct {
    kind: u4,
    count: u32,
    slot_off: u32,
    gen_off: u32,
    comps: []const Col,
    /// Index in comps of Transform, if replicated.
    transform: ?usize,
    /// First global entity index of this kind.
    base: u32,
    /// Bytes of one entity's replicated value (sum of strides).
    value_size: u32,
    is_player_rows: bool,
};

pub fn Replicator(comptime Sim: type) type {
    return struct {
        const R = @This();

        pub const kinds: []const KindInfo = buildKinds();
        pub const total_entities: u32 = blk: {
            var n: u32 = 0;
            for (kinds) |k| n += k.count;
            break :blk n;
        };
        pub const value_bytes: u32 = blk: {
            var n: u32 = 0;
            for (kinds) |k| n += k.count * k.value_size;
            break :blk n;
        };
        /// Columns sent with the 32-bit-word fallback codec (see top).
        pub const fallback_columns: u32 = blk: {
            var n: u32 = 0;
            for (kinds) |k| for (k.comps) |cl| {
                if (CompType(cl.id) == void) n += 1;
            };
            break :blk n;
        };

        fn buildKinds() []const KindInfo {
            @setEvalBranchQuota(100_000);
            const views = Sim.views();
            var out: [17]KindInfo = undefined;
            var n: usize = 0;
            var base: u32 = 0;
            for (0..15) |kk| {
                const k: u8 = @intCast(kk);
                var slot_off: ?u32 = null;
                var gen_off: u32 = 0;
                var count: u32 = 0;
                var comps: [16]Col = undefined;
                var nc: usize = 0;
                for (views) |v| {
                    if (v.kind != k) continue;
                    if (v.component == Special.slot) {
                        slot_off = v.offset;
                        count = v.count;
                    } else if (v.component == Special.generation) {
                        gen_off = v.offset;
                    } else if (v.component < 0x100 and v.component != @intFromEnum(abi.ComponentId.predicted)) {
                        if (@hasDecl(Sim, "replicated") and !simReplicates(k, v.component)) continue;
                        comps[nc] = .{ .id = v.component, .offset = v.offset, .stride = v.stride };
                        nc += 1;
                    }
                }
                if (slot_off == null or count == 0) continue;
                // ascending ComponentId
                std.mem.sort(Col, comps[0..nc], {}, struct {
                    fn lt(_: void, a: Col, b: Col) bool {
                        return a.id < b.id;
                    }
                }.lt);
                const final = comps[0..nc].*;
                var tr: ?usize = null;
                var vs: u32 = 0;
                for (final, 0..) |cl, i| {
                    if (cl.id == @intFromEnum(abi.ComponentId.transform)) tr = i;
                    vs += cl.stride;
                    const T = CompType(cl.id);
                    if (T != void and @sizeOf(T) != cl.stride) @compileError("component size differs from view stride");
                    if (cl.stride % 4 != 0) @compileError("component stride must be a multiple of 4");
                }
                out[n] = .{ .kind = @intCast(k), .count = count, .slot_off = slot_off.?, .gen_off = gen_off, .comps = &final, .transform = tr, .base = base, .value_size = vs, .is_player_rows = false };
                base += count;
                n += 1;
            }
            for (views) |v| {
                if (v.component != Special.player_rows) continue;
                const pr = [_]Col{.{ .id = 0xFFFF, .offset = v.offset, .stride = v.stride }};
                out[n] = .{ .kind = 15, .count = v.count, .slot_off = 0, .gen_off = 0, .comps = &pr, .transform = null, .base = base, .value_size = v.stride, .is_player_rows = true };
                base += v.count;
                n += 1;
            }
            const res = out[0..n].*;
            return &res;
        }

        fn simReplicates(comptime k: u8, comptime id: u16) bool {
            for (Sim.replicated) |entry| {
                if (@intFromEnum(entry[0]) != k) continue;
                for (entry[1]) |T| {
                    if (@intFromEnum(T.id) == id) return true;
                }
            }
            return false;
        }

        fn simType(comptime id: u16) type {
            if (@hasDecl(Sim, "replicated")) {
                for (Sim.replicated) |entry| for (entry[1]) |T| {
                    if (@intFromEnum(T.id) == id) return T;
                };
            }
            if (@hasDecl(Sim, "ComponentType")) return Sim.ComponentType(@enumFromInt(id));
            return void;
        }

        pub fn CompType(comptime id: u16) type {
            return switch (id) {
                0xFFFF => abi.PlayerRow,
                @intFromEnum(abi.ComponentId.transform) => abi.Transform,
                @intFromEnum(abi.ComponentId.velocity) => abi.Velocity,
                @intFromEnum(abi.ComponentId.health) => abi.Health,
                @intFromEnum(abi.ComponentId.controller) => abi.Controller,
                @intFromEnum(abi.ComponentId.riding) => abi.Riding,
                @intFromEnum(abi.ComponentId.predicted) => abi.Predicted,
                else => simType(id),
            };
        }

        fn encodeComp(comptime cl: Col, w: *wire.Writer, base: []const u8, val: []const u8) wire.Error!void {
            const T = CompType(cl.id);
            if (T == void) {
                var i: usize = 0;
                while (i < cl.stride) : (i += 4) {
                    const b = std.mem.readInt(u32, base[i..][0..4], .little);
                    const v = std.mem.readInt(u32, val[i..][0..4], .little);
                    try w.svarint(@as(i32, @bitCast(v -% b)));
                }
            } else {
                const b = std.mem.bytesToValue(T, base[0..@sizeOf(T)]);
                const v = std.mem.bytesToValue(T, val[0..@sizeOf(T)]);
                try wire.encodeComponent(T, w, &b, &v);
            }
        }

        // ------------------------------------------------------------------
        // Reading the live state

        pub fn alive(state: []const u8, comptime k: KindInfo, idx: u32) bool {
            if (k.is_player_rows) {
                const row = std.mem.bytesToValue(abi.PlayerRow, state[k.comps[0].offset + idx * k.comps[0].stride ..][0..@sizeOf(abi.PlayerRow)]);
                return row.flags & abi.PlayerRow.flag_active != 0;
            }
            return state[k.slot_off + idx] == abi.Slot.alive;
        }

        pub fn genOf(state: []const u8, comptime k: KindInfo, idx: u32) u16 {
            if (k.is_player_rows) return 0;
            return std.mem.readInt(u16, state[k.gen_off + idx * 2 ..][0..2], .little);
        }

        pub fn compBytes(state: []const u8, comptime cl: Col, idx: u32) []const u8 {
            return state[cl.offset + idx * cl.stride ..][0..cl.stride];
        }

        pub fn position(state: []const u8, comptime k: KindInfo, idx: u32) ?[2]i32 {
            const ti = k.transform orelse return null;
            const t = std.mem.bytesToValue(abi.Transform, compBytes(state, k.comps[ti], idx)[0..@sizeOf(abi.Transform)]);
            return .{ t.x >> abi.fx_frac_bits, t.y >> abi.fx_frac_bits };
        }

        /// Where a player's view is centred: their car if riding, else ped.
        pub fn playerCentre(state: []const u8, slot: u32) ?[2]i32 {
            inline for (kinds) |k| {
                if (k.is_player_rows) {
                    if (slot >= k.count) return null;
                    const row = std.mem.bytesToValue(abi.PlayerRow, state[k.comps[0].offset + slot * k.comps[0].stride ..][0..@sizeOf(abi.PlayerRow)]);
                    if (row.flags & abi.PlayerRow.flag_active == 0) return null;
                    const id = if (!row.car.isNone()) row.car else row.ped;
                    if (id.isNone()) return null;
                    return entityPos(state, id);
                }
            }
            return null;
        }

        fn entityPos(state: []const u8, id: abi.EntityId) ?[2]i32 {
            inline for (kinds) |k| {
                if (!k.is_player_rows and k.kind == id.kind() and id.index() < k.count) {
                    return position(state, k, id.index());
                }
            }
            return null;
        }

        // ------------------------------------------------------------------
        // Per-client replication state

        pub const EntState = enum(u8) { none, creating, known, removing };

        pub const Ent = struct {
            state: EntState = .none,
            gen: u16 = 0,
            base_seq: u16 = 0,
            last_sent_seq: u16 = 0,
        };

        const Rec = struct { g: u32, op: wire.RecordOp, gen: u16, val_off: u32 };

        const Hist = struct {
            seq: u16 = 0,
            valid: bool = false,
            acked: bool = false,
            sent_ns: u64 = 0,
            recs: std.ArrayList(Rec) = .empty,
            vals: std.ArrayList(u8) = .empty,
        };

        pub const Stats = struct {
            snapshots: u64 = 0,
            acked: u64 = 0,
            /// History entries overwritten without an ack: downlink loss.
            lost: u64 = 0,
            bytes: u64 = 0,
            records: u64 = 0,
            /// Candidates that did not fit the budget.
            deferred: u64 = 0,
            last_rtt_ns: u64 = 0,
        };

        pub const Client = struct {
            gpa: std.mem.Allocator,
            ents: []Ent,
            /// Acked base value per entity, `value_size` bytes each.
            bases: []u8,
            hist: [history_len]Hist = @splat(.{}),
            next_seq: u16 = 0,
            baseline_seq: ?u16 = null,
            baseline_acked: bool = false,
            stats: Stats = .{},
            // scratch
            cands: std.ArrayList(Cand) = .empty,
            tmp: std.ArrayList(u8) = .empty,

            pub fn init(gpa: std.mem.Allocator) !Client {
                const ents = try gpa.alloc(Ent, total_entities);
                @memset(ents, .{});
                const bases = try gpa.alloc(u8, value_bytes);
                @memset(bases, 0);
                return .{ .gpa = gpa, .ents = ents, .bases = bases };
            }

            pub fn deinit(c: *Client) void {
                for (&c.hist) |*h| {
                    h.recs.deinit(c.gpa);
                    h.vals.deinit(c.gpa);
                }
                c.cands.deinit(c.gpa);
                c.tmp.deinit(c.gpa);
                c.gpa.free(c.ents);
                c.gpa.free(c.bases);
            }

            fn baseOf(c: *Client, comptime k: KindInfo, idx: u32) []u8 {
                return c.bases[baseOffset(k) + idx * k.value_size ..][0..k.value_size];
            }

            /// Applies an input datagram's ack fields. Returns how many
            /// snapshots were newly acked.
            pub fn onAck(c: *Client, ack_seq: u16, ack_bits: u32, now_ns: u64) u32 {
                var n: u32 = 0;
                var i: u5 = 0;
                while (true) : (i += 1) {
                    if (ack_bits & (@as(u32, 1) << i) != 0) {
                        const s = ack_seq -% i;
                        const h = &c.hist[s % history_len];
                        if (h.valid and h.seq == s and !h.acked) {
                            h.acked = true;
                            n += 1;
                            c.stats.acked += 1;
                            if (i == 0 and now_ns > h.sent_ns) c.stats.last_rtt_ns = now_ns - h.sent_ns;
                            c.applyAck(h);
                            if (c.baseline_seq) |b| if (b == s) {
                                c.baseline_acked = true;
                            };
                        }
                    }
                    if (i == 31) break;
                }
                return n;
            }

            fn applyAck(c: *Client, h: *Hist) void {
                for (h.recs.items) |r| {
                    const e = &c.ents[r.g];
                    switch (r.op) {
                        .create, .update => {
                            if (e.gen != r.gen) continue;
                            if (e.state == .creating or (e.state == .known and seqNewer(h.seq, e.base_seq))) {
                                e.state = .known;
                                e.base_seq = h.seq;
                                const vs = valueSizeOfGlobal(r.g);
                                @memcpy(c.bases[baseOffsetOfGlobal(r.g)..][0..vs], h.vals.items[r.val_off..][0..vs]);
                            }
                        },
                        .remove => if (e.state == .removing) {
                            e.state = .none;
                        },
                        _ => {},
                    }
                }
            }

            const Cand = struct {
                g: u32,
                kind_i: u8,
                idx: u32,
                handle: u16,
                op: wire.RecordOp,
                gen: u16,
                mask: u32,
                base_age: u6,
                score: u32,
                est: u32,
            };

            pub const Centres = []const [2]i32;

            /// Writes one snapshot (or the baseline) for this client into
            /// `w`, after `hdr`. Returns the record count.
            pub fn build(
                c: *Client,
                state: []const u8,
                hdr: wire.SnapshotHeader,
                centres: Centres,
                policy: Policy,
                baseline: bool,
                max_bytes: usize,
                w: *wire.Writer,
                now_ns: u64,
            ) !u32 {
                const seq = hdr.seq;
                const h = &c.hist[seq % history_len];
                if (h.valid and !h.acked) c.stats.lost += 1;
                h.valid = true;
                h.acked = false;
                h.seq = seq;
                h.sent_ns = now_ns;
                h.recs.clearRetainingCapacity();
                h.vals.clearRetainingCapacity();
                if (baseline) c.baseline_seq = seq;

                try hdr.encode(w, baseline);
                const budget = if (baseline) max_bytes else @min(policy.budget, max_bytes);

                // 1. candidates
                c.cands.clearRetainingCapacity();
                inline for (kinds, 0..) |k, ki| {
                    var idx: u32 = 0;
                    while (idx < k.count) : (idx += 1) {
                        const g = k.base + idx;
                        const e = &c.ents[g];
                        const live = alive(state, k, idx);
                        const gen = genOf(state, k, idx);
                        var dist: i32 = 0;
                        var in_interest = live;
                        if (live and policy.interest_radius > 0 and centres.len > 0) {
                            if (position(state, k, idx)) |p| {
                                dist = std.math.maxInt(i32);
                                for (centres) |cc| dist = @min(dist, @max(@abs(p[0] - cc[0]), @abs(p[1] - cc[1])));
                                in_interest = dist <= policy.interest_radius;
                            }
                        }
                        const handle: u16 = @intCast((@as(u32, k.kind) << 12) | idx);
                        const stale: u32 = seq -% e.last_sent_seq;
                        const near: u32 = @intCast(@min(@max(dist, 0), 1000));
                        if (in_interest) {
                            var op: wire.RecordOp = .create;
                            var mask: u32 = 0;
                            var age: u16 = 0;
                            if (e.state == .known and e.gen == gen) {
                                age = seq -% e.base_seq;
                                const base = c.baseOf(k, idx);
                                var off: u32 = 0;
                                inline for (k.comps, 0..) |cl, bi| {
                                    if (!std.mem.eql(u8, base[off..][0..cl.stride], compBytes(state, cl, idx))) mask |= @as(u32, 1) << bi;
                                    off += cl.stride;
                                }
                                if (age >= 1 and age <= wire.max_base_age) {
                                    op = .update;
                                } else mask = allMask(k);
                                // Unchanged since the acked base and nothing newer in
                                // flight (the client may hold an unacked newer value,
                                // which would otherwise stick): nothing to send.
                                if (op == .update and mask == 0 and age < policy.refresh_age and !seqNewer(e.last_sent_seq, e.base_seq)) {
                                } else try c.cands.append(c.gpa, .{
                                    .g = g, .kind_i = ki, .idx = idx, .handle = handle, .op = op, .gen = gen, .mask = mask,
                                    .base_age = if (op == .update) @intCast(age) else 0,
                                    .score = if (op == .create) 0xF000_0000 - near else (stale + 1) * 4096 / (near + 1) + (if (mask != 0) @as(u32, 1024) else 0),
                                    .est = 0,
                                });
                            } else if (!baseline or e.state != .known) {
                                if (e.gen != gen or e.state == .none or e.state == .removing) {
                                    e.state = .creating;
                                    e.gen = gen;
                                }
                                try c.cands.append(c.gpa, .{ .g = g, .kind_i = ki, .idx = idx, .handle = handle, .op = .create, .gen = gen, .mask = allMask(k), .base_age = 0, .score = 0xF000_0000 - near, .est = 0 });
                            }
                        } else if (e.state != .none and !baseline) {
                            e.state = .removing;
                            try c.cands.append(c.gpa, .{ .g = g, .kind_i = ki, .idx = idx, .handle = handle, .op = .remove, .gen = e.gen, .mask = 0, .base_age = 0, .score = 0xFFFF_FFFF, .est = 0 });
                        }
                    }
                }

                // 2. sizes
                for (c.cands.items) |*cd| cd.est = try c.measure(state, cd.*);

                // 3. priority, then budget
                std.mem.sort(Cand, c.cands.items, {}, struct {
                    fn gt(_: void, a: Cand, b: Cand) bool {
                        return a.score > b.score;
                    }
                }.gt);
                var used: usize = w.pos;
                var take: usize = 0;
                for (c.cands.items) |cd| {
                    if (used + cd.est > budget and !(take == 0 and used + cd.est <= max_bytes)) {
                        c.stats.deferred += 1;
                        continue;
                    }
                    used += cd.est;
                    c.cands.items[take] = cd;
                    take += 1;
                }
                const chosen = c.cands.items[0..take];

                // 4. ascending handle, encode, remember
                std.mem.sort(Cand, chosen, {}, struct {
                    fn lt(_: void, a: Cand, b: Cand) bool {
                        return a.handle < b.handle;
                    }
                }.lt);
                var prev: ?u16 = null;
                for (chosen) |cd| {
                    try c.writeRecord(state, cd, prev, w, h);
                    prev = cd.handle;
                    c.ents[cd.g].last_sent_seq = seq;
                }
                c.stats.snapshots += 1;
                c.stats.records += take;
                c.stats.bytes += w.pos;
                return @intCast(take);
            }

            fn allMask(comptime k: KindInfo) u32 {
                return (@as(u32, 1) << @intCast(k.comps.len)) - 1;
            }

            fn measure(c: *Client, state: []const u8, cd: Cand) !u32 {
                c.tmp.clearRetainingCapacity();
                try c.tmp.ensureTotalCapacity(c.gpa, 4096);
                var w: wire.Writer = .{ .buf = c.tmp.allocatedSlice() };
                try c.writeBody(state, cd, &w);
                return @intCast(w.pos + 3); // + worst-case handle delta
            }

            fn writeRecord(c: *Client, state: []const u8, cd: Cand, prev: ?u16, w: *wire.Writer, h: *Hist) !void {
                try wire.encodeRecordHeader(w, prev, .{ .handle = cd.handle, .op = cd.op, .base_age = cd.base_age, .generation = cd.gen, .mask = cd.mask });
                try c.writePayload(state, cd, w);
                const off: u32 = @intCast(h.vals.items.len);
                if (cd.op != .remove) {
                    inline for (kinds, 0..) |k, ki| if (ki == cd.kind_i) {
                        inline for (k.comps) |cl| try h.vals.appendSlice(c.gpa, compBytes(state, cl, cd.idx));
                    };
                }
                try h.recs.append(c.gpa, .{ .g = cd.g, .op = cd.op, .gen = cd.gen, .val_off = off });
            }

            fn writeBody(c: *Client, state: []const u8, cd: Cand, w: *wire.Writer) !void {
                try wire.encodeRecordHeader(w, if (cd.handle == 0) null else cd.handle - 1, .{ .handle = cd.handle, .op = cd.op, .base_age = cd.base_age, .generation = cd.gen, .mask = cd.mask });
                try c.writePayload(state, cd, w);
            }

            fn writePayload(c: *Client, state: []const u8, cd: Cand, w: *wire.Writer) !void {
                if (cd.op == .remove) return;
                const zeros: [256]u8 = @splat(0);
                inline for (kinds, 0..) |k, ki| if (ki == cd.kind_i) {
                    const base = c.baseOf(k, cd.idx);
                    var off: u32 = 0;
                    inline for (k.comps, 0..) |cl, bi| {
                        if (cd.mask & (@as(u32, 1) << bi) != 0) {
                            const b: []const u8 = if (cd.op == .create) zeros[0..cl.stride] else base[off..][0..cl.stride];
                            try encodeComp(cl, w, b, compBytes(state, cl, cd.idx));
                        }
                        off += cl.stride;
                    }
                };
            }
        };

        fn decodeComp(comptime cl: Col, r: *wire.Reader, base: []const u8, out: []u8) wire.Error!void {
            const T = CompType(cl.id);
            if (T == void) {
                var i: usize = 0;
                while (i < cl.stride) : (i += 4) {
                    const b = std.mem.readInt(u32, base[i..][0..4], .little);
                    const d = try r.svarint();
                    if (d < std.math.minInt(i32) or d > std.math.maxInt(i32)) return error.BadMessage;
                    std.mem.writeInt(u32, out[i..][0..4], b +% @as(u32, @bitCast(@as(i32, @intCast(d)))), .little);
                }
            } else {
                const b = std.mem.bytesToValue(T, base[0..@sizeOf(T)]);
                var v: T = undefined;
                try wire.decodeComponent(T, r, &b, &v);
                @memcpy(out[0..@sizeOf(T)], std.mem.asBytes(&v));
            }
        }

        /// The client side of replication, for bots, tools and tests: keeps
        /// the decoded value of every entity for the last 64 snapshot seqs
        /// and applies records against per-entity bases, as I3 describes.
        pub const Mirror = struct {
            gpa: std.mem.Allocator,
            vals: [history_len][]u8,
            live: [history_len][]bool,
            seqs: [history_len]?u16 = @splat(null),
            newest: ?u16 = null,
            cur: usize = 0,

            pub fn init(gpa: std.mem.Allocator) !Mirror {
                var m: Mirror = .{ .gpa = gpa, .vals = undefined, .live = undefined };
                for (0..history_len) |i| {
                    m.vals[i] = try gpa.alloc(u8, value_bytes);
                    @memset(m.vals[i], 0);
                    m.live[i] = try gpa.alloc(bool, total_entities);
                    @memset(m.live[i], false);
                }
                return m;
            }
            pub fn deinit(m: *Mirror) void {
                for (0..history_len) |i| {
                    m.gpa.free(m.vals[i]);
                    m.gpa.free(m.live[i]);
                }
            }

            pub const Applied = struct { seq: u16, tick: u32, records: u32, stale: bool };

            /// Applies a snapshot or baseline body. Older-than-newest
            /// snapshots are ignored (`stale`).
            pub fn apply(m: *Mirror, body: []const u8, players_out: *[wire.max_local_players]wire.SnapshotPlayer) !Applied {
                var r: wire.Reader = .{ .buf = body };
                const d = try wire.SnapshotHeader.decode(&r, players_out);
                const seq = d.header.seq;
                if (m.newest) |n| if (!seqNewer(seq, n)) return .{ .seq = seq, .tick = d.header.tick, .records = 0, .stale = true };
                const slot = seq % history_len;
                if (slot != m.cur) {
                    @memcpy(m.vals[slot], m.vals[m.cur]);
                    @memcpy(m.live[slot], m.live[m.cur]);
                }
                var prev: ?u16 = null;
                var n: u32 = 0;
                while (!r.done()) {
                    const rh = try wire.decodeRecordHeader(&r, prev);
                    prev = rh.handle;
                    n += 1;
                    const kind: u4 = @intCast(rh.handle >> 12);
                    const idx: u32 = rh.handle & 0xFFF;
                    var found = false;
                    inline for (kinds) |k| {
                        if (k.kind == kind and idx < k.count) {
                            found = true;
                            const g = k.base + idx;
                            const off = baseOffsetOfGlobal(g);
                            const out = m.vals[slot][off..][0..k.value_size];
                            if (rh.op == .remove) {
                                m.live[slot][g] = false;
                            } else {
                                var base_buf: [4096]u8 = @splat(0);
                                const base = base_buf[0..k.value_size];
                                if (rh.op == .update) {
                                    const bs = seq -% rh.base_age;
                                    const bslot = bs % history_len;
                                    if (m.seqs[bslot] == null or m.seqs[bslot].? != bs) return error.MissingBase;
                                    @memcpy(base, m.vals[bslot][off..][0..k.value_size]);
                                }
                                var coff: u32 = 0;
                                inline for (k.comps, 0..) |cl, bi| {
                                    if (rh.mask & (@as(u32, 1) << bi) != 0) {
                                        try decodeComp(cl, &r, base[coff..][0..cl.stride], out[coff..][0..cl.stride]);
                                    } else @memcpy(out[coff..][0..cl.stride], base[coff..][0..cl.stride]);
                                    coff += cl.stride;
                                }
                                m.live[slot][g] = true;
                            }
                        }
                    }
                    if (!found) return error.BadMessage;
                }
                m.seqs[slot] = seq;
                m.newest = seq;
                m.cur = slot;
                return .{ .seq = seq, .tick = d.header.tick, .records = n, .stale = false };
            }

            /// Current value of component `id` of entity (kind, idx), if live.
            pub fn component(m: *const Mirror, comptime T: type, kind: u4, idx: u32, id: u16) ?T {
                inline for (kinds) |k| {
                    if (k.kind == kind and idx < k.count) {
                        const g = k.base + idx;
                        if (!m.live[m.cur][g]) return null;
                        var coff: u32 = 0;
                        inline for (k.comps) |cl| {
                            if (cl.id == id) return std.mem.bytesToValue(T, m.vals[m.cur][baseOffsetOfGlobal(g) + coff ..][0..@sizeOf(T)]);
                            coff += cl.stride;
                        }
                    }
                }
                return null;
            }

            pub fn liveCount(m: *const Mirror) u32 {
                var n: u32 = 0;
                for (m.live[m.cur]) |l| n += @intFromBool(l);
                return n;
            }
        };

        fn baseOffset(comptime k: KindInfo) u32 {
            var off: u32 = 0;
            inline for (kinds) |kk| {
                if (kk.base == k.base) return off;
                off += kk.count * kk.value_size;
            }
            unreachable;
        }

        pub fn baseOffsetOfGlobal(g: u32) u32 {
            var off: u32 = 0;
            inline for (kinds) |k| {
                if (g >= k.base and g < k.base + k.count) return off + (g - k.base) * k.value_size;
                off += k.count * k.value_size;
            }
            unreachable;
        }

        fn valueSizeOfGlobal(g: u32) u32 {
            inline for (kinds) |k| {
                if (g >= k.base and g < k.base + k.count) return k.value_size;
            }
            unreachable;
        }
    };
}

pub inline fn seqNewer(a: u16, b: u16) bool {
    return @as(i16, @bitCast(a -% b)) > 0;
}

// ---------------------------------------------------------------------------
// Tests: encode against the stub, decode with the I3 codecs, check the
// client can rebuild exact values from per-entity bases.

const testing = std.testing;

test "stub replication tables" {
    const R = Replicator(abi.Stub);
    try testing.expectEqual(@as(usize, 2), R.kinds.len); // peds + player rows
    try testing.expectEqual(@as(u4, 1), R.kinds[0].kind);
    // transform, velocity, controller (predicted excluded)
    try testing.expectEqual(@as(usize, 3), R.kinds[0].comps.len);
    try testing.expectEqual(@as(u16, 1), R.kinds[0].comps[0].id);
    try testing.expectEqual(@as(u16, 5), R.kinds[0].comps[2].id);
    try testing.expectEqual(@as(u32, 0), R.fallback_columns);
}

/// A minimal client-side decoder: enough to check the encoder.
const MiniClient = struct {
    // values[seq % 64][handle] for peds 0..15 (transform only checked)
    hist: [64]?[16]?abi.Transform = @splat(null),
    cur: [16]?abi.Transform = @splat(null),

    fn apply(m: *MiniClient, bytes: []const u8) !u16 {
        var r: wire.Reader = .{ .buf = bytes };
        var players: [4]wire.SnapshotPlayer = undefined;
        const d = try wire.SnapshotHeader.decode(&r, &players);
        const seq = d.header.seq;
        var prev: ?u16 = null;
        var next = m.cur;
        while (!r.done()) {
            const rh = try wire.decodeRecordHeader(&r, prev);
            prev = rh.handle;
            const kind = rh.handle >> 12;
            const idx = rh.handle & 0xFFF;
            if (rh.op == .remove) {
                if (kind == 1) next[idx] = null;
                continue;
            }
            if (kind == 15) {
                var row: abi.PlayerRow = undefined;
                const z = std.mem.zeroes(abi.PlayerRow);
                if (rh.mask & 1 != 0) try wire.decodeComponent(abi.PlayerRow, &r, &z, &row);
                continue;
            }
            const base_t: abi.Transform = if (rh.op == .create) std.mem.zeroes(abi.Transform) else m.hist[(seq -% rh.base_age) % 64].?[idx].?;
            var t = base_t;
            if (rh.mask & 1 != 0) try wire.decodeComponent(abi.Transform, &r, &base_t, &t);
            var v: abi.Velocity = undefined;
            const zv = std.mem.zeroes(abi.Velocity);
            if (rh.mask & 2 != 0) try wire.decodeComponent(abi.Velocity, &r, &zv, &v); // value ignored
            var ct: abi.Controller = undefined;
            const zc = std.mem.zeroes(abi.Controller);
            if (rh.mask & 4 != 0) try wire.decodeComponent(abi.Controller, &r, &zc, &ct);
            next[idx] = t;
        }
        m.cur = next;
        m.hist[seq % 64] = next;
        return seq;
    }
};

test "snapshots decode to the server's exact transforms" {
    const gpa = testing.allocator;
    const Sim = abi.Stub;
    const R = Replicator(Sim);
    const grid = try gpa.create(abi.Grid);
    defer gpa.destroy(grid);
    var sim: Sim = undefined;
    sim.init(grid, .{ .seed = 1, .mode = .authoritative });
    var frames: [16]ifc.input.Frame = @splat(ifc.input.Frame.neutral(0));
    const joins = [_]abi.Command{ .{ .op = .join, .slot = 0, .arg = 0 }, .{ .op = .join, .slot = 5, .arg = 0 } };
    sim.step(&frames, &joins);

    var cl = try R.Client.init(gpa);
    defer cl.deinit();
    var mini: MiniClient = .{};
    var buf: [1100]u8 = undefined;
    var ack_bits: u32 = 0;
    var ack_seq: u16 = 0;
    var seq: u16 = 0;
    // baseline
    {
        var w: wire.Writer = .{ .buf = &buf };
        _ = try cl.build(sim.stateBytes(), .{ .seq = seq, .tick = sim.tick(), .echo_time = 0, .hold_ms = 0, .players = &.{} }, &.{}, .{}, true, buf.len, &w, 0);
        ack_seq = try mini.apply(w.written());
        ack_bits = 1;
        _ = cl.onAck(ack_seq, ack_bits, 1);
        try testing.expect(cl.baseline_acked);
        seq += 1;
    }
    var prng = std.Random.DefaultPrng.init(3);
    for (0..200) |i| {
        frames[0].throttle = 100;
        frames[0].steer = @intCast(@as(i32, @intCast(i % 7)) - 3);
        frames[5].throttle = -50;
        sim.step(&frames, &.{});
        var w: wire.Writer = .{ .buf = &buf };
        _ = try cl.build(sim.stateBytes(), .{ .seq = seq, .tick = sim.tick(), .echo_time = 0, .hold_ms = 0, .players = &.{} }, &.{}, .{}, false, buf.len, &w, 0);
        // 20% loss downlink
        if (prng.random().uintLessThan(u8, 10) >= 2) {
            const s = try mini.apply(w.written());
            ack_bits = if (seqNewer(s, ack_seq)) (ack_bits << @intCast(s -% ack_seq)) | 1 else ack_bits;
            ack_seq = s;
            for ([_]u32{ 0, 5 }) |p| {
                const want = sim.state.ped.transform[p];
                try testing.expectEqual(want, mini.cur[p].?);
            }
        }
        // 20% loss uplink
        if (prng.random().uintLessThan(u8, 10) >= 2) _ = cl.onAck(ack_seq, ack_bits, 1);
        seq +%= 1;
    }
    try testing.expect(cl.stats.lost > 0);
}

test "mirror decodes what the server encodes" {
    const gpa = testing.allocator;
    const Sim = abi.Stub;
    const R = Replicator(Sim);
    const grid = try gpa.create(abi.Grid);
    defer gpa.destroy(grid);
    var sim: Sim = undefined;
    sim.init(grid, .{ .seed = 1, .mode = .authoritative });
    var frames: [16]ifc.input.Frame = @splat(ifc.input.Frame.neutral(0));
    const joins = [_]abi.Command{ .{ .op = .join, .slot = 2, .arg = 0 }, .{ .op = .join, .slot = 9, .arg = 0 } };
    sim.step(&frames, &joins);
    var cl = try R.Client.init(gpa);
    defer cl.deinit();
    var m = try R.Mirror.init(gpa);
    defer m.deinit();
    var players: [4]wire.SnapshotPlayer = undefined;
    var buf: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(9);
    var ack_seq: u16 = 0;
    var ack_bits: u32 = 0;
    var seq: u16 = 0;
    for (0..300) |i| {
        if (i > 0) {
            frames[2].throttle = 90;
            frames[2].steer = 5;
            frames[9].throttle = @intCast(@as(i32, @intCast(i % 50)) - 25);
            sim.step(&frames, if (i == 150) &[_]abi.Command{.{ .op = .leave, .slot = 9, .arg = 0 }} else &.{});
        }
        var w: wire.Writer = .{ .buf = if (i == 0) &buf else buf[0..1100] };
        _ = try cl.build(sim.stateBytes(), .{ .seq = seq, .tick = sim.tick(), .echo_time = 0, .hold_ms = 0, .players = &.{} }, &.{}, .{}, i == 0, w.buf.len, &w, 0);
        seq +%= 1;
        if (i == 0 or prng.random().uintLessThan(u8, 10) >= 3) {
            const a = try m.apply(w.written(), &players);
            if (!a.stale) {
                ack_bits = if (i == 0) 1 else if (seqNewer(a.seq, ack_seq)) (ack_bits << @intCast(a.seq -% ack_seq)) | 1 else ack_bits;
                ack_seq = a.seq;
                const t = m.component(abi.Transform, 1, 2, 1).?;
                try testing.expectEqual(sim.state.ped.transform[2], t);
                if (i > 160) try testing.expect(m.component(abi.Transform, 1, 9, 1) == null);
            }
        }
        if (prng.random().uintLessThan(u8, 10) >= 3) _ = cl.onAck(ack_seq, ack_bits, 1);
    }
}
