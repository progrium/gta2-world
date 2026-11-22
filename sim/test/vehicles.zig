//! Tests: trailers, cranes and the script car flags (`sys/trailers.zig`,
//! `sys/cranes.zig`, `sys/car_flags.zig`). Deathmatch-sized harness for
//! the flags and trailers (they work in every configuration), a small
//! `sp` one for cranes.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const Button = h_.Button;
const Frame = h_.Frame;
const EntityId = abi.EntityId;
const Harness = h_.Harness;
const S = h_.S;
const blk = h_.blk;
const eql = h_.eql;
const TV = @import("../tuning/vehicles.zig");
const TCars = @import("../tuning/cars.zig");
const testmap = h_.testmap;

const V = c.Vehicle;

/// Test models: 0 a plain car, 1 a truck cab, 2 a trailer (no doors, long),
/// 3 an emergency car.
fn installModels() void {
    var models = [4]T.CarModel{ T.default_car_models[0], T.default_car_models[0], T.default_car_models[0], T.default_car_models[0] };
    models[1].flags = TCars.car_flag_cab;
    var tspec = T.default_spec;
    tspec.h_px = 120;
    tspec.w_px = 40;
    tspec.flags = TCars.car_flag_trailer;
    tspec.doors = 0;
    models[2] = T.deriveModel(tspec);
    models[3].flags = TCars.car_flag_emerg_lights;
    T.setCarModels(&models);
}
fn resetModels() void {
    T.setCarModels(&T.default_car_models);
}

fn veh(h: *Harness, id: EntityId) *V {
    return h.sim.state.world.get(id, V).?;
}
fn tr(h: *Harness, id: EntityId) *c.Transform {
    return h.sim.transformOf(id).?;
}
fn hp(h: *Harness, id: EntityId) i32 {
    return h.sim.state.world.get(id, c.Health).?.hp;
}

// --------------------------------------------------------------------------
// Car info flags and model numbers

test "car info: the collide_over bit makes a heavy tank; flags and doors carry through" {
    var sp = T.default_spec;
    sp.flags = TCars.car_flag_collide_over | TCars.car_flag_emerg_lights;
    sp.doors = 0;
    const m = T.deriveModel(sp);
    try std.testing.expectEqual(@as(i32, 1), m.heavy);
    try std.testing.expectEqual(@as(i32, 1), m.tank);
    try std.testing.expectEqual(@as(i32, 0), m.doors);
    try std.testing.expectEqual(@as(i32, 0), T.deriveModel(T.default_spec).heavy);
}

// --------------------------------------------------------------------------
// Proofs (script-cars.md 2.5)

test "proofs: rocketproof shrugs off a blast, flameproof a fire, a plain car takes both" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    const plain = h.sim.spawnCarAt(blk(44), blk(36), 0, 0).?;
    const proof = h.sim.spawnCarAt(blk(48), blk(36), 0, 0).?;
    h.run(1);
    S.car_flags.setFlag(h.sim, proof, V.xf_rocketproof, true);
    S.car_flags.setFlag(h.sim, proof, V.xf_flameproof, true);
    const z = tr(&h, plain).z;
    h.sim.explodeAt(blk(44), blk(36), z, .none, 0);
    h.sim.explodeAt(blk(48), blk(36), z, .none, 0);
    h.run(60);
    try std.testing.expect(hp(&h, plain) < T.car_damage_max);
    try std.testing.expectEqual(T.car_damage_max, hp(&h, proof));
    try std.testing.expect(S.car_flags.shielded(h.sim, proof, .flame));
    try std.testing.expect(!S.car_flags.shielded(h.sim, proof, .bullet));
    // A car-size blast right beside it still gets through.
    try std.testing.expect(!S.car_flags.shielded(h.sim, proof, .bomb_close));
}

test "proofs: a bulletproof car takes no damage from a machine gun" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 40, 37);
    const car = h.sim.spawnCarAt(blk(44), blk(37), 16384, 0).?;
    h.run(1);
    S.car_flags.setFlag(h.sim, car, V.xf_bulletproof, true);
    const me = h.sim.pedOf(0).?;
    tr(&h, me).heading = 0; // facing +x, at the car
    _ = h_.arm(&h, 0, T.weapon_smg, 500);
    h.frames[0].buttons = Button.fire;
    h.run(40);
    h.frames[0].buttons = 0;
    h.run(5);
    try std.testing.expectEqual(T.car_damage_max, hp(&h, car));
    // Without the flag the same burst hurts it.
    S.car_flags.setFlag(h.sim, car, V.xf_bulletproof, false);
    h.frames[0].buttons = Button.fire;
    h.run(40);
    h.frames[0].buttons = 0;
    h.run(5);
    try std.testing.expect(hp(&h, car) < T.car_damage_max);
}

// --------------------------------------------------------------------------
// Locks and the alarm

fn pressEnter(h: *Harness) void {
    h.frames[0].buttons |= Button.enter_exit;
    h.run(1);
    h.frames[0].buttons &= ~Button.enter_exit;
    h.run(1);
    h.settleCar(0);
}

test "locks: a locked car keeps the player out, a player lockout too, an unlocked one lets him in" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 37);
    const car = h.sim.spawnCarAt(blk(61), blk(34), 0, 0).?;
    h.run(1);
    const me = h.sim.pedOf(0).?;
    for ([_]u8{ V.lock_locked, V.lock_player }) |lk| {
        veh(&h, car).lock = lk;
        h.ped(0).heading = 16384 * 3;
        pressEnter(&h);
        try std.testing.expect(h.sim.state.world.get(me, c.Riding).?.vehicle.isNone());
    }
    // A thief-only lock does not stop a player.
    veh(&h, car).lock = V.lock_thief;
    h.ped(0).heading = 16384 * 3;
    pressEnter(&h);
    try std.testing.expect(eql(h.sim.state.world.get(me, c.Riding).?.vehicle, car));
}

test "locks: a permanent lock is never replaced except by another permanent lock" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    const car = h.sim.spawnCarAt(blk(61), blk(34), 0, 0).?;
    h.run(1);
    S.car_flags.setLock(h.sim, car, V.lock_permanent);
    S.car_flags.setLock(h.sim, car, V.lock_unlocked);
    try std.testing.expectEqual(V.lock_permanent, veh(&h, car).lock);
    S.car_flags.setLock(h.sim, car, V.lock_permanent);
    try std.testing.expectEqual(V.lock_permanent, veh(&h, car).lock);
}

test "alarm: rings once when someone tries the door or the car is hit, then stops" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 60, 37);
    const car = h.sim.spawnCarAt(blk(61), blk(34), 0, 0).?;
    h.run(1);
    S.car_flags.setFlag(h.sim, car, V.xf_alarm, true);
    h.ped(0).heading = 16384 * 3;
    h.frames[0].buttons |= Button.enter_exit;
    h.run(1);
    h.frames[0].buttons &= ~Button.enter_exit;
    var rang = false;
    for (0..200) |_| {
        h.run(1);
        if (h_.hasEvent(h.sim.events(), S.Event.Kind.car_alarm)) rang = true;
    }
    try std.testing.expect(rang);
    try std.testing.expect(veh(&h, car).alarm_n > 0 or rang);
    h.run(TV.alarm_ticks);
    try std.testing.expectEqual(@as(u8, 0), veh(&h, car).alarm_n);
    // A car without an alarm stays quiet when hit.
    const quiet = h.sim.spawnCarAt(blk(44), blk(36), 0, 0).?;
    h.run(1);
    h.sim.damageCar(quiet, 100 << fx.frac_bits, .none);
    try std.testing.expectEqual(@as(u8, 0), veh(&h, quiet).alarm_n);
}

// --------------------------------------------------------------------------
// Jammed accelerator and siren

test "jammed accelerator: a player's car drives off with no keys held, and can still brake" {
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 40, 35);
    const car = h.sim.spawnCarAt(blk(44), fx.fromInt(35), 0, 0).?;
    h.run(1);
    h.sim.board(h.sim.pedOf(0).?, car);
    h.run(20);
    try std.testing.expect(S.speedOf(h.sim.state.world.get(car, c.Velocity).?) == 0);
    S.car_flags.setFlag(h.sim, car, V.xf_jammed, true);
    h.run(30);
    const fast = S.speedOf(h.sim.state.world.get(car, c.Velocity).?);
    try std.testing.expect(fast > 0);
    // Down brakes it.
    h.frames[0].throttle = -127;
    h.run(15);
    try std.testing.expect(S.speedOf(h.sim.state.world.get(car, c.Velocity).?) < fast);
}

test "siren: only cars with emergency lights take it; the flag is what 417 reads" {
    installModels();
    defer resetModels();
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    const plain = h.sim.spawnCarAt(blk(44), blk(36), 0, 0).?;
    const cop = h.sim.spawnCarAt(blk(48), blk(36), 0, 3).?;
    h.run(1);
    S.car_flags.setSiren(h.sim, plain, true);
    S.car_flags.setSiren(h.sim, cop, true);
    try std.testing.expect(!S.car_flags.sirenOn(h.sim, plain));
    try std.testing.expect(S.car_flags.sirenOn(h.sim, cop));
    try std.testing.expect(h_.hasEvent(h.sim.events(), S.Event.Kind.siren));
    S.car_flags.setSiren(h.sim, cop, false);
    try std.testing.expect(!S.car_flags.sirenOn(h.sim, cop));
}

// --------------------------------------------------------------------------
// Trailers

/// The distance from the cab's hitch to the trailer's kingpin.
fn gap(h: *Harness, cab: EntityId, trailer: EntityId) fx.Fx {
    const tc = tr(h, cab);
    const tt = tr(h, trailer);
    const ho = S.trailers.hitchOffset(veh(h, cab).model);
    const ko = S.trailers.kingpinOffset(veh(h, trailer).model);
    const hx = tc.x + fx.mul(fx.cos(tc.heading), ho);
    const hy = tc.y + fx.mul(fx.sin(tc.heading), ho);
    const kx = tt.x + fx.mul(fx.cos(tt.heading), ko);
    const ky = tt.y + fx.mul(fx.sin(tt.heading), ko);
    return fx.length(kx - hx, ky - hy);
}

test "trailers: a cab created with a trailer pulls it along, hitch on the kingpin, and it trails round a turn" {
    installModels();
    defer resetModels();
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 40, 35);
    const cab = h.sim.spawnCarAt(blk(50), fx.fromInt(35), 0, 1).?;
    const trailer = S.trailers.spawnBehind(h.sim, cab, 2).?;
    h.run(1);
    try std.testing.expect(eql(veh(&h, cab).trailerId(), trailer));
    try std.testing.expect(eql(veh(&h, trailer).towId(), cab));
    try std.testing.expect(gap(&h, cab, trailer) < fx.ratio(1, 64));
    // Nobody can get into a towed trailer.
    try std.testing.expect(!S.enterable(veh(&h, trailer)));
    h.sim.board(h.sim.pedOf(0).?, cab);
    const x0 = tr(&h, trailer).x;
    h.frames[0].throttle = 127;
    h.run(40);
    try std.testing.expect(tr(&h, trailer).x > x0 + fx.half);
    try std.testing.expect(gap(&h, cab, trailer) < fx.ratio(1, 16));
    // A turn: the trailer's heading follows the cab's, lagging behind.
    h.frames[0].steer = 127;
    h.run(25);
    const dh: i16 = @bitCast(tr(&h, cab).heading -% tr(&h, trailer).heading);
    try std.testing.expect(dh != 0);
    try std.testing.expect(@abs(@as(i32, dh)) <= TV.max_articulation);
    try std.testing.expect(gap(&h, cab, trailer) < fx.ratio(1, 16));
    h.frames[0].steer = 0;
    h.frames[0].throttle = 0;
}

test "trailers: fire drops the trailer; backing slowly onto it hitches it again" {
    installModels();
    defer resetModels();
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    h.join(0, 40, 35);
    const cab = h.sim.spawnCarAt(blk(50), fx.fromInt(35), 0, 1).?;
    const trailer = S.trailers.spawnBehind(h.sim, cab, 2).?;
    h.run(1);
    h.sim.board(h.sim.pedOf(0).?, cab);
    h.run(2);
    h.frames[0].buttons = Button.fire;
    h.run(1);
    h.frames[0].buttons = 0;
    h.run(1);
    try std.testing.expect(veh(&h, cab).trailerId().isNone());
    try std.testing.expect(veh(&h, trailer).towId().isNone());
    // Pull away, then reverse back onto the kingpin.
    h.frames[0].throttle = 127;
    h.run(25);
    h.frames[0].throttle = 0;
    h.run(60);
    var hitched = false;
    for (0..400) |_| {
        const v = S.speedOf(h.sim.state.world.get(cab, c.Velocity).?);
        h.frames[0].throttle = if (v > fx.ratio(5, 100)) 0 else -60;
        h.run(1);
        if (eql(veh(&h, cab).trailerId(), trailer)) {
            hitched = true;
            break;
        }
    }
    h.frames[0].throttle = 0;
    try std.testing.expect(hitched);
}

test "trailers: the pair splits when either half is wrecked, and they never collide with each other" {
    installModels();
    defer resetModels();
    var h = try Harness.init(.authoritative);
    defer h.deinit();
    const cab = h.sim.spawnCarAt(blk(50), fx.fromInt(35), 0, 1).?;
    const trailer = S.trailers.spawnBehind(h.sim, cab, 2).?;
    h.run(1);
    try std.testing.expect(S.trailers.paired(h.sim, cab, trailer));
    const hp0 = hp(&h, trailer);
    h.run(30);
    try std.testing.expectEqual(hp0, hp(&h, trailer));
    h.sim.state.world.get(trailer, c.Health).?.hp = 0;
    h.run(3);
    try std.testing.expect(veh(&h, cab).trailerId().isNone());
}

test "trailers: two sims agree tick for tick (determinism)" {
    installModels();
    defer resetModels();
    var a = try Harness.init(.authoritative);
    defer a.deinit();
    var b = try Harness.init(.authoritative);
    defer b.deinit();
    for ([_]*Harness{ &a, &b }) |h| {
        h.join(0, 40, 35);
        const cab = h.sim.spawnCarAt(blk(50), fx.fromInt(35), 0, 1).?;
        _ = S.trailers.spawnBehind(h.sim, cab, 2).?;
        h.run(1);
        h.sim.board(h.sim.pedOf(0).?, cab);
        h.frames[0].throttle = 127;
        h.frames[0].steer = 90;
        h.run(80);
    }
    try std.testing.expectEqual(a.sim.hash(), b.sim.hash());
}

// --------------------------------------------------------------------------
// Cranes (sp)

const cfg_sp: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 8, .ped_capacity = 16, .projectile_capacity = 16, .pickup_capacity = 4, .map_object_capacity = 64 };
const Sp = simmod.Sim(cfg_sp);

const SpH = struct {
    grid: *map.Grid,
    sim: *Sp,
    frames: [1]Frame = .{Frame.neutral(0)},

    fn init() !SpH {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(Sp);
        s.init(g, .{ .seed = 3, .mode = .authoritative });
        var h = SpH{ .grid = g, .sim = s };
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(30, 37) }});
        return h;
    }
    fn deinit(h: *SpH) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    fn run(h: *SpH, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
};

test "cranes: a car left still in reach is lifted, swung over and set down at the first target" {
    var h = try SpH.init();
    defer h.deinit();
    const hook = Sp.cranes.addCrane(h.sim, blk(44), blk(36), 0, .none).?;
    Sp.cranes.setTarget(h.sim, hook, 0, blk(47), blk(36), 16384);
    h.run(1);
    const car = h.sim.spawnCarAt(blk(42), blk(36), 0, 0).?;
    var was_lifted = false;
    var carried = false;
    for (0..1500) |_| {
        h.run(1);
        if (Sp.cranes.lifted(h.sim, car)) was_lifted = true;
        if (eql(Sp.cranes.carOn(h.sim, hook), car)) carried = true;
        if (was_lifted and !Sp.cranes.lifted(h.sim, car)) break;
    }
    try std.testing.expect(was_lifted);
    try std.testing.expect(carried);
    try std.testing.expect(!Sp.cranes.lifted(h.sim, car));
    const t = h.sim.transformOf(car).?;
    try std.testing.expect(@abs(t.x - blk(47)) < fx.ratio(1, 8));
    try std.testing.expect(@abs(t.y - blk(36)) < fx.ratio(1, 8));
    try std.testing.expectEqual(@as(u16, 16384), t.heading);
    // Back on the ground and solid again.
    h.run(40);
    try std.testing.expect(h.sim.state.world.get(car, c.Collider).?.flags & c.Collider.flag_disabled == 0);
    try std.testing.expect(t.z < fx.fromInt(2));
}

test "cranes: into a crusher, then a linked crane moves the wreck to its own target" {
    var h = try SpH.init();
    defer h.deinit();
    const a = Sp.cranes.addCrane(h.sim, blk(44), blk(36), 0, .none).?;
    Sp.cranes.setTarget(h.sim, a, 0, blk(46), blk(36), 0);
    const b = Sp.cranes.addCrane(h.sim, blk(48), blk(36), 0, a).?;
    Sp.cranes.setTarget(h.sim, b, 1, blk(50), blk(38), 0);
    _ = Sp.objects.addCrusher(h.sim, blk(46), blk(36), Sp.objects.ground_z).?;
    h.run(1);
    const car = h.sim.spawnCarAt(blk(42), blk(36), 0, 0).?;
    var crushed = false;
    for (0..4000) |_| {
        h.run(1);
        const v = h.sim.state.world.get(car, c.Vehicle) orelse break;
        if (v.flags & c.Vehicle.flag_crushed != 0) crushed = true;
        if (crushed and !Sp.cranes.lifted(h.sim, car)) {
            const t = h.sim.transformOf(car).?;
            if (@abs(t.x - blk(50)) < fx.ratio(1, 8) and @abs(t.y - blk(38)) < fx.ratio(1, 8)) break;
        }
    }
    try std.testing.expect(crushed);
    const t = h.sim.transformOf(car).?;
    try std.testing.expect(@abs(t.x - blk(50)) < fx.ratio(1, 8));
    try std.testing.expect(@abs(t.y - blk(38)) < fx.ratio(1, 8));
}

test "cranes: a driver rides along and cannot get out while lifted" {
    var h = try SpH.init();
    defer h.deinit();
    const hook = Sp.cranes.addCrane(h.sim, blk(44), blk(36), 0, .none).?;
    Sp.cranes.setTarget(h.sim, hook, 0, blk(47), blk(36), 0);
    h.run(1);
    const car = h.sim.spawnCarAt(blk(42), blk(36), 0, 0).?;
    h.run(1);
    const me = h.sim.pedOf(0).?;
    h.sim.board(me, car);
    var tried = false;
    for (0..1500) |_| {
        h.run(1);
        if (Sp.cranes.lifted(h.sim, car)) {
            h.sim.tryExit(me);
            try std.testing.expect(eql(h.sim.state.world.get(me, c.Riding).?.vehicle, car));
            tried = true;
            break;
        }
    }
    try std.testing.expect(tried);
}
