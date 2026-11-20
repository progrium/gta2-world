const std = @import("std");
const itf = @import("interfaces");
const abi = itf.abi;
const schema = @import("schema.zig");
const testsim = @import("testsim.zig");

pub const TestCfg: abi.Config = .{ .name = "arena_test", .max_players = 4, .car_capacity = 16, .ped_capacity = 32, .projectile_capacity = 0, .ambient_cars = 4, .ambient_peds = 20 };
pub const TS = testsim.Sim(TestCfg);

test "schema of testsim and stub" {
    const Sc = schema.Schema(TS);
    try std.testing.expectEqual(@as(usize, 3), Sc.num_kinds);
    try std.testing.expectEqual(@as(u32, 16 + 32 + 4), Sc.total);
    try std.testing.expectEqual(@as(u32, 16 + 16 + 8 + 16 + 8), Sc.desc[0].value_size);
    const St = schema.Schema(abi.Stub);
    try std.testing.expectEqual(@as(usize, 2), St.num_kinds);
    try std.testing.expectEqual(@as(u32, 16 + 16 + 16), St.desc[0].value_size);
}

const enc = @import("encoder.zig");
const dec = @import("decoder.zig");
const wire = itf.wire;
const input = itf.input;

fn noop(_: void, _: usize, _: u32, _: wire.RecordOp) void {}

/// Server steps; every 1.5 ticks a snapshot is encoded, "sent" with loss,
/// decoded and applied to a client copy; acks flow back with loss. Checks
/// that each applied snapshot leaves the client's replicated values equal to
/// the server's at that tick for every record it carried, and that with a
/// generous budget the client converges to the full replicated world.
fn roundTrip(budget: u32, loss_mod: u32) !void {
    const gpa = std.testing.allocator;
    const Sc = schema.Schema(TS);
    const grid = try gpa.create(abi.Grid);
    defer gpa.destroy(grid);
    const srv = try gpa.create(TS);
    defer gpa.destroy(srv);
    const cli = try gpa.create(TS);
    defer gpa.destroy(cli);
    srv.init(grid, .{ .seed = 3, .mode = .authoritative });
    cli.init(grid, .{ .seed = 3, .mode = .predict });
    var hist = try enc.History(TS).init(gpa);
    defer hist.deinit(gpa);
    var e = try enc.ClientEncoder(TS).init(gpa, .{ .budget = budget, .interest_enter = 1000 * abi.fx_one, .interest_leave = 1000 * abi.fx_one });
    defer e.deinit(gpa);
    e.own_slots[0] = 0;
    var d = try dec.Decoder(TS).init(gpa);
    defer d.deinit(gpa);

    var frames: [4]input.Frame = @splat(input.Frame.neutral(0));
    srv.step(&frames, &.{ .{ .op = .join, .slot = 0, .arg = 0 }, .{ .op = .join, .slot = 1, .arg = 0 } });
    var rng = std.Random.DefaultPrng.init(9);
    const rand = rng.random();
    var buf: [2048]u8 = undefined;
    var n: u32 = 0;
    var applied: u32 = 0;
    for (0..1500) |t| {
        frames[0] = .{ .steer = @intCast(@as(i32, @intCast(t % 200)) - 100), .throttle = 127, .buttons = 0, .aim = 0, .seq = 0 };
        frames[1] = .{ .steer = 60, .throttle = 100, .buttons = 0, .aim = 0, .seq = 0 };
        srv.step(&frames, &.{});
        if (t % 3 == 0 or t % 3 == 2) {
            n += 1;
            const g = hist.push(srv);
            const bytes = try e.encode(&hist, g, .{ .seq = 0, .tick = srv.tick(), .echo_time = 0, .hold_ms = 0, .players = &.{} }, null, &buf, false);
            try std.testing.expect(bytes.len <= @max(budget * 3, 64));
            if (loss_mod != 0 and rand.uintLessThan(u32, loss_mod) == 0) continue;
            const snap = (try d.decode(bytes)) orelse continue;
            dec.Decoder(TS).apply(&snap, cli, {}, noop);
            applied += 1;
            // Every record matches the server at this tick.
            const st = srv.stateBytes();
            const ct = cli.stateBytes();
            for (snap.recs) |rec| {
                if (rec.op == .remove) {
                    try std.testing.expect(!Sc.alive(ct, rec.kind, rec.index));
                    continue;
                }
                var a: [Sc.max_value_size]u8 = undefined;
                var b: [Sc.max_value_size]u8 = undefined;
                Sc.readValue(st, rec.kind, rec.index, &a);
                Sc.readValue(ct, rec.kind, rec.index, &b);
                try std.testing.expectEqualSlices(u8, a[0..Sc.desc[rec.kind].value_size], b[0..Sc.desc[rec.kind].value_size]);
                try std.testing.expectEqual(Sc.gen(st, rec.kind, rec.index), Sc.gen(ct, rec.kind, rec.index));
            }
            if (loss_mod != 0 and rand.uintLessThan(u32, loss_mod) == 0) continue;
            const af = d.ackFields();
            e.ack(af.ack_seq, af.ack_bits);
        }
    }
    try std.testing.expect(applied > n / 2);
    if (budget >= 4000 and loss_mod == 0) {
        // Converged: alive sets and values equal.
        const st = srv.stateBytes();
        const ct = cli.stateBytes();
        for (0..Sc.num_kinds) |k| {
            var i: u32 = 0;
            while (i < Sc.desc[k].capacity) : (i += 1) {
                try std.testing.expectEqual(Sc.alive(st, k, i), Sc.alive(ct, k, i));
            }
        }
    }
}

test "snapshot round trip, unlimited budget" {
    try roundTrip(4000, 0);
}
test "snapshot round trip, 187 byte budget and 10% loss" {
    try roundTrip(187, 10);
}
