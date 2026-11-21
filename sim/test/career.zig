//! Tests: the single-player career (power-ups-death-and-arrest.md,
//! scoring.md with the multiplier, weapons.md 3.7). Workstream G.

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
const eql = h_.eql;
const blk = h_.blk;
const hasEvent = h_.hasEvent;
const TC = @import("../tuning/career.zig");
const career = @import("../sp/career.zig");
const CS = career.State;
const PowerUp = career.PowerUp;
const combo_gap: u32 = @as(u32, T.combo_window) + 1;

/// A small single-player config: no ambient population.
const cfg_sp_small: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 8, .ped_capacity = 24, .projectile_capacity = 32, .pickup_capacity = 4, .map_object_capacity = 8 };
const Sp = simmod.Sim(cfg_sp_small);

/// Two restart zones: one a few blocks from the start, one far away; and
/// an arrest restart zone.
const zones = [_]simmod.level.Zone{
    .{ .kind = .restart, .x = 120, .y = 120, .w = 2, .h = 2, .name = "far" },
    .{ .kind = .restart, .x = 36, .y = 48, .w = 2, .h = 2, .name = "near" },
    .{ .kind = .arrest_restart, .x = 52, .y = 36, .w = 2, .h = 2, .name = "cells" },
};
const lvl: simmod.Level = .{ .zones = &zones };

const H = struct {
    grid: *map.Grid,
    sim: *Sp,
    frames: [1]Frame = .{Frame.neutral(0)},

    fn init() !H {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(Sp);
        s.init(g, .{ .seed = 11, .mode = .authoritative });
        s.attachLevel(&lvl);
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
    fn cs(h: *H) *CS {
        return &h.sim.state.sp.career[0];
    }
    fn me(h: *H) EntityId {
        return h.sim.state.players[0].ped;
    }
    fn ped(h: *H) *c.Pedestrian {
        return h.sim.state.world.get(h.me(), c.Pedestrian).?;
    }
    fn weapon(h: *H) *c.Weapon {
        return h.sim.state.world.get(h.me(), c.Weapon).?;
    }
    fn block(h: *H, id: EntityId) [2]i32 {
        const t = h.sim.state.world.get(id, c.Transform).?;
        return .{ fx.toInt(t.x), fx.toInt(t.y) };
    }
    fn take(h: *H, p: PowerUp) bool {
        return Sp.career.takePowerUp(h.sim, 0, p);
    }
    /// Kill the player (as if hit by `by`) and run the tick that notices.
    fn die(h: *H, by: EntityId) void {
        const hp = h.sim.state.world.get(h.me(), c.Health).?;
        hp.hp = 0;
        hp.last_hit_by = by;
        h.run(1);
    }
    /// A civilian (or `occ`) at block (bx, by), killed by `by`.
    fn killPed(h: *H, bx: u8, by_: u8, occ: simmod.ids.Occupation, by: EntityId) void {
        const v = h.sim.spawnPed(c.Controller.no_player, simmod.spawnHint(bx, by_)).?;
        const w = &h.sim.state.world;
        w.get(v, c.Objective).?.occupation = @intFromEnum(occ);
        const vh = w.get(v, c.Health).?;
        vh.hp = 0;
        vh.last_hit_by = by;
        h.run(2); // a new entity joins the world at the end of a step
    }
};

test "career: a player starts with lives and a multiplier of 1" {
    var h = try H.init();
    defer h.deinit();
    try std.testing.expectEqual(TC.start_lives, Sp.career.lives(h.sim, 0));
    try std.testing.expectEqual(@as(u8, 1), Sp.career.multiplier(h.sim, 0));
    try std.testing.expect(!Sp.career.isOut(h.sim, 0));
    // Unarmed: no deathmatch pistol.
    for (h.weapon().rounds()) |r| try std.testing.expectEqual(@as(u16, 0), r);
    // Lives and multiplier clamp (script-player.md 2.1-2.2).
    Sp.career.addLives(h.sim, 0, -50);
    try std.testing.expectEqual(@as(u8, 0), Sp.career.lives(h.sim, 0));
    Sp.career.addLives(h.sim, 0, 127);
    try std.testing.expectEqual(TC.lives_max, Sp.career.lives(h.sim, 0));
    Sp.career.addMultiplier(h.sim, 0, -10);
    try std.testing.expectEqual(@as(u8, 1), Sp.career.multiplier(h.sim, 0));
    Sp.career.setMultiplier(h.sim, 0, 200);
    try std.testing.expectEqual(TC.multiplier_max, Sp.career.multiplier(h.sim, 0));
}

test "power-ups: every row of the table, and each is refused when full (3-1)" {
    var h = try H.init();
    defer h.deinit();
    // Multiplier and extra life: +1, refused at 99.
    try std.testing.expect(h.take(.multiplier));
    try std.testing.expectEqual(@as(u8, 2), h.cs().multiplier);
    h.cs().multiplier = 99;
    try std.testing.expect(!h.take(.multiplier));
    const lives = h.cs().lives;
    try std.testing.expect(h.take(.extra_life));
    try std.testing.expectEqual(lives + 1, h.cs().lives);
    h.cs().lives = 99;
    try std.testing.expect(!h.take(.extra_life));
    // Health: to full, refused at full.
    try std.testing.expect(!h.take(.health));
    h.sim.state.world.get(h.me(), c.Health).?.hp = 10;
    try std.testing.expect(h.take(.health));
    try std.testing.expectEqual(T.ped_hp, h.sim.state.world.get(h.me(), c.Health).?.hp);
    // Armour: 10 charges, refused at 10.
    try std.testing.expect(h.take(.armour));
    try std.testing.expectEqual(@as(u8, 10), h.ped().armour);
    try std.testing.expect(!h.take(.armour));
    h.ped().armour = 3;
    try std.testing.expect(h.take(.armour));
    try std.testing.expectEqual(@as(u8, 10), h.ped().armour);
    // Jail card: one, refused when held.
    try std.testing.expect(h.take(.jail_card));
    try std.testing.expect(!h.take(.jail_card));
    try std.testing.expectEqual(@as(u8, 1), h.cs().jail_cards);
    // Cop bribe: refused when not wanted.
    try std.testing.expect(!h.take(.cop_bribe));
    h.sim.state.sp.wanted[0].points = 600;
    try std.testing.expect(h.take(.cop_bribe));
    // Timed ones: full length, refused while exactly full, taken again
    // once they have ticked down even once.
    const timed = [_]struct { p: PowerUp, full: u16 }{
        .{ .p = .invulnerability, .full = 1200 },
        .{ .p = .double_damage, .full = 1800 },
        .{ .p = .fast_reload, .full = 1800 },
        .{ .p = .electro_fingers, .full = 2100 },
        .{ .p = .invisibility, .full = 1800 },
    };
    for (timed) |row| {
        try std.testing.expect(h.take(row.p));
        const timer = switch (row.p) {
            .invulnerability => &h.ped().invulnerable,
            .double_damage => &h.ped().double_damage,
            .fast_reload => &h.ped().fast_reload,
            .electro_fingers => &h.cs().electro_fingers,
            else => &h.cs().invisible,
        };
        try std.testing.expectEqual(row.full, timer.*);
        try std.testing.expect(!h.take(row.p));
        h.run(1);
        try std.testing.expectEqual(row.full - 1, timer.*);
        try std.testing.expect(h.take(row.p));
        try std.testing.expectEqual(row.full, timer.*);
    }
    try std.testing.expect(Sp.career.invisible(h.sim, 0));
    try std.testing.expect(Sp.career.electroFingers(h.sim, 0));
    // Respect: refused outside a gang area (no gangs on the test map).
    try std.testing.expect(!h.take(.respect));
    // Instant gang: on foot only.
    try std.testing.expect(h.take(.instant_gang));
    const car = h.sim.spawnCarAt(blk(40), blk(34), 0, 0).?;
    h.sim.board(h.me(), car);
    try std.testing.expect(!h.take(.instant_gang));
}

test "power-ups: invisibility and electro-fingers run out; electro-fingers zaps close peds" {
    var h = try H.init();
    defer h.deinit();
    Sp.career.givePowerUp(h.sim, 0, @intFromEnum(PowerUp.invisibility), 5);
    Sp.career.givePowerUp(h.sim, 0, @intFromEnum(PowerUp.electro_fingers), 3);
    const t = h.sim.state.world.get(h.me(), c.Transform).?.*;
    const victim = h.sim.spawnPed(c.Controller.no_player, simmod.spawnHint(36, 40)).?;
    const w = &h.sim.state.world;
    w.get(victim, c.Transform).?.* = .{ .x = t.x + fx.ratio(3, 10), .y = t.y, .z = t.z, .heading = 0 };
    w.get(victim, c.Pedestrian).?.ai_timer = 1000;
    h.run(1);
    w.get(victim, c.Transform).?.* = .{ .x = t.x + fx.ratio(3, 10), .y = t.y, .z = t.z, .heading = 0 };
    const hp0 = w.get(victim, c.Health).?.hp;
    h.run(1);
    try std.testing.expect(w.get(victim, c.Health).?.hp < hp0);
    try std.testing.expect(eql(w.get(victim, c.Health).?.last_hit_by, h.me()));
    h.run(5);
    try std.testing.expect(!Sp.career.invisible(h.sim, 0));
    try std.testing.expect(!Sp.career.electroFingers(h.sim, 0));
    // The option makes it permanent.
    Sp.career.setOption(h.sim, 0, CS.flag_always_invisible, true);
    try std.testing.expect(Sp.career.invisible(h.sim, 0));
}

test "wasted: a life goes, a double stays, the player respawns at once at the nearest restart zone (3-2, 3-4)" {
    var h = try H.init();
    defer h.deinit();
    const w = &h.sim.state.world;
    const old = h.me();
    h.weapon().rounds()[T.weapon_smg] = 300;
    h.cs().jail_cards = 1;
    h.ped().armour = 5;
    h.ped().double_damage = 100;
    Sp.career.setFrenzyWeapon(h.sim, 0, T.weapon_rocket);
    const lives = h.cs().lives;
    const at = w.get(old, c.Transform).?.*;
    h.die(.none);
    try std.testing.expect(hasEvent(h.sim.events(), .wasted));
    for (h.sim.events()) |e| {
        if (e.kind != .wasted) continue;
        // Where the double lies, for the camera.
        try std.testing.expectEqual(at.x, e.x);
        try std.testing.expectEqual(at.y, e.y);
    }
    try std.testing.expectEqual(lives - 1, h.cs().lives);
    try std.testing.expectEqual(CS.phase_wasted, h.cs().phase);
    try std.testing.expect(Sp.career.isOut(h.sim, 0));
    // The double is the old body, lying there.
    try std.testing.expect(eql(Sp.career.bodyDouble(h.sim, 0), old));
    try std.testing.expect(w.isAlive(old));
    try std.testing.expectEqual(c.Pedestrian.state_down, w.get(old, c.Pedestrian).?.state);
    // The player is already at the near restart zone, in a new body, with
    // his weapons for now.
    const fresh = h.me();
    try std.testing.expect(!eql(fresh, old));
    try std.testing.expectEqual([2]i32{ 37, 49 }, h.block(fresh));
    try std.testing.expect(h.weapon().rounds()[T.weapon_smg] > 0);
    // 70 ticks later: the double is gone; weapons, the frenzy weapon and
    // power-ups go; the jail card stays.
    h.run(TC.countdown_ticks - 2);
    try std.testing.expect(Sp.career.isOut(h.sim, 0));
    h.run(2);
    try std.testing.expect(!Sp.career.isOut(h.sim, 0));
    try std.testing.expect(!w.isAlive(old));
    for (h.weapon().rounds()) |r| try std.testing.expectEqual(@as(u16, 0), r);
    try std.testing.expectEqual(@as(u8, 0), h.ped().armour);
    try std.testing.expectEqual(@as(u16, 0), h.ped().double_damage);
    try std.testing.expectEqual(CS.no_weapon, h.cs().frenzy_weapon);
    try std.testing.expectEqual(@as(u8, 1), h.cs().jail_cards);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[0].deaths);
}

test "wasted: the keep-weapons option keeps them, but not the kill-frenzy weapon" {
    var h = try H.init();
    defer h.deinit();
    Sp.career.setOption(h.sim, 0, CS.flag_keep_weapons, true);
    h.weapon().rounds()[T.weapon_shotgun] = 100;
    Sp.career.setFrenzyWeapon(h.sim, 0, T.weapon_flamethrower);
    h.die(.none);
    h.run(TC.countdown_ticks);
    try std.testing.expectEqual(@as(u16, 100), h.weapon().rounds()[T.weapon_shotgun]);
    try std.testing.expectEqual(@as(u16, 0), h.weapon().rounds()[T.weapon_flamethrower]);
}

test "wasted with no lives left: game over (3-2 step 5)" {
    var h = try H.init();
    defer h.deinit();
    h.cs().lives = 0;
    h.die(.none);
    try std.testing.expect(hasEvent(h.sim.events(), .game_over));
    try std.testing.expect(!hasEvent(h.sim.events(), .wasted));
    try std.testing.expect(h.me().isNone());
    h.run(TC.countdown_ticks + 30);
    try std.testing.expect(Sp.career.isGameOver(h.sim, 0));
    // Nobody respawns him.
    try std.testing.expect(h.me().isNone());
}

test "busted without a jail card: no life lost, weapons gone, multiplier halved (3-3)" {
    var h = try H.init();
    defer h.deinit();
    const w = &h.sim.state.world;
    const old = h.me();
    h.weapon().rounds()[T.weapon_smg] = 300;
    h.cs().multiplier = 5;
    h.ped().armour = 4;
    h.sim.state.sp.wanted[0].points = 2000;
    const lives = h.cs().lives;
    Sp.career.bust(h.sim, 0, .none);
    try std.testing.expect(hasEvent(h.sim.events(), .busted));
    try std.testing.expectEqual(CS.phase_busted, h.cs().phase);
    try std.testing.expect(eql(Sp.career.bodyDouble(h.sim, 0), old));
    try std.testing.expectEqual(c.Pedestrian.state_arrested, w.get(old, c.Pedestrian).?.state);
    // Moved at once, to the arrest restart zone.
    try std.testing.expectEqual([2]i32{ 53, 37 }, h.block(h.me()));
    // A second arrest during the countdown does nothing.
    Sp.career.bust(h.sim, 0, .none);
    h.run(TC.countdown_ticks);
    try std.testing.expect(!Sp.career.isOut(h.sim, 0));
    try std.testing.expectEqual(lives, h.cs().lives);
    try std.testing.expectEqual(@as(u8, 2), h.cs().multiplier);
    try std.testing.expectEqual(@as(u16, 0), h.weapon().rounds()[T.weapon_smg]);
    try std.testing.expectEqual(@as(u8, 0), h.ped().armour);
    try std.testing.expect(!w.isAlive(old));
    // Halved again from 1 stays 1.
    h.cs().multiplier = 1;
    Sp.career.bust(h.sim, 0, .none);
    h.run(TC.countdown_ticks);
    try std.testing.expectEqual(@as(u8, 1), h.cs().multiplier);
}

test "busted with a jail card: the card goes, everything else stays; unlimited keeps the card" {
    var h = try H.init();
    defer h.deinit();
    h.cs().jail_cards = 1;
    h.cs().multiplier = 6;
    h.weapon().rounds()[T.weapon_smg] = 300;
    Sp.career.bust(h.sim, 0, .none);
    h.run(TC.countdown_ticks);
    try std.testing.expectEqual(@as(u8, 0), h.cs().jail_cards);
    try std.testing.expectEqual(@as(u8, 6), h.cs().multiplier);
    try std.testing.expectEqual(@as(u16, 300), h.weapon().rounds()[T.weapon_smg]);
    Sp.career.setOption(h.sim, 0, CS.flag_unlimited_jail, true);
    h.cs().jail_cards = 1;
    Sp.career.bust(h.sim, 0, .none);
    h.run(TC.countdown_ticks);
    try std.testing.expectEqual(@as(u8, 1), h.cs().jail_cards);
    try std.testing.expectEqual(@as(u8, 6), h.cs().multiplier);
}

test "busted with no lives, or in a bonus stage: game over (3-3 step 5)" {
    var h = try H.init();
    defer h.deinit();
    h.cs().lives = 0;
    Sp.career.bust(h.sim, 0, .none);
    h.run(TC.countdown_ticks - 1);
    try std.testing.expect(!Sp.career.isGameOver(h.sim, 0));
    h.run(1);
    try std.testing.expect(hasEvent(h.sim.events(), .game_over));
    try std.testing.expect(Sp.career.isGameOver(h.sim, 0));

    var h2 = try H.init();
    defer h2.deinit();
    Sp.career.setOption(h2.sim, 0, CS.flag_bonus_stage, true);
    Sp.career.bust(h2.sim, 0, .none);
    h2.run(TC.countdown_ticks);
    try std.testing.expect(Sp.career.isGameOver(h2.sim, 0));
}

test "scoring: kills by class, method and combo, times the multiplier (scoring.md 3-1-3-2)" {
    var h = try H.init();
    defer h.deinit();
    h.cs().multiplier = 3;
    const me = h.me();
    // A civilian by weapon: 20 x 3.
    h.killPed(30, 40, .civilian, me);
    try std.testing.expectEqual(@as(i32, 60), Sp.career.score(h.sim, 0));
    try std.testing.expectEqual(@as(i32, 60), h.sim.state.players[0].score);
    // A policeman right after: 200 x combo 2 x 3.
    h.killPed(30, 40, .police, me);
    try std.testing.expectEqual(@as(i32, 60 + 1200), Sp.career.score(h.sim, 0));
    h.run(combo_gap);
    // Each class, by weapon, combo 1.
    const classes = [_]struct { o: simmod.ids.Occupation, p: i32 }{
        .{ .o = .mugger, .p = 40 },
        .{ .o = .car_thief, .p = 40 },
        .{ .o = .gang_member, .p = 50 },
        .{ .o = .emergency, .p = 200 },
        .{ .o = .guard, .p = 200 },
        .{ .o = .swat, .p = 300 },
        .{ .o = .fbi, .p = 400 },
        .{ .o = .army, .p = 500 },
    };
    for (classes) |row| {
        const before = Sp.career.score(h.sim, 0);
        h.killPed(30, 40, row.o, me);
        try std.testing.expectEqual(row.p * 3, Sp.career.score(h.sim, 0) - before);
        h.run(combo_gap);
    }
    // Elvis: 100 by any method, with his own combo.
    var before = Sp.career.score(h.sim, 0);
    h.killPed(30, 40, .elvis, me);
    h.killPed(30, 40, .elvis, me);
    try std.testing.expectEqual(@as(i32, (100 + 200) * 3), Sp.career.score(h.sim, 0) - before);
    h.run(combo_gap);
    // Run over: half; electrocuted: two and a half times.
    const car = h.sim.spawnCarAt(blk(40), blk(34), 0, 0).?;
    h.sim.state.world.get(car, c.Vehicle).?.driver = me;
    before = Sp.career.score(h.sim, 0);
    h.killPed(30, 40, .civilian, car);
    try std.testing.expectEqual(@as(i32, 10 * 3), Sp.career.score(h.sim, 0) - before);
    h.sim.state.world.get(car, c.Vehicle).?.driver = .none;
    h.run(combo_gap);
    before = Sp.career.score(h.sim, 0);
    {
        const v = h.sim.spawnPed(c.Controller.no_player, simmod.spawnHint(30, 40)).?;
        const w = &h.sim.state.world;
        w.get(v, c.Pedestrian).?.shock = T.shock_threshold;
        const vh = w.get(v, c.Health).?;
        vh.hp = 0;
        vh.last_hit_by = me;
        h.run(2);
    }
    try std.testing.expectEqual(@as(i32, 50 * 3), Sp.career.score(h.sim, 0) - before);
    // Script rewards: with and without the multiplier.
    before = Sp.career.score(h.sim, 0);
    Sp.career.addScore(h.sim, 0, 1000, .with_multiplier);
    Sp.career.addScore(h.sim, 0, 1000, .flat);
    try std.testing.expectEqual(@as(i32, 4000), Sp.career.score(h.sim, 0) - before);
}

test "scoring: a wreck pays value x 5 x combo x multiplier, and a background driver inside pays extra" {
    var h = try H.init();
    defer h.deinit();
    h.cs().multiplier = 2;
    const w = &h.sim.state.world;
    const car = h.sim.spawnCarAt(blk(44), blk(34), 0, 0).?;
    const driver = h.sim.spawnPed(c.Controller.no_player, simmod.spawnHint(44, 34)).?;
    h.run(1);
    h.sim.board(driver, car);
    const before = Sp.career.score(h.sim, 0);
    const ch = w.get(car, c.Health).?;
    ch.hp = 0;
    ch.last_hit_by = h.me();
    h.run(2);
    const value = T.carModel(w.get(car, c.Vehicle).?.model).value;
    // Wreck (value x 5) + driver cash (20) + the driver's kill (20), all x 2.
    try std.testing.expectEqual((value * 5 + 20 + 20) * 2, Sp.career.score(h.sim, 0) - before);
}

test "scoring: the multiplier is 1 in deathmatch" {
    var h = try h_.Harness.init(.authoritative);
    defer h.deinit();
    try std.testing.expectEqual(@as(u8, 1), h_.S.career.multiplier(h.sim, 0));
    try std.testing.expect(!h_.S.career.takePowerUp(h.sim, 0, .multiplier));
}

test "car weapons: car guns fire two shots while held and spend ammo" {
    var h = try H.init();
    defer h.deinit();
    const w = &h.sim.state.world;
    const car = h.sim.spawnCarAt(blk(44), blk(34), 0, 0).?;
    h.run(1);
    h.sim.board(h.me(), car);
    try std.testing.expect(Sp.car_weapons.arm(h.sim, car, .car_guns, 5));
    try std.testing.expectEqual(TC.CarWeapon.car_guns, Sp.car_weapons.weaponOf(h.sim, car));
    h.frames[0].buttons = Button.fire;
    h.run(1);
    var it_weapon: u8 = 0;
    const shots = w.count(Sp.Shot);
    try std.testing.expectEqual(@as(u32, 2), shots);
    {
        // Every shot is a car-gun shot owned by the car.
        const Ctx = struct { car: EntityId, ok: *bool, k: *u8 };
        var ok = true;
        w.each(.{c.Projectile}, Ctx{ .car = car, .ok = &ok, .k = &it_weapon }, struct {
            fn f(cx: Ctx, _: EntityId, p: *c.Projectile) void {
                if (!eql(p.owner, cx.car)) cx.ok.* = false;
                cx.k.* = p.weapon;
            }
        }.f);
        try std.testing.expect(ok);
        try std.testing.expectEqual(T.car_shot_base, it_weapon);
    }
    h.run(9);
    // A shot every 2 ticks: 5 pulls in 10 ticks, a tenth each.
    try std.testing.expectEqual(@as(u16, 50 - 5), Sp.car_weapons.armOf(h.sim, car).?.ammo);
    h.frames[0].buttons = 0;
}

test "car weapons: a car bomb needs a fresh press, then destroys the car credited to the armer" {
    var h = try H.init();
    defer h.deinit();
    const w = &h.sim.state.world;
    const car = h.sim.spawnCarAt(blk(44), blk(34), 0, 0).?;
    h.run(1);
    try std.testing.expect(Sp.car_weapons.arm(h.sim, car, .car_bomb, 1));
    // Already full: refused.
    try std.testing.expect(!Sp.car_weapons.arm(h.sim, car, .car_bomb, 1));
    h.frames[0].buttons = Button.fire; // held before getting in
    h.run(1);
    h.sim.board(h.me(), car);
    w.get(car, c.Controller).?.in.buttons = Button.fire;
    h.run(3);
    try std.testing.expect(!Sp.car_weapons.bombArmed(h.sim, car));
    h.frames[0].buttons = 0;
    h.run(1);
    h.frames[0].buttons = Button.fire;
    h.run(1);
    try std.testing.expect(Sp.car_weapons.bombArmed(h.sim, car));
    h.frames[0].buttons = 0;
    h.sim.tryExit(h.me());
    h.run(TC.car_bomb_fuse + 2);
    try std.testing.expect(w.get(car, c.Vehicle).?.flags & c.Vehicle.flag_wrecked != 0);
}

test "car weapons: the tank gun needs a fresh press each shot; disarm removes a fitted weapon" {
    var h = try H.init();
    defer h.deinit();
    const car = h.sim.spawnCarAt(blk(44), blk(34), 0, 0).?;
    h.run(1);
    h.sim.board(h.me(), car);
    try std.testing.expect(Sp.car_weapons.arm(h.sim, car, .tank_gun, 10));
    h.frames[0].buttons = Button.fire;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 1), h.sim.state.world.count(Sp.Shot));
    h.run(60); // held: no second shot
    try std.testing.expectEqual(@as(u16, 90), Sp.car_weapons.armOf(h.sim, car).?.ammo);
    Sp.car_weapons.disarm(h.sim, car);
    try std.testing.expectEqual(TC.CarWeapon.none, Sp.car_weapons.weaponOf(h.sim, car));
    h.frames[0].buttons = 0;
}

test "career: deterministic across save and load mid-countdown" {
    var a = try H.init();
    defer a.deinit();
    a.cs().multiplier = 4;
    a.die(.none);
    a.run(20);
    const buf = try std.testing.allocator.alloc(u8, Sp.state_size);
    defer std.testing.allocator.free(buf);
    _ = a.sim.save(buf);
    var b = try H.init();
    defer b.deinit();
    try b.sim.load(buf);
    a.run(80);
    b.run(80);
    try std.testing.expectEqual(a.sim.hash(), b.sim.hash());
    try std.testing.expect(!Sp.career.isOut(b.sim, 0));
}

test "accuracy: the player's projectile hits are counted by weapon (scoring.md 3-4)" {
    var h = try H.init();
    defer h.deinit();
    const w = &h.sim.state.world;
    const t = w.get(h.me(), c.Transform).?.*;
    const victim = h.sim.spawnPed(c.Controller.no_player, simmod.spawnHint(36, 40)).?;
    h.run(1);
    w.get(victim, c.Transform).?.* = .{ .x = t.x + fx.one, .y = t.y, .z = t.z, .heading = 0 };
    w.get(victim, c.Pedestrian).?.ai_timer = 1000;
    w.get(h.me(), c.Transform).?.heading = 0;
    h.weapon().kind = T.weapon_pistol;
    h.weapon().rounds()[T.weapon_pistol] = 100;
    h.frames[0].buttons = Button.fire;
    h.run(1);
    h.frames[0].buttons = 0;
    h.run(10);
    try std.testing.expectEqual(@as(u16, 1), h.cs().hits_other[T.weapon_pistol]);
    // The script's per-entity hit record saw it too.
    try std.testing.expect(w.get(victim, c.ScriptTag).?.hits & (@as(u32, 1) << T.weapon_pistol) != 0);
}

test "car weapons: mines drop behind the car on a fresh press, credited to the driver" {
    var h = try H.init();
    defer h.deinit();
    const w = &h.sim.state.world;
    const car = h.sim.spawnCarAt(blk(44), blk(34), 0, 0).?;
    h.run(1);
    h.sim.board(h.me(), car);
    try std.testing.expect(Sp.car_weapons.arm(h.sim, car, .mines, 3));
    const before = w.count(Sp.MapObject);
    h.frames[0].buttons = Button.fire;
    h.run(2);
    h.run(5); // held: no second mine
    h.frames[0].buttons = 0;
    try std.testing.expectEqual(before + 1, w.count(Sp.MapObject));
    try std.testing.expectEqual(@as(u16, 20), Sp.car_weapons.armOf(h.sim, car).?.ammo);
    const Ctx = struct { me: EntityId, found: *bool };
    var found = false;
    w.each(.{c.Object}, Ctx{ .me = h.me(), .found = &found }, struct {
        fn f(cx: Ctx, _: EntityId, o: *c.Object) void {
            if (o.kind == @intFromEnum(simmod.ids.ObjectKind.mine) and eql(o.owner, cx.me)) cx.found.* = true;
        }
    }.f);
    try std.testing.expect(found);
}
