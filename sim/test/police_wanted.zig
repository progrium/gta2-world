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
    Sp.police.setDispatch(h.sim, false); // no crew ever pursues
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

// --- Crews (police-ai.md) ----------------------------------------------------

const crew_mod = @import("../ai/police_crew.zig");

/// A city-sized single-player config for crews: room for their cars and
/// officers, still no ambient population.
const cfg_sp_crews: abi.Config = .{ .name = "sp_crews", .max_players = 1, .car_capacity = 16, .ped_capacity = 48, .projectile_capacity = 128, .pickup_capacity = 4, .map_object_capacity = 4 };
const Spc = simmod.Sim(cfg_sp_crews);

fn crewSim() !*Spc {
    const g = try std.testing.allocator.create(map.Grid);
    testmap.build(g);
    const s = try std.testing.allocator.create(Spc);
    s.init(g, .{ .seed = 21, .mode = .authoritative });
    var frames = [_]Frame{Frame.neutral(0)};
    s.step(&frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(36, 40) }});
    s.step(&frames, &.{});
    return s;
}
fn freeCrewSim(s: *Spc) void {
    std.testing.allocator.destroy(@constCast(s.grid));
    std.testing.allocator.destroy(s);
}
fn runC(s: *Spc, n: u32) void {
    var frames = [_]Frame{Frame.neutral(0)};
    for (0..n) |_| s.step(&frames, &.{});
}
fn liveCrews(s: *Spc) u32 {
    var n: u32 = 0;
    for (s.state.sp.police.crews) |cr| {
        if (cr.phase != @intFromEnum(crew_mod.Phase.free) and cr.phase != @intFromEnum(crew_mod.Phase.spawning)) n += 1;
    }
    return n;
}

test "police: a wanted player gets a crew after the 200-tick delay: a car with two officers, siren on" {
    const s = try crewSim();
    defer freeCrewSim(s);
    Spc.wanted.setStars(s, 0, 1);
    runC(s, 1);
    try std.testing.expectEqual(@as(u32, 0), liveCrews(s));
    var saw_siren = false;
    var n: u32 = 0;
    while (n < TP.first_crew_delay + 5 and liveCrews(s) == 0) : (n += 1) {
        runC(s, 1);
        if (hasEvent(s.events(), .siren)) saw_siren = true;
    }
    try std.testing.expectEqual(@as(u32, 1), liveCrews(s));
    try std.testing.expect(saw_siren);
    try std.testing.expect(n >= TP.first_crew_delay - 2);
    const cr = s.state.sp.police.crews[0];
    try std.testing.expect(Spc.police.ownsCar(s, cr.car));
    try std.testing.expect(Spc.wanted.isLawCar(s, cr.car));
    try std.testing.expect(s.state.world.get(cr.car, c.Vehicle).?.ai_flags & c.Vehicle.ai_emergency != 0);
    for (cr.members[0..TP.police_crew_size]) |m| {
        try std.testing.expectEqual(ids.Occupation.police, Spc.objectives.occupationOf(s, m));
        try std.testing.expect(h_.eql(s.state.world.get(m, c.Riding).?.vehicle, cr.car));
        try std.testing.expectEqual(TP.police_hp_low, s.state.world.get(m, c.Health).?.hp);
    }
    try std.testing.expect(cr.members[2].isNone());
    // One star wants one crew: no second one.
    runC(s, TP.backup_crew_delay * 3);
    try std.testing.expect(liveCrews(s) <= 1);
    // Cleared: the crew goes home and its car rejoins traffic.
    const car = cr.car;
    Spc.wanted.clear(s, 0);
    runC(s, 1);
    try std.testing.expectEqual(@as(u32, 0), liveCrews(s));
    try std.testing.expect(!Spc.police.ownsCar(s, car));
}

test "police: two stars want two crews; five stars send police home" {
    const s = try crewSim();
    defer freeCrewSim(s);
    Spc.wanted.setStars(s, 0, 2);
    runC(s, TP.first_crew_delay + TP.backup_crew_delay + 10);
    try std.testing.expectEqual(@as(u32, 2), liveCrews(s));
    for (s.state.sp.police.crews[0..2]) |cr| try std.testing.expectEqual(TP.police_hp, s.state.world.get(cr.members[0], c.Health).?.hp);
    Spc.wanted.setStars(s, 0, 5);
    runC(s, 2);
    try std.testing.expectEqual(@as(u32, 0), liveCrews(s));
    runC(s, TP.first_crew_delay + 10);
    try std.testing.expectEqual(@as(u32, 0), liveCrews(s));
}

test "police: four stars add one SWAT crew of four once the pursuit is active" {
    const s = try crewSim();
    defer freeCrewSim(s);
    Spc.wanted.setStars(s, 0, 4);
    runC(s, 1);
    Spc.police.sighted(s, 0); // a cop has seen him
    var n: u32 = 0;
    var swat: ?crew_mod.Crew = null;
    while (n < 600 and swat == null) : (n += 1) {
        runC(s, 1);
        Spc.police.sighted(s, 0);
        for (s.state.sp.police.crews) |cr| {
            if (cr.kind == @intFromEnum(ids.Occupation.swat) and !cr.car.isNone()) swat = cr;
        }
    }
    const cr = swat orelse return error.NoSwat;
    for (cr.members) |m| try std.testing.expectEqual(TP.swat_hp, s.state.world.get(m, c.Health).?.hp);
    try std.testing.expectEqual(T.weapon_smg, s.state.world.get(cr.members[0], c.Weapon).?.kind);
}

test "police: a ram on the target's car adds 500 damage, once per cooldown" {
    const s = try crewSim();
    defer freeCrewSim(s);
    const mine = s.spawnCarAt(h_.blk(30), h_.blk(44), 0, 0).?;
    s.state.players[0].car = mine;
    Spc.wanted.setStars(s, 0, 3);
    runC(s, TP.first_crew_delay + 5);
    const cr = &s.state.sp.police.crews[0];
    try std.testing.expect(!cr.car.isNone());
    const hp0 = s.state.world.get(mine, c.Health).?.hp;
    Spc.police.onImpact(s, mine, cr.car); // not ramming: nothing extra
    try std.testing.expectEqual(hp0, s.state.world.get(mine, c.Health).?.hp);
    cr.phase = @intFromEnum(crew_mod.Phase.chasing);
    cr.step = @intFromEnum(crew_mod.Step.ram);
    Spc.police.onImpact(s, mine, cr.car);
    try std.testing.expectEqual(hp0 - TP.ram_damage, s.state.world.get(mine, c.Health).?.hp);
    Spc.police.onImpact(s, mine, cr.car);
    try std.testing.expectEqual(hp0 - TP.ram_damage, s.state.world.get(mine, c.Health).?.hp);
}

test "police: a one-star player on foot is chased down and arrested or shot by the crew" {
    const s = try crewSim();
    defer freeCrewSim(s);
    Spc.career.start(s, 0);
    Spc.wanted.setStars(s, 0, 1);
    var n: u32 = 0;
    var out = false;
    var saw_officer_out = false;
    while (n < 3000) : (n += 1) {
        runC(s, 1);
        // Stay wanted: keep the timeout away.
        if (Spc.wanted.stars(s, 0) == 0 and !Spc.career.isOut(s, 0)) Spc.wanted.setStars(s, 0, 1);
        for (s.state.sp.police.crews) |cr| {
            if (cr.phase == @intFromEnum(crew_mod.Phase.on_foot)) saw_officer_out = true;
        }
        if (Spc.career.isOut(s, 0)) {
            out = true;
            break;
        }
    }
    try std.testing.expect(saw_officer_out);
    try std.testing.expect(out);
}

test "police: a roadblock goes up across the road at three stars, and comes down unseen and far" {
    const s = try crewSim();
    defer freeCrewSim(s);
    s.state.sp.police.flags |= @import("../sp/police.zig").State.flag_no_dispatch;
    const route = @import("../ai/route.zig");
    // A road block with a lane arrow near the player.
    const n = Spc.route.nearestRoadTo(s, 36, 40, 1).?;
    const arrows = map.arrowsOf(map.cellAt(s.grid, n.x, n.y, n.l));
    var dir: u2 = 0;
    while (dir < 3 and arrows & route.dir_arrow[dir] == 0) dir += 1;
    // Below three stars: no.
    Spc.wanted.setStars(s, 0, 2);
    runC(s, 1);
    try std.testing.expect(!Spc.police.tryRoadblock(s, n.x, n.y, n.l, dir));
    Spc.wanted.setStars(s, 0, 3);
    runC(s, 1);
    try std.testing.expect(Spc.police.tryRoadblock(s, n.x, n.y, n.l, dir));
    const rb = s.state.sp.police.roadblocks[0];
    try std.testing.expectEqual(@as(u8, 1), rb.active);
    try std.testing.expect(!rb.cars[0].isNone());
    try std.testing.expect(Spc.police.ownsCar(s, rb.cars[0]));
    try std.testing.expect(Spc.wanted.isLawCar(s, rb.cars[0]));
    // The cooldown holds the next one back.
    try std.testing.expect(!Spc.police.tryRoadblock(s, n.x, n.y, n.l, dir));
    // The player goes far away: torn down after 200 unseen ticks.
    const t = s.transformOf(s.pedOf(0).?).?;
    t.x = fx.fromInt(n.x + 60);
    runC(s, TP.roadblock_unseen_ticks + 2);
    try std.testing.expectEqual(@as(u8, 0), s.state.sp.police.roadblocks[0].active);
}
