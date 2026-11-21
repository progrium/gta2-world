//! Tests: Weapons, pickups, power-ups, explosions.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const input = h_.input;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const testmap = h_.testmap;
const Button = h_.Button;
const Frame = h_.Frame;
const EntityId = h_.EntityId;
const eql = h_.eql;
const cfg_small = h_.cfg_small;
const S = h_.S;
const Harness = h_.Harness;
const blk = h_.blk;
const hasEvent = h_.hasEvent;
const flood = h_.flood;
const arm = h_.arm;
const shotCount = h_.shotCount;

test "pickups give weapons; the machine gun runs dry back to the pistol" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 36, 40);
    const ped = h.sim.pedOf(0).?;
    const wpn = h.sim.state.world.get(ped, c.Weapon).?;
    try std.testing.expectEqual(T.weapon_pistol, wpn.kind);
    // weapon_next with only the pistol keeps the pistol.
    h.tap(0, Button.weapon_next);
    try std.testing.expectEqual(T.weapon_pistol, wpn.kind);
    const t = h.ped(0).*;
    _ = h.sim.spawnPickupAt(t.x, t.y, T.weapon_smg).?;
    h.run(1);
    try std.testing.expect(hasEvent(h.sim.events(), .pickup));
    try std.testing.expectEqual(T.weapon_smg, wpn.kind);
    try std.testing.expectEqual(T.weapons[T.weapon_smg].pickup_rounds * 10, wpn.rounds()[T.weapon_smg]);
    try std.testing.expectEqual(@as(u32, 0), h.sim.state.world.count(S.Pickup));
    // Cycling goes to the pistol and back.
    h.tap(0, Button.weapon_next);
    try std.testing.expectEqual(T.weapon_pistol, wpn.kind);
    h.tap(0, Button.weapon_prev);
    try std.testing.expectEqual(T.weapon_smg, wpn.kind);
    // Empty the machine gun (into the building next door).
    h.frames[0].buttons = Button.fire;
    const smg = T.weapons[T.weapon_smg];
    h.run(@as(u32, smg.cooldown) * smg.pickup_rounds * 10 / smg.tenths_per_pull + 10);
    h.frames[0].buttons = 0;
    try std.testing.expectEqual(@as(u16, 0), wpn.rounds()[T.weapon_smg]);
    try std.testing.expectEqual(T.weapon_pistol, wpn.kind);
    // A health pack is left when not needed.
    _ = h.sim.spawnPickupAt(t.x, t.y, T.pickup_health).?;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 1), h.sim.state.world.count(S.Pickup));
    // A new weapon goes into the hand even when another one is held.
    wpn.rounds()[T.weapon_smg] = 50;
    wpn.kind = T.weapon_smg;
    _ = h.sim.spawnPickupAt(t.x + fx.one / 4, t.y, T.weapon_shotgun).?;
    h.run(1);
    try std.testing.expectEqual(T.weapon_shotgun, wpn.kind);
    // More rounds for a weapon you have leave the hand alone.
    _ = h.sim.spawnPickupAt(t.x + fx.one / 4, t.y, T.weapon_smg).?;
    h.run(1);
    try std.testing.expectEqual(T.weapon_shotgun, wpn.kind);
}

test "a rocket kills another player and credits the shooter; your own costs a frag" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.join(1, 33, 66);
    const w = &h.sim.state.world;
    const ped0 = h.sim.pedOf(0).?;
    h.ped(0).heading = 16384; // down the road toward slot 1
    const wpn = w.get(ped0, c.Weapon).?;
    wpn.rounds()[T.weapon_rocket] = 40;
    wpn.kind = T.weapon_rocket;
    h.frames[0].buttons = Button.fire;
    h.run(1);
    h.frames[0].buttons = 0;
    var saw_kill = false;
    for (0..90) |_| {
        h.run(1);
        for (h.sim.events()) |e| {
            if (e.kind == .kill) {
                try std.testing.expectEqual(@as(u8, 0), e.a);
                try std.testing.expectEqual(@as(u8, 1), e.b);
                try std.testing.expectEqual(T.weapon_rocket, e.c);
                saw_kill = true;
            }
        }
    }
    try std.testing.expect(saw_kill);
    try std.testing.expect(h.sim.scratch.stats.explosions >= 1);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[0].kills);
    // Points: 2000 for a player killed by weapon (and any bystanders).
    const points = h.sim.state.players[0].score;
    try std.testing.expect(points >= T.points_player_weapon);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[1].deaths);
    // Now point-blank at a building wall: the blast kills the shooter.
    const t0 = h.ped(0);
    // Within half the blast radius a player is killed (further out, but
    // inside it, only knocked down).
    t0.x = fx.fromInt(37) + fx.ratio(3, 4);
    t0.y = blk(41);
    t0.heading = 0; // +x: building wall at x = 38
    h.frames[0].buttons = Button.fire;
    h.run(1);
    h.frames[0].buttons = 0;
    h.run(60);
    try std.testing.expect(h.sim.pedOf(0) == null);
    // Your own death costs a frag; points are kept.
    try std.testing.expectEqual(@as(i32, 0), h.sim.state.players[0].kills);
    try std.testing.expect(h.sim.state.players[0].score >= points);
}

test "a shot-up car catches fire, explodes and burns out" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 61);
    const car = h.sim.spawnCarAt(blk(33), fx.fromInt(60) + fx.ratio(3, 10), 0, 0).?;
    const w = &h.sim.state.world;
    // Damage at the larger fire: it burns on by itself until it explodes.
    w.get(car, c.Health).?.hp = T.car_damage_max - T.car_fire2_damage;
    h.run(1);
    const v = w.get(car, c.Vehicle).?;
    try std.testing.expect(v.flags & c.Vehicle.flag_burning != 0);
    var ticks: u32 = 0;
    while (v.flags & c.Vehicle.flag_wrecked == 0 and ticks < 200) : (ticks += 1) h.run(1);
    try std.testing.expect(v.flags & c.Vehicle.flag_wrecked != 0);
    try std.testing.expectEqual(@as(u64, 1), h.sim.scratch.stats.explosions);
    // The player 1.2 blocks away (inside twice the radius) is knocked over,
    // then gets up; the wreck cannot be entered.
    const ped = h.sim.pedOf(0).?;
    h.run(2);
    try std.testing.expectEqual(c.Pedestrian.state_over, w.get(ped, c.Pedestrian).?.state);
    h.run(60);
    try std.testing.expectEqual(c.Pedestrian.state_up, w.get(ped, c.Pedestrian).?.state);
    try std.testing.expectEqual(T.ped_hp, w.get(ped, c.Health).?.hp);
    h.ped(0).* = .{ .x = blk(33), .y = blk(61), .z = h.ped(0).z, .heading = 16384 * 3 };
    h.tap(0, Button.enter_exit);
    try std.testing.expect(w.get(ped, c.Riding).?.vehicle.isNone());
    h.run(T.wreck_ticks + 2);
    try std.testing.expect(!w.isAlive(car));
}

test "dual pistols fire two bullets; fast reload halves the wait" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.ped(0).heading = 16384;
    const wpn = arm(&h, 0, T.weapon_dual_pistol, 100);
    h.frames[0].buttons = Button.fire;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 2), shotCount(&h));
    try std.testing.expectEqual(@as(u16, 90), wpn.rounds()[T.weapon_dual_pistol]);
    try std.testing.expectEqual(T.weapons[T.weapon_dual_pistol].cooldown, wpn.cooldown);
    h.frames[0].buttons = 0;
    h.run(30);
    h.sim.state.world.get(h.sim.pedOf(0).?, c.Pedestrian).?.fast_reload = T.fast_reload_ticks;
    h.frames[0].buttons = Button.fire;
    h.run(1);
    try std.testing.expectEqual(T.weapons[T.weapon_dual_pistol].cooldown / 2, wpn.cooldown);
}

test "a held grenade is thrown on release and goes off on its fuse" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.ped(0).heading = 16384;
    const wpn = arm(&h, 0, T.weapon_grenade, 30);
    h.frames[0].buttons = Button.fire;
    h.run(40);
    try std.testing.expectEqual(@as(u32, 0), shotCount(&h));
    h.frames[0].buttons = 0;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 1), shotCount(&h));
    try std.testing.expectEqual(@as(u16, 20), wpn.rounds()[T.weapon_grenade]);
    const y0 = h.ped(0).y;
    const before = h.sim.scratch.stats.explosions;
    h.run(T.grenadeFuse(40) + 2);
    try std.testing.expectEqual(before + 1, h.sim.scratch.stats.explosions);
    _ = y0;
    // Held to 96, the next one goes off in the hand.
    h.frames[0].buttons = Button.fire;
    h.run(T.grenade_in_hand + 1);
    h.frames[0].buttons = 0;
    h.run(1);
    try std.testing.expectEqual(before + 2, h.sim.scratch.stats.explosions);
    try std.testing.expectEqual(@as(u16, 10), wpn.rounds()[T.weapon_grenade]);
}

test "a molotov bursts into a fire that sets people alight" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 56);
    h.join(1, 33, 59);
    h.ped(0).heading = 16384; // toward slot 1
    _ = arm(&h, 0, T.weapon_molotov, 30);
    h.frames[0].buttons = Button.fire;
    h.run(20);
    h.frames[0].buttons = 0;
    // Find the fire once the bottle lands, and walk slot 1 into it.
    var fire: ?c.Transform = null;
    for (0..200) |_| {
        h.run(1);
        const Ctx = struct { out: *?c.Transform };
        h.sim.state.world.each(.{ c.Transform, c.Projectile }, Ctx{ .out = &fire }, struct {
            fn f(cx: Ctx, _: abi.EntityId, t: *c.Transform, p: *c.Projectile) void {
                if (p.weapon == c.Projectile.explosion_bit | T.explosion_fire) cx.out.* = t.*;
            }
        }.f);
        if (fire != null) break;
    }
    const f = fire orelse return error.NoFire;
    try std.testing.expect(f.y > h.ped(0).y + fx.fromInt(2));
    h.ped(1).* = .{ .x = f.x, .y = f.y, .z = f.z, .heading = 0 };
    h.run(2);
    const p1 = h.sim.pedOf(1).?;
    try std.testing.expect(h.sim.state.world.get(p1, c.Pedestrian).?.burn > 0);
    h.run(10);
    try std.testing.expect(h.sim.state.world.get(p1, c.Health).?.hp < T.ped_hp);
}

test "the flamethrower sets a target on fire and burning hurts" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.join(1, 33, 61);
    h.ped(0).heading = 16384;
    h.ped(1).* = .{ .x = h.ped(0).x, .y = h.ped(0).y + fx.ratio(8, 10), .z = h.ped(0).z, .heading = 0 };
    _ = arm(&h, 0, T.weapon_flamethrower, 200);
    h.frames[0].buttons = Button.fire;
    h.run(4);
    h.frames[0].buttons = 0;
    const p1 = h.sim.pedOf(1).?;
    try std.testing.expect(h.sim.state.world.get(p1, c.Pedestrian).?.burn > 0);
    const hp = h.sim.state.world.get(p1, c.Health).?.hp;
    h.run(10);
    try std.testing.expect(h.sim.state.world.get(p1, c.Health).?.hp < hp);
}

test "the electro gun shocks a target to death and chains" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.join(1, 33, 62);
    h.ped(0).heading = 16384;
    h.ped(1).* = .{ .x = h.ped(0).x, .y = h.ped(0).y + fx.ratio(15, 10), .z = h.ped(0).z, .heading = 0 };
    _ = arm(&h, 0, T.weapon_electro, 500);
    h.frames[0].buttons = Button.fire;
    var died = false;
    for (0..40) |_| {
        h.run(1);
        if (h.sim.state.players[1].deaths > 0) died = true;
    }
    try std.testing.expect(died);
    try std.testing.expectEqual(@as(i32, 1), h.sim.state.players[0].kills);
}

test "armour soaks whole hits; invulnerability ignores them; double damage doubles" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 33, 60);
    h.join(1, 33, 62);
    h.ped(0).heading = 16384;
    const p1 = h.sim.pedOf(1).?;
    const w = &h.sim.state.world;
    const ped1 = w.get(p1, c.Pedestrian).?;
    const hp1 = w.get(p1, c.Health).?;
    const shoot = struct {
        fn f(hh: *Harness) void {
            hh.ped(1).* = .{ .x = hh.ped(0).x, .y = hh.ped(0).y + fx.ratio(15, 10), .z = hh.ped(0).z, .heading = 0 };
            const wp = hh.sim.state.world.get(hh.sim.pedOf(0).?, c.Weapon).?;
            wp.cooldown = 0;
            hh.frames[0].buttons = Button.fire;
            hh.run(1);
            hh.frames[0].buttons = 0;
            hh.run(12);
        }
    }.f;
    _ = arm(&h, 0, T.weapon_smg, 100);
    ped1.armour = 2;
    shoot(&h);
    try std.testing.expectEqual(@as(u8, 1), ped1.armour);
    try std.testing.expectEqual(T.ped_hp, hp1.hp);
    ped1.armour = 0;
    ped1.invulnerable = 100;
    shoot(&h);
    try std.testing.expectEqual(T.ped_hp, hp1.hp);
    ped1.invulnerable = 0;
    shoot(&h);
    try std.testing.expectEqual(T.ped_hp - T.weapons[T.weapon_smg].damage_player, hp1.hp);
    w.get(h.sim.pedOf(0).?, c.Pedestrian).?.double_damage = 100;
    shoot(&h);
    try std.testing.expectEqual(T.ped_hp - 3 * T.weapons[T.weapon_smg].damage_player, hp1.hp);
    // Power-up pickups: refused when full.
    const t = h.ped(1).*;
    _ = h.sim.spawnPickupAt(t.x, t.y, T.pickup_armour).?;
    h.run(1);
    try std.testing.expectEqual(T.armour_charges, ped1.armour);
    _ = h.sim.spawnPickupAt(t.x, t.y, T.pickup_armour).?;
    h.run(1);
    try std.testing.expectEqual(@as(u32, 1), w.count(S.Pickup));
}
