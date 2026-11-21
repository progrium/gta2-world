//! Tests: deathmatch with police (`config_16_police`, "dmp16"). The host
//! picks it when the room has police on; `dm16` stays as it is (workstream
//! E; police-ai.md, wanted-level.md).

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const map = h_.map;
const c = h_.c;
const testmap = h_.testmap;
const Frame = h_.Frame;
const hasEvent = h_.hasEvent;
const ids = simmod.ids;
const crew_mod = @import("../ai/police_crew.zig");
const TP = @import("../tuning/police.zig");

const Dmp = simmod.Sim16Police;

test "dm police: dmp16 is a living city with deathmatch rules; dm16 is neither" {
    try std.testing.expect(Dmp.city);
    try std.testing.expect(!Dmp.single_player);
    try std.testing.expect(!simmod.Sim16.city);
    try std.testing.expect(!simmod.Sim16.single_player);
    try std.testing.expectEqual(simmod.config_16.max_players, Dmp.config.max_players);
    try std.testing.expect(Dmp.state_size > simmod.Sim16.state_size);
}

fn dmpSim(slots: u8) !*Dmp {
    const g = try std.testing.allocator.create(map.Grid);
    testmap.build(g);
    const s = try std.testing.allocator.create(Dmp);
    s.init(g, .{ .seed = 33, .mode = .authoritative });
    var frames: [16]Frame = @splat(Frame.neutral(0));
    var cmds: [16]abi.Command = undefined;
    for (0..slots) |i| cmds[i] = .{ .op = .join, .slot = @intCast(i), .arg = simmod.spawnHint(@intCast(30 + 6 * i), 40) };
    s.step(&frames, cmds[0..slots]);
    s.step(&frames, &.{});
    return s;
}
fn freeDmp(s: *Dmp) void {
    std.testing.allocator.destroy(@constCast(s.grid));
    std.testing.allocator.destroy(s);
}
fn run(s: *Dmp, n: u32) void {
    var frames: [16]Frame = @splat(Frame.neutral(0));
    for (0..n) |_| s.step(&frames, &.{});
}
fn crewsFor(s: *Dmp, slot: u8) u32 {
    var n: u32 = 0;
    for (s.state.sp.police.crews) |cr| {
        if (cr.slot != slot) continue;
        if (cr.phase != @intFromEnum(crew_mod.Phase.free) and cr.phase != @intFromEnum(crew_mod.Phase.spawning)) n += 1;
    }
    return n;
}

test "dm police: a wanted player gets a crew; the other player does not" {
    const s = try dmpSim(2);
    defer freeDmp(s);
    Dmp.wanted.setStars(s, 1, 1);
    var n: u32 = 0;
    var siren = false;
    while (n < TP.first_crew_delay + 10 and crewsFor(s, 1) == 0) : (n += 1) {
        run(s, 1);
        if (hasEvent(s.events(), .siren)) siren = true;
    }
    try std.testing.expectEqual(@as(u32, 1), crewsFor(s, 1));
    try std.testing.expectEqual(@as(u32, 0), crewsFor(s, 0));
    try std.testing.expect(siren);
    // Respawned with a clean slate; the other player was never wanted.
    try std.testing.expectEqual(@as(u8, 0), Dmp.wanted.stars(s, 0));
}

test "dm police: an arrest counts as a death (no lives or arrest sequence in deathmatch)" {
    const s = try dmpSim(2);
    defer freeDmp(s);
    Dmp.police.setDispatch(s, false);
    Dmp.wanted.setStars(s, 1, 1);
    const target = s.pedOf(1).?;
    const pt = s.state.world.get(target, c.Transform).?.*;
    const bx: u8 = @intCast(simmod.fx.toInt(pt.x));
    const by: u8 = @intCast(simmod.fx.toInt(pt.y));
    const cop = s.spawnPed(c.Controller.no_player, simmod.spawnHint(bx, by)).?;
    s.state.world.applyPending();
    s.state.world.get(cop, c.Transform).?.* = .{ .x = pt.x + simmod.fx.ratio(1, 2), .y = pt.y, .z = pt.z, .heading = 32768 };
    Dmp.objectives.setOccupation(s, cop, .police);
    for (s.state.world.get(cop, c.Weapon).?.rounds()) |*r| r.* = 0;
    Dmp.objectives.attack(s, cop, target);
    // Weak enough that the next punch is the knock-down: the bust.
    s.state.world.get(target, c.Health).?.hp = 15;
    const deaths0 = s.state.players[1].deaths;
    var n: u32 = 0;
    while (n < 300 and s.state.players[1].deaths == deaths0) : (n += 1) run(s, 1);
    try std.testing.expectEqual(deaths0 + 1, s.state.players[1].deaths);
    // The player respawns and the level is gone with the old ped.
    run(s, 400);
    try std.testing.expect(s.state.players[1].flags & abi.PlayerRow.flag_active != 0);
    try std.testing.expect(!s.state.players[1].ped.isNone());
    try std.testing.expectEqual(@as(u8, 0), Dmp.wanted.stars(s, 1));
}

test "dm police: a full room with police on runs clean (crews, roadblocks, traffic)" {
    const g = try std.testing.allocator.create(map.Grid);
    defer std.testing.allocator.destroy(g);
    testmap.build(g);
    const s = try std.testing.allocator.create(Dmp);
    defer std.testing.allocator.destroy(s);
    s.init(g, .{ .seed = 7, .mode = .authoritative });
    var frames: [16]Frame = @splat(Frame.neutral(0));
    var cmds: [4]abi.Command = undefined;
    for (0..4) |i| cmds[i] = .{ .op = .join, .slot = @intCast(i), .arg = 0 };
    s.step(&frames, &cmds);
    var most: u32 = 0;
    for (0..3000) |t| {
        // Players at different heats, kept up.
        for (0..4) |i| {
            const slot: u8 = @intCast(i);
            if (Dmp.wanted.stars(s, slot) < slot + 1) Dmp.wanted.setStars(s, slot, slot + 1);
        }
        s.step(&frames, &.{});
        if (t % 50 == 0) {
            var live: u32 = 0;
            for (0..4) |i| live += crewsFor(s, @intCast(i));
            most = @max(most, live);
        }
    }
    try std.testing.expect(most >= 3);
}
