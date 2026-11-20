//! Replication schema for an I1 sim type: which kinds and components travel
//! in I3 snapshots, where they live in the state bytes, and how one entity's
//! replicated value is packed, diffed and coded.
//!
//! The replicated set comes from `S.replicated` if the sim declares it:
//!
//!     pub const replicated = .{
//!         .{ abi.Kind.car, .{ abi.Transform, abi.Velocity, abi.Controller, Vehicle } },
//!         ...
//!     };
//!
//! a tuple of (kind, tuple of component types in ascending `id`), never
//! including `Predicted`. Without it, each kind replicates the frozen I1
//! components that have a view column. Player rows (handle kind 15) are always
//! replicated, as one `PlayerRow` component.
//!
//! An entity's *value* is its replicated components packed back to back in
//! mask-bit order. Values are what the encoder diffs, what the decoder keeps
//! as bases, and what the client writes into its state.

const std = @import("std");
const itf = @import("interfaces");
const abi = itf.abi;
const wire = itf.wire;

const Special = abi.ColumnDesc.Special;

pub const Pos = struct { x: abi.Fx, y: abi.Fx };

pub fn Schema(comptime S: type) type {
    @setEvalBranchQuota(100_000);
    const views = comptime S.views();

    const rep = if (@hasDecl(S, "replicated")) S.replicated else defaultReplicated(views);

    const KindDesc = struct {
        kind: u4,
        capacity: u32,
        slot_off: u32,
        gen_off: u32,
        /// offsets of each component's column, and their strides
        col_off: []const u32,
        col_stride: []const u32,
        comp_size: []const u32,
        /// offset of each component inside the packed value
        val_off: []const u32,
        value_size: u32,
        transform_off: ?u32,
        velocity_off: ?u32,
        controller_off: ?u32,
        predicted_off: ?u32,
    };

    const nk = rep.len + 1; // + player rows
    const kd: [nk]KindDesc = blk: {
        var out: [nk]KindDesc = undefined;
        for (0..rep.len) |k| {
            const kind: u4 = @intFromEnum(@as(abi.Kind, rep[k][0]));
            const comps = rep[k][1];
            var col_off: [comps.len]u32 = undefined;
            var col_stride: [comps.len]u32 = undefined;
            var comp_size: [comps.len]u32 = undefined;
            var val_off: [comps.len]u32 = undefined;
            var vs: u32 = 0;
            var last_id: i32 = -1;
            for (comps, 0..) |C, c| {
                const id: u16 = @intFromEnum(@as(abi.ComponentId, C.id));
                if (id <= last_id) @compileError("replicated components must be in ascending id order");
                if (C.id == .predicted) @compileError("Predicted is never replicated");
                last_id = id;
                const v = findView(views, kind, id) orelse @compileError("no view column for a replicated component of kind " ++ @tagName(@as(abi.Kind, rep[k][0])));
                if (v.stride != @sizeOf(C)) @compileError("view stride differs from component size");
                col_off[c] = v.offset;
                col_stride[c] = v.stride;
                comp_size[c] = @sizeOf(C);
                val_off[c] = vs;
                vs += @sizeOf(C);
            }
            const sv = findView(views, kind, Special.slot) orelse @compileError("kind without slot column");
            const gv = findView(views, kind, Special.generation) orelse @compileError("kind without generation column");
            const fc = col_off;
            const fs = col_stride;
            const fz = comp_size;
            const fv = val_off;
            out[k] = .{
                .kind = kind,
                .capacity = sv.count,
                .slot_off = sv.offset,
                .gen_off = gv.offset,
                .col_off = &fc,
                .col_stride = &fs,
                .comp_size = &fz,
                .val_off = &fv,
                .value_size = vs,
                .transform_off = if (findView(views, kind, @intFromEnum(abi.ComponentId.transform))) |t| t.offset else null,
                .velocity_off = if (findView(views, kind, @intFromEnum(abi.ComponentId.velocity))) |t| t.offset else null,
                .controller_off = if (findView(views, kind, @intFromEnum(abi.ComponentId.controller))) |t| t.offset else null,
                .predicted_off = if (findView(views, kind, @intFromEnum(abi.ComponentId.predicted))) |t| t.offset else null,
            };
        }
        const pv = findView(views, 15, Special.player_rows) orelse @compileError("no player_rows view");
        const pc = [_]u32{pv.offset};
        const ps = [_]u32{@sizeOf(abi.PlayerRow)};
        const pz = [_]u32{0};
        out[rep.len] = .{
            .kind = 15,
            .capacity = pv.count,
            .slot_off = 0,
            .gen_off = 0,
            .col_off = &pc,
            .col_stride = &ps,
            .comp_size = &ps,
            .val_off = &pz,
            .value_size = @sizeOf(abi.PlayerRow),
            .transform_off = null,
            .velocity_off = null,
            .controller_off = null,
            .predicted_off = null,
        };
        break :blk out;
    };

    return struct {
        pub const Sim = S;
        pub const num_kinds = nk;
        pub const player_kind = nk - 1;
        pub const desc = kd;

        /// First flat entity index of each kind; flat indices cover every
        /// replicated slot of every kind plus the player rows.
        pub const kind_base: [nk]u32 = blk: {
            var b: [nk]u32 = undefined;
            var acc: u32 = 0;
            for (0..nk) |k| {
                b[k] = acc;
                acc += kd[k].capacity;
            }
            break :blk b;
        };
        pub const total: u32 = kind_base[nk - 1] + kd[nk - 1].capacity;

        pub const max_value_size: u32 = blk: {
            var m: u32 = 0;
            for (kd) |d| m = @max(m, d.value_size);
            break :blk m;
        };

        /// Kind index (into `desc`) for an I1 kind number, or null.
        pub fn kindIndex(kind: u4) ?usize {
            inline for (0..nk) |k| if (kd[k].kind == kind) return k;
            return null;
        }

        pub fn handle(comptime k: usize, i: u32) u16 {
            return (@as(u16, kd[k].kind) << 12) | @as(u16, @intCast(i));
        }

        pub fn flat(k: usize, i: u32) u32 {
            return kind_base[k] + i;
        }

        pub fn fromFlat(f: u32) struct { k: usize, i: u32 } {
            var k: usize = nk - 1;
            while (kind_base[k] > f) k -= 1;
            return .{ .k = k, .i = f - kind_base[k] };
        }

        pub fn handleOfFlat(f: u32) u16 {
            const e = fromFlat(f);
            return (@as(u16, kd[e.k].kind) << 12) | @as(u16, @intCast(e.i));
        }

        // -- state access ---------------------------------------------------

        /// Whether the entity exists. Player rows exist while active.
        pub fn alive(state: []const u8, k: usize, i: u32) bool {
            if (k == player_kind) {
                const row = readAt(abi.PlayerRow, state, kd[k].col_off[0] + i * @sizeOf(abi.PlayerRow));
                return row.flags & abi.PlayerRow.flag_active != 0;
            }
            return state[kd[k].slot_off + i] == abi.Slot.alive;
        }

        pub fn gen(state: []const u8, k: usize, i: u32) u16 {
            if (k == player_kind) return 0;
            return std.mem.readInt(u16, state[kd[k].gen_off + 2 * i ..][0..2], .little);
        }

        pub fn entityId(state: []const u8, k: usize, i: u32) abi.EntityId {
            return .{ .raw = (i & 0xFFF) | (@as(u32, kd[k].kind) << 12) | (@as(u32, gen(state, k, i)) << 16) };
        }

        pub fn transform(state: []const u8, k: usize, i: u32) ?abi.Transform {
            const off = kd[k].transform_off orelse return null;
            return readAt(abi.Transform, state, off + i * @sizeOf(abi.Transform));
        }

        pub fn setTransform(state: []u8, k: usize, i: u32, t: abi.Transform) void {
            const off = kd[k].transform_off orelse return;
            writeAt(abi.Transform, state, off + i * @sizeOf(abi.Transform), t);
        }

        pub fn velocity(state: []const u8, k: usize, i: u32) ?abi.Velocity {
            const off = kd[k].velocity_off orelse return null;
            return readAt(abi.Velocity, state, off + i * @sizeOf(abi.Velocity));
        }

        pub fn controller(state: []const u8, k: usize, i: u32) ?abi.Controller {
            const off = kd[k].controller_off orelse return null;
            return readAt(abi.Controller, state, off + i * @sizeOf(abi.Controller));
        }

        pub fn setPredicted(state: []u8, k: usize, i: u32, on: bool) void {
            const off = kd[k].predicted_off orelse return;
            std.mem.writeInt(u32, state[off + 4 * i ..][0..4], @intFromBool(on), .little);
        }

        pub fn canPredict(k: usize) bool {
            return kd[k].predicted_off != null;
        }

        pub fn playerRow(state: []const u8, slot: u32) abi.PlayerRow {
            return readAt(abi.PlayerRow, state, kd[nk - 1].col_off[0] + slot * @sizeOf(abi.PlayerRow));
        }

        /// Gather the entity's replicated value into `out[0..value_size]`.
        pub fn readValue(state: []const u8, k: usize, i: u32, out: []u8) void {
            inline for (0..nk) |kk| if (kk == k) {
                const d = kd[kk];
                inline for (0..d.col_off.len) |c| {
                    const src = d.col_off[c] + i * d.col_stride[c];
                    @memcpy(out[d.val_off[c]..][0..d.comp_size[c]], state[src..][0..d.comp_size[c]]);
                }
                return;
            };
        }

        /// Scatter a value into the entity's columns (every replicated
        /// component, so a create also clears stale values).
        pub fn writeValue(state: []u8, k: usize, i: u32, val: []const u8) void {
            inline for (0..nk) |kk| if (kk == k) {
                const d = kd[kk];
                inline for (0..d.col_off.len) |c| {
                    const dst = d.col_off[c] + i * d.col_stride[c];
                    @memcpy(state[dst..][0..d.comp_size[c]], val[d.val_off[c]..][0..d.comp_size[c]]);
                }
                return;
            };
        }

        // -- coding ---------------------------------------------------------

        /// Bit c set when component c differs between base and val.
        pub fn diffMask(k: usize, base: []const u8, val: []const u8) u32 {
            var m: u32 = 0;
            inline for (0..nk) |kk| if (kk == k) {
                const d = kd[kk];
                inline for (0..d.col_off.len) |c| {
                    const a = base[d.val_off[c]..][0..d.comp_size[c]];
                    const b = val[d.val_off[c]..][0..d.comp_size[c]];
                    if (!std.mem.eql(u8, a, b)) m |= @as(u32, 1) << c;
                }
            };
            return m;
        }

        pub fn encodePayload(k: usize, w: *wire.Writer, mask: u32, base: []const u8, val: []const u8) wire.Error!void {
            inline for (0..nk) |kk| if (kk == k) {
                const comps = if (kk == nk - 1) .{abi.PlayerRow} else rep[kk][1];
                const d = kd[kk];
                inline for (comps, 0..) |C, c| {
                    if (mask & (@as(u32, 1) << c) != 0) {
                        const b = readAt(C, base, d.val_off[c]);
                        const v = readAt(C, val, d.val_off[c]);
                        try wire.encodeComponent(C, w, &b, &v);
                    }
                }
                return;
            };
        }

        /// Decode a payload against `base` into `out` (components not in the
        /// mask are copied from base).
        pub fn decodePayload(k: usize, r: *wire.Reader, mask: u32, base: []const u8, out: []u8) wire.Error!void {
            inline for (0..nk) |kk| if (kk == k) {
                const comps = if (kk == nk - 1) .{abi.PlayerRow} else rep[kk][1];
                const d = kd[kk];
                if (mask >> @intCast(comps.len) != 0) return error.BadMessage;
                @memcpy(out[0..d.value_size], base[0..d.value_size]);
                inline for (comps, 0..) |C, c| {
                    if (mask & (@as(u32, 1) << c) != 0) {
                        const b = readAt(C, base, d.val_off[c]);
                        var v: C = undefined;
                        try wire.decodeComponent(C, r, &b, &v);
                        writeAt(C, out, d.val_off[c], v);
                    }
                }
                return;
            };
        }
    };
}

pub fn readAt(comptime T: type, bytes: []const u8, off: usize) T {
    var v: T = undefined;
    @memcpy(std.mem.asBytes(&v), bytes[off..][0..@sizeOf(T)]);
    return v;
}

pub fn writeAt(comptime T: type, bytes: []u8, off: usize, v: T) void {
    @memcpy(bytes[off..][0..@sizeOf(T)], std.mem.asBytes(&v));
}

fn findView(comptime views: []const abi.ColumnDesc, comptime kind: u8, comptime comp: u16) ?abi.ColumnDesc {
    for (views) |v| if (v.kind == kind and v.component == comp) return v;
    return null;
}

fn defaultReplicated(comptime views: []const abi.ColumnDesc) defaultType(views) {
    var out: defaultType(views) = undefined;
    var n = 0;
    for (0..15) |kind| {
        if (findView(views, kind, Special.slot) == null) continue;
        const comps = defaultComps(views, kind);
        out[n] = .{ @as(abi.Kind, @enumFromInt(kind)), &comps };
        n += 1;
    }
    return out;
}

const frozen = .{ abi.Transform, abi.Velocity, abi.Health, abi.Controller, abi.Riding };

fn defaultComps(comptime views: []const abi.ColumnDesc, comptime kind: u8) DefaultCompsType(views, kind) {
    var out: DefaultCompsType(views, kind) = undefined;
    var n = 0;
    for (frozen) |C| {
        if (findView(views, kind, @intFromEnum(C.id)) != null) {
            out[n] = C;
            n += 1;
        }
    }
    return out;
}

fn DefaultCompsType(comptime views: []const abi.ColumnDesc, comptime kind: u8) type {
    var n = 0;
    for (frozen) |C| {
        if (findView(views, kind, @intFromEnum(C.id)) != null) n += 1;
    }
    return [n]type;
}

fn defaultType(comptime views: []const abi.ColumnDesc) type {
    var n = 0;
    for (0..15) |kind| {
        if (findView(views, kind, Special.slot) != null) n += 1;
    }
    return [n]struct { abi.Kind, []const type };
}
