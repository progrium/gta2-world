//! Cross-language test vectors. `zig build vectors` prints them; the output
//! is committed as interfaces/testdata/vectors.txt and the TypeScript tests
//! decode and re-encode every one. Format: `name hex` per line.

const std = @import("std");
const abi = @import("abi.zig");
const input = @import("input.zig");
const wire = @import("wire.zig");

pub const Vector = struct { name: []const u8, len: usize, buf: [512]u8 };

pub fn build(out: *[16]Vector) !usize {
    var n: usize = 0;
    const add = struct {
        fn f(o: *[16]Vector, k: *usize, name: []const u8) *wire.Writer {
            o[k.*] = .{ .name = name, .len = 0, .buf = undefined };
            k.* += 1;
            return undefined;
        }
    }.f;
    _ = add;

    // frame
    {
        const v = &out[n];
        n += 1;
        v.name = "frame";
        const f: input.Frame = .{ .steer = -100, .throttle = 127, .buttons = input.Button.fire | input.Button.direct, .aim = 0x4000, .seq = 0x1234 };
        f.encode(v.buf[0..8]);
        v.len = 8;
    }
    // hello
    {
        const v = &out[n];
        n += 1;
        v.name = "hello";
        var w: wire.Writer = .{ .buf = &v.buf };
        var mh: [32]u8 = undefined;
        for (&mh, 0..) |*b, i| b.* = @intCast(i);
        try (wire.Hello{
            .layout_hash = 0x0123_4567_89AB_CDEF,
            .map_hash = mh,
            .transport = .webtransport,
            .names = &.{ "jeff", "p2" },
        }).encode(&w);
        v.len = w.pos;
    }
    // welcome
    {
        const v = &out[n];
        n += 1;
        v.name = "welcome";
        var w: wire.Writer = .{ .buf = &v.buf };
        try (wire.Welcome{
            .client_id = 42,
            .resume_token = @splat(0xAB),
            .server_tick = 90_000,
            .max_players = 16,
            .config_name = "dm16",
            .slots = &.{ 3, 4 },
        }).encode(&w);
        v.len = w.pos;
    }
    // reject in a stream frame
    {
        const v = &out[n];
        n += 1;
        v.name = "stream_reject";
        var body: [64]u8 = undefined;
        var bw: wire.Writer = .{ .buf = &body };
        try (wire.Reject{ .code = .map_mismatch, .message = "map differs" }).encode(&bw);
        var w: wire.Writer = .{ .buf = &v.buf };
        try wire.writeStreamFrame(&w, bw.written());
        v.len = w.pos;
    }
    // input
    {
        const v = &out[n];
        n += 1;
        v.name = "input";
        var w: wire.Writer = .{ .buf = &v.buf };
        const fa = [_]input.Frame{
            .{ .steer = 10, .throttle = 127, .buttons = 0, .aim = 0, .seq = input.seqOf(65535) },
            .{ .steer = 20, .throttle = 127, .buttons = input.Button.handbrake_jump, .aim = 0, .seq = input.seqOf(65536) },
            .{ .steer = -127, .throttle = -50, .buttons = input.Button.fire, .aim = 0, .seq = input.seqOf(65537) },
        };
        const fb = [_]input.Frame{.{ .steer = 0, .throttle = 90, .buttons = input.Button.direct | input.Button.run, .aim = 49152, .seq = input.seqOf(65537) }};
        try wire.encodeInput(&w, .{ .ack_seq = 700, .ack_bits = 0x8000_000F, .send_time = 51234, .players = 2 }, &.{
            .{ .slot = 3, .newest_tick = 65537, .frames = &fa },
            .{ .slot = 4, .newest_tick = 65537, .frames = &fb },
        });
        v.len = w.pos;
    }
    // snapshot
    {
        const v = &out[n];
        n += 1;
        v.name = "snapshot";
        var w: wire.Writer = .{ .buf = &v.buf };
        try (wire.SnapshotHeader{
            .seq = 701,
            .tick = 65530,
            .echo_time = 51200,
            .hold_ms = 12,
            .players = &.{.{ .slot = 3, .input_ack = 65536, .slack_q = 7 }},
        }).encode(&w, false);
        const zero_t = std.mem.zeroes(abi.Transform);
        // update car 2 against snapshot seq 698
        const car_base: abi.Transform = .{ .x = 120 * abi.fx_one, .y = 80 * abi.fx_one, .z = 2 * abi.fx_one, .heading = 1000 };
        const car_now: abi.Transform = .{ .x = 120 * abi.fx_one + 30000, .y = 80 * abi.fx_one - 500, .z = 2 * abi.fx_one, .heading = 64000 };
        var prev: ?u16 = null;
        const h_car = abi.EntityId.make(.car, 2, 0).handle();
        try wire.encodeRecordHeader(&w, prev, .{ .handle = h_car, .op = .update, .base_age = 3, .mask = 1 });
        try wire.encodeComponent(abi.Transform, &w, &car_base, &car_now);
        prev = h_car;
        // create ped 3 generation 7, transform only
        const h_ped = abi.EntityId.make(.ped, 3, 7).handle();
        const ped: abi.Transform = .{ .x = 121 * abi.fx_one, .y = 79 * abi.fx_one, .z = 2 * abi.fx_one, .heading = 16384 };
        try wire.encodeRecordHeader(&w, prev, .{ .handle = h_ped, .op = .create, .generation = 7, .mask = 1 });
        try wire.encodeComponent(abi.Transform, &w, &zero_t, &ped);
        prev = h_ped;
        // remove projectile 16
        const h_shot = abi.EntityId.make(.projectile, 16, 0).handle();
        try wire.encodeRecordHeader(&w, prev, .{ .handle = h_shot, .op = .remove });
        prev = h_shot;
        // create player row 3
        const h_row = wire.handle_player_row_base | 3;
        const zero_r = std.mem.zeroes(abi.PlayerRow);
        const row: abi.PlayerRow = .{ .ped = abi.EntityId.make(.ped, 3, 7), .car = .none, .kills = 5, .deaths = 2, .score = 5000, .respawn_timer = 0, .flags = abi.PlayerRow.flag_active | abi.PlayerRow.flag_connected };
        try wire.encodeRecordHeader(&w, prev, .{ .handle = h_row, .op = .create, .generation = 0, .mask = 1 });
        try wire.encodeComponent(abi.PlayerRow, &w, &zero_r, &row);
        v.len = w.pos;
    }
    // event
    {
        const v = &out[n];
        n += 1;
        v.name = "event";
        var w: wire.Writer = .{ .buf = &v.buf };
        try (wire.Event{ .tick = 65500, .kind = .explosion, .a = 12, .x = 120 * abi.fx_one, .y = -3, .z = 2 * abi.fx_one }).encode(&w);
        v.len = w.pos;
    }
    // chat_from
    {
        const v = &out[n];
        n += 1;
        v.name = "chat_from";
        var w: wire.Writer = .{ .buf = &v.buf };
        try (wire.Chat{ .slot = 5, .text = "gg ✓" }).encode(&w, true);
        v.len = w.pos;
    }
    // player_info
    {
        const v = &out[n];
        n += 1;
        v.name = "player_info";
        var w: wire.Writer = .{ .buf = &v.buf };
        try (wire.PlayerInfo{ .slot = 5, .flags = wire.PlayerInfo.flag_present, .name = "zaibatsu" }).encode(&w);
        v.len = w.pos;
    }
    // svarints
    {
        const v = &out[n];
        n += 1;
        v.name = "svarints";
        var w: wire.Writer = .{ .buf = &v.buf };
        for ([_]i64{ 0, -1, 1, 63, -64, 64, 300, -300, 2147483647, -2147483648 }) |x| try w.svarint(x);
        v.len = w.pos;
    }
    return n;
}

pub fn main() !void {
    var vs: [16]Vector = undefined;
    const n = try build(&vs);
    for (vs[0..n]) |v| {
        std.debug.print("{s} ", .{v.name});
        for (v.buf[0..v.len]) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});
    }
}

test "vectors decode in Zig" {
    var vs: [16]Vector = undefined;
    const n = try build(&vs);
    try std.testing.expectEqual(@as(usize, 10), n);
    // input
    {
        var r: wire.Reader = .{ .buf = vs[4].buf[0..vs[4].len] };
        var po: [wire.max_local_players]wire.InputPlayer = undefined;
        var fo: [wire.max_local_players][wire.max_redundancy]input.Frame = undefined;
        const d = try wire.decodeInput(&r, &po, &fo);
        try std.testing.expectEqual(@as(usize, 2), d.players.len);
        try std.testing.expectEqual(@as(i8, -127), d.players[0].frames[2].steer);
    }
    // snapshot
    {
        var r: wire.Reader = .{ .buf = vs[5].buf[0..vs[5].len] };
        var po: [wire.max_local_players]wire.SnapshotPlayer = undefined;
        const d = try wire.SnapshotHeader.decode(&r, &po);
        try std.testing.expect(!d.baseline);
        try std.testing.expectEqual(@as(u32, 65530), d.header.tick);
        var prev: ?u16 = null;
        var count: usize = 0;
        while (!r.done()) {
            const h = try wire.decodeRecordHeader(&r, prev);
            prev = h.handle;
            count += 1;
            if (h.op == .remove) continue;
            if (h.handle >> 12 == 15) {
                var row: abi.PlayerRow = undefined;
                try wire.decodeComponent(abi.PlayerRow, &r, &std.mem.zeroes(abi.PlayerRow), &row);
                try std.testing.expectEqual(@as(i32, 5000), row.score);
            } else {
                var t: abi.Transform = undefined;
                try wire.decodeComponent(abi.Transform, &r, &std.mem.zeroes(abi.Transform), &t);
            }
        }
        try std.testing.expectEqual(@as(usize, 4), count);
    }
}
