//! Tests: wanted level and police (workstream E; wanted-level.md,
//! police-ai.md, script-player.md 2.3).

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const testmap = h_.testmap;
const Button = h_.Button;
const Frame = h_.Frame;
const EntityId = h_.EntityId;
const hasEvent = h_.hasEvent;
const ids = simmod.ids;
const wanted = @import("../sp/wanted.zig");
const police = @import("../sp/police.zig");
const TP = @import("../tuning/police.zig");

/// Single player with no ambient population, so tests control everything.
const cfg_sp_small: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 8, .ped_capacity = 16, .projectile_capacity = 32, .pickup_capacity = 4, .map_object_capacity = 4 };
const Sp = simmod.Sim(cfg_sp_small);

const H = struct {
    grid: *map.Grid,
    sim: *Sp,
    frames: [1]Frame = .{Frame.neutral(0)},

    fn init() !H {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(Sp);
        s.init(g, .{ .seed = 11, .mode = .authoritative });
        var h: H = .{ .grid = g, .sim = s };
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(36, 40) }});
        h.run(1);
        return h;
    }
    fn deinit(h: *H) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    fn run(h: *H, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
    fn player(h: *H) EntityId {
        return h.sim.pedOf(0).?;
    }
    fn stars(h: *H) u8 {
        return Sp.wanted.stars(h.sim, 0);
    }
    fn points(h: *H) u16 {
        return Sp.wanted.points(h.sim, 0);
    }
    fn w(h: *H) *Sp.World {
        return &h.sim.state.world;
    }
    /// A ped of occupation `o` at block (bx, by).
    fn pedAt(h: *H, bx: u8, by: u8, o: ids.Occupation) EntityId {
        const id = h.sim.spawnPed(c.Controller.no_player, simmod.spawnHint(bx, by)).?;
        h.w().applyPending();
        h.w().get(id, c.Objective).?.occupation = @intFromEnum(o);
        return id;
    }
    fn wst(h: *H) *wanted.State {
        return &h.sim.state.sp.wanted[0];
    }
};

test "wanted: the star table and adding points (clamp, script cap, set and raise)" {
    try std.testing.expectEqual(@as(u8, 0), wanted.starsOf(599));
    try std.testing.expectEqual(@as(u8, 1), wanted.starsOf(600));
    try std.testing.expectEqual(@as(u8, 2), wanted.starsOf(1600));
    try std.testing.expectEqual(@as(u8, 3), wanted.starsOf(4999));
    try std.testing.expectEqual(@as(u8, 4), wanted.starsOf(5000));
    try std.testing.expectEqual(@as(u8, 5), wanted.starsOf(8000));
    try std.testing.expectEqual(@as(u8, 6), wanted.starsOf(12000));

    var h = try H.init();
    defer h.deinit();
    Sp.wanted.addPoints(h.sim, 0, -50);
    try std.testing.expectEqual(@as(u16, 0), h.points());
    Sp.wanted.addPoints(h.sim, 0, 20000);
    try std.testing.expectEqual(@as(u16, 12000), h.points());
    // A cap of 3 stars brings 6 stars down to the 3-star total.
    Sp.wanted.setCap(h.sim, 0, 3);
    try std.testing.expectEqual(@as(u16, 3000), h.points());
    Sp.wanted.addPoints(h.sim, 0, 1999);
    try std.testing.expectEqual(@as(u16, 4999), h.points()); // still 3 stars
    Sp.wanted.addPoints(h.sim, 0, 1);
    try std.testing.expectEqual(@as(u16, 3000), h.points());
    Sp.wanted.setCap(h.sim, 0, 6);
    Sp.wanted.setStars(h.sim, 0, 5);
    try std.testing.expectEqual(@as(u8, 5), h.stars());
    Sp.wanted.setStars(h.sim, 0, 2); // 164 lowers
    try std.testing.expectEqual(@as(u16, 1600), h.points());
    Sp.wanted.raiseToStars(h.sim, 0, 1); // 421 never lowers
    try std.testing.expectEqual(@as(u8, 2), h.stars());
    Sp.wanted.setStars(h.sim, 0, 7); // out of range: ignored
    try std.testing.expectEqual(@as(u8, 2), h.stars());
    Sp.wanted.atLeastOneStar(h.sim, 0);
    try std.testing.expectEqual(@as(u8, 2), h.stars());
    Sp.wanted.clear(h.sim, 0);
    Sp.wanted.atLeastOneStar(h.sim, 0);
    try std.testing.expectEqual(@as(u16, 600), h.points());
    // A cap of 0 holds the level at none.
    Sp.wanted.setCap(h.sim, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), h.points());
    Sp.wanted.atLeastOneStar(h.sim, 0);
    try std.testing.expectEqual(@as(u16, 0), h.points());
}

test "wanted: a star change is an event (slot, now, before)" {
    var h = try H.init();
    defer h.deinit();
    h.sim.scratch.event_len = 0;
    Sp.wanted.setStars(h.sim, 0, 3);
    const e = h.sim.events()[0];
    try std.testing.expectEqual(Sp.Event.Kind.wanted, e.kind);
    try std.testing.expectEqual(@as(u8, 3), e.b);
    try std.testing.expectEqual(@as(u8, 0), e.c);
}

test "wanted: kills by the player (+100 ordinary, +500 cop or medic, +1 gang)" {
    var h = try H.init();
    defer h.deinit();
    const me = h.player();
    const civ = h.pedAt(30, 40, .civilian);
    const cop = h.pedAt(30, 41, .police);
    const medic = h.pedAt(30, 42, .emergency);
    const gang = h.pedAt(31, 40, .gang_member);
    const member = h.pedAt(31, 41, .gang_member);
    Sp.wanted.onKill(h.sim, civ, me);
    try std.testing.expectEqual(@as(u16, 100), h.points());
    Sp.wanted.onKill(h.sim, cop, me);
    try std.testing.expectEqual(@as(u16, 600), h.points());
    Sp.wanted.onKill(h.sim, medic, me);
    try std.testing.expectEqual(@as(u16, 1100), h.points());
    Sp.wanted.onKill(h.sim, gang, me);
    try std.testing.expectEqual(@as(u16, 1101), h.points());
    Sp.wanted.onKill(h.sim, member, me);
    try std.testing.expectEqual(@as(u16, 1102), h.points());
    // Nobody's kill, or your own death: nothing.
    Sp.wanted.onKill(h.sim, civ, .none);
    Sp.wanted.onKill(h.sim, me, me);
    try std.testing.expectEqual(@as(u16, 1102), h.points());
}

test "wanted: a real kill goes through scoring into the wanted points" {
    var h = try H.init();
    defer h.deinit();
    const civ = h.pedAt(30, 40, .civilian);
    h.sim.killPed(civ, h.player());
    h.run(2);
    try std.testing.expectEqual(@as(u16, 100), h.points());
}

test "wanted: destroying a car (one star, then +200 when wanted; never crushed)" {
    var h = try H.init();
    defer h.deinit();
    const car = h.sim.spawnCarAt(h_.blk(30), h_.blk(44), 0, 0).?;
    const v = h.w().get(car, c.Vehicle).?;
    Sp.wanted.onCarDestroyed(h.sim, v, h.player(), true);
    try std.testing.expectEqual(@as(u16, 0), h.points());
    Sp.wanted.onCarDestroyed(h.sim, v, h.player(), false);
    try std.testing.expectEqual(@as(u16, 600), h.points());
    Sp.wanted.onCarDestroyed(h.sim, v, h.player(), false);
    try std.testing.expectEqual(@as(u16, 800), h.points());
}

test "wanted: driving into a police car over 0.6 gets a star" {
    var h = try H.init();
    defer h.deinit();
    const mine = h.sim.spawnCarAt(h_.blk(30), h_.blk(44), 0, 0).?;
    const theirs = h.sim.spawnCarAt(h_.blk(33), h_.blk(44), 0, 0).?;
    const civ_car = h.sim.spawnCarAt(h_.blk(36), h_.blk(44), 0, 0).?;
    const cop = h.pedAt(30, 41, .police);
    h.w().get(mine, c.Vehicle).?.driver = h.player();
    h.w().get(theirs, c.Vehicle).?.driver = cop;
    try std.testing.expect(Sp.wanted.isLawCar(h.sim, theirs));
    try std.testing.expect(!Sp.wanted.isLawCar(h.sim, civ_car));
    Sp.wanted.onCarImpact(h.sim, civ_car, mine, fx.one, false);
    try std.testing.expectEqual(@as(u16, 0), h.points());
    Sp.wanted.onCarImpact(h.sim, theirs, mine, TP.ram_cop_impact, false);
    try std.testing.expectEqual(@as(u16, 0), h.points()); // not over 0.6
    Sp.wanted.onCarImpact(h.sim, mine, theirs, fx.one, false); // the cop hitting you
    try std.testing.expectEqual(@as(u16, 0), h.points());
    Sp.wanted.onCarImpact(h.sim, theirs, mine, TP.ram_cop_impact + 1, false);
    try std.testing.expectEqual(@as(u16, 600), h.points());
    Sp.wanted.clear(h.sim, 0);
    Sp.wanted.onCarImpact(h.sim, theirs, mine, 0, true); // crushing
    try std.testing.expectEqual(@as(u16, 600), h.points());
}

test "wanted: crime reports (de-duplicated shots, cops exempt, last known position)" {
    var h = try H.init();
    defer h.deinit();
    const cop = h.pedAt(10, 10, .police); // out of view
    var buf: [TP.report_ring]wanted.Report = undefined;
    Sp.wanted.onShot(h.sim, cop);
    try std.testing.expectEqual(@as(usize, 0), Sp.wanted.reports(h.sim, &buf));
    Sp.wanted.onShot(h.sim, h.player());
    Sp.wanted.onShot(h.sim, h.player());
    try std.testing.expectEqual(@as(usize, 1), Sp.wanted.reports(h.sim, &buf));
    try std.testing.expectEqual(TP.recent_crime_ticks, h.wst().recent);
    try std.testing.expectEqual(h.sim.transformOf(h.player()).?.x, h.wst().last_x);
    Sp.wanted.reportCrime(h.sim, .ped_hurt, h.player(), 0, 0, 0);
    Sp.wanted.reportCrime(h.sim, .ped_hurt, h.player(), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), Sp.wanted.reports(h.sim, &buf));
    // The ring overwrites the oldest.
    for (0..TP.report_ring) |_| Sp.wanted.reportCrime(h.sim, .car_stolen, h.player(), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, TP.report_ring), Sp.wanted.reports(h.sim, &buf));
    try std.testing.expectEqual(@intFromEnum(wanted.Crime.car_stolen), buf[0].crime);
    // Reports live through the tick after the one they were filed in.
    h.run(2);
    try std.testing.expectEqual(@as(usize, TP.report_ring), Sp.wanted.reports(h.sim, &buf));
    h.run(1);
    try std.testing.expectEqual(@as(usize, 0), Sp.wanted.reports(h.sim, &buf));
    // Filing shows no stars by itself.
    try std.testing.expectEqual(@as(u8, 0), h.stars());
}

test "wanted: shooting near a cop gets one star; far from him, none" {
    var h = try H.init();
    defer h.deinit();
    const far = h.pedAt(10, 10, .police);
    _ = far;
    h.frames[0].buttons = Button.fire;
    h.run(10);
    h.frames[0].buttons = 0;
    try std.testing.expectEqual(@as(u8, 0), h.stars());
    const t = h.sim.transformOf(h.player()).?;
    const near = h.pedAt(@intCast(fx.toInt(t.x) - 2), @intCast(fx.toInt(t.y)), .police);
    _ = near;
    h.run(1); // the recent-crime timer is still running
    try std.testing.expectEqual(@as(u8, 1), h.stars());
    try std.testing.expectEqual(t.x, h.wst().last_x);
}

test "wanted: a cop ignores an innocent player, and anyone mid-jump" {
    var h = try H.init();
    defer h.deinit();
    const t = h.sim.transformOf(h.player()).?;
    const cop = h.pedAt(@intCast(fx.toInt(t.x) - 2), @intCast(fx.toInt(t.y)), .police);
    h.run(30);
    try std.testing.expectEqual(@as(u8, 0), h.stars());
    h.wst().recent = 100;
    h.w().get(h.player(), c.Pedestrian).?.jump = 5;
    try std.testing.expect(!Sp.wanted.copSees(h.sim, cop, 0));
    h.w().get(h.player(), c.Pedestrian).?.jump = 0;
    try std.testing.expect(Sp.wanted.copSees(h.sim, cop, 0));
    try std.testing.expectEqual(@as(u8, 1), h.stars());
    // Hitting a cop is enough for him.
    Sp.wanted.clear(h.sim, 0);
    h.w().get(cop, c.Health).?.last_hit_by = h.player();
    try std.testing.expect(Sp.wanted.copSees(h.sim, cop, 0));
}

test "wanted: one star wears off after 900 quiet ticks; two stars do not" {
    var h = try H.init();
    defer h.deinit();
    Sp.wanted.atLeastOneStar(h.sim, 0);
    h.run(TP.one_star_timeout - 1);
    try std.testing.expectEqual(@as(u8, 1), h.stars());
    h.run(1);
    try std.testing.expectEqual(@as(u8, 0), h.stars());
    try std.testing.expectEqual(wanted.Pursuit.idle, Sp.police.pursuitOf(h.sim, 0));
    try std.testing.expectEqual(TP.new_car_cap_reset, h.sim.state.sp.police.new_car_cap);
    Sp.wanted.setStars(h.sim, 0, 2);
    h.run(TP.one_star_timeout * 2);
    try std.testing.expectEqual(@as(u8, 2), h.stars());
}

test "wanted: no police clears the level every tick; a respawn clears it" {
    var h = try H.init();
    defer h.deinit();
    Sp.wanted.setStars(h.sim, 0, 4);
    Sp.wanted.setNoPolice(h.sim, 0, true);
    h.run(1);
    try std.testing.expectEqual(@as(u8, 0), h.stars());
    Sp.wanted.setNoPolice(h.sim, 0, false);
    Sp.wanted.setStars(h.sim, 0, 4);
    const before = h.player();
    h.sim.killPed(before, .none);
    var n: u32 = 0;
    while (n < 400) : (n += 1) {
        h.run(1);
        if (h.sim.pedOf(0)) |p| if (!h_.eql(p, before)) break;
    }
    try std.testing.expect(n < 400);
    h.run(1);
    try std.testing.expectEqual(@as(u8, 0), h.stars());
}

test "police: crew targets per tier, and the pursuit states" {
    const p = @intFromEnum(ids.Occupation.police);
    try std.testing.expectEqual(police.Targets{ .crews = 1, .kind = p, .new_cars = 1 }, police.targetsFor(1, 0));
    try std.testing.expectEqual(@as(u8, 0), police.targetsFor(1, 1).new_cars);
    try std.testing.expectEqual(@as(u8, 2), police.targetsFor(3, 1).new_cars);
    try std.testing.expectEqual(@as(u8, 0), police.targetsFor(3, 2).new_cars);
    try std.testing.expectEqual(@intFromEnum(ids.Occupation.swat), police.targetsFor(4, 0).kind);
    try std.testing.expectEqual(@as(u8, 0), police.targetsFor(5, 0).crews);
    try std.testing.expectEqual(@as(u8, 0), police.targetsFor(6, 0).new_cars);

    var h = try H.init();
    defer h.deinit();
    Sp.wanted.setStars(h.sim, 0, 2);
    h.run(1);
    try std.testing.expectEqual(wanted.Pursuit.responding, Sp.police.pursuitOf(h.sim, 0));
    try std.testing.expectEqual(@as(u8, 2), h.wst().crews_wanted);
    // A cop sees the player: active, the sight clock full.
    const t = h.sim.transformOf(h.player()).?;
    const cop = h.pedAt(@intCast(fx.toInt(t.x) - 2), @intCast(fx.toInt(t.y)), .police);
    h.run(1);
    try std.testing.expectEqual(wanted.Pursuit.active, Sp.police.pursuitOf(h.sim, 0));
    // Out of sight for 250 ticks: searching.
    h.w().despawn(cop);
    h.w().applyPending();
    h.run(TP.sight_ticks + 1);
    try std.testing.expectEqual(wanted.Pursuit.searching, Sp.police.pursuitOf(h.sim, 0));
    Sp.wanted.setStars(h.sim, 0, 5);
    h.run(1);
    try std.testing.expectEqual(@intFromEnum(ids.Occupation.fbi), h.wst().top_kind);
    Sp.wanted.clear(h.sim, 0);
    h.run(1);
    try std.testing.expectEqual(wanted.Pursuit.idle, Sp.police.pursuitOf(h.sim, 0));
}

test "wanted: the API does nothing outside single player" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    const before = h.sim.hash();
    const S = h_.S;
    S.wanted.setStars(h.sim, 0, 3);
    S.wanted.raiseToStars(h.sim, 0, 3);
    S.wanted.setNoPolice(h.sim, 0, true);
    S.wanted.onShot(h.sim, h.sim.pedOf(0).?);
    S.wanted.onKill(h.sim, h.sim.pedOf(0).?, .none);
    S.wanted.onCarImpact(h.sim, .none, .none, fx.one, true);
    _ = S.wanted.copSees(h.sim, .none, 0);
    S.police.sighted(h.sim, 0);
    try std.testing.expectEqual(@as(u8, 0), S.wanted.stars(h.sim, 0));
    try std.testing.expectEqual(before, h.sim.hash());
}
