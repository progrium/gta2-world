//! Tests: objects and city furniture (workstream B). One test per rule:
//! the light cycle and crossing markers, phones, doors, generators,
//! crushers, oil, mines, conveyors and destructors. All in a small `sp`
//! configuration on the synthetic test map.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const testmap = h_.testmap;
const Frame = h_.Frame;
const EntityId = abi.EntityId;
const blk = h_.blk;
const eql = h_.eql;
const OT = @import("../tuning/objects.zig");
const lights = @import("../sys/lights.zig");
const st = @import("../sys/objects_state.zig");

const cfg: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 8, .ped_capacity = 16, .projectile_capacity = 16, .pickup_capacity = 4, .map_object_capacity = 64 };
const S = simmod.Sim(cfg);
const O = S.objects;
const street: fx.Fx = fx.fromInt(1);

const H = struct {
    grid: *map.Grid,
    sim: *S,
    frames: [1]Frame = .{Frame.neutral(0)},

    fn init(lvl: ?*const simmod.Level) !H {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(S);
        s.init(g, .{ .seed = 11, .mode = .authoritative });
        if (lvl) |l| s.attachLevel(l);
        var h = H{ .grid = g, .sim = s };
        // The player on the pavement at (40, 37).
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(40, 37) }});
        h.put(blk(40), blk(37));
        return h;
    }
    fn deinit(h: *H) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    fn run(h: *H, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
    fn hash(h: *H) u64 {
        return h.sim.hash();
    }
    fn ped(h: *H) EntityId {
        return h.sim.pedOf(0).?;
    }
    /// Move the player's ped (on foot) to (x, y) on the street.
    fn put(h: *H, x: fx.Fx, y: fx.Fx) void {
        const t = h.sim.transformOf(h.ped()).?;
        t.x = x;
        t.y = y;
        t.z = street;
    }
    fn obj(h: *H, id: EntityId) *c.Object {
        return h.sim.state.world.get(id, c.Object).?;
    }
    fn count(h: *H, kind: simmod.ids.ObjectKind) u32 {
        var n: u32 = 0;
        const t = h.sim.state.world.table(S.MapObject);
        for (0..t.len) |i| {
            if (t.slot[i] == simmod.ecs.Slot.alive and t.col(c.Object)[i].kind == @intFromEnum(kind)) n += 1;
        }
        return n;
    }
    fn sawEvent(h: *H, kind: S.Event.Kind, a: u8) bool {
        for (h.sim.events()) |e| if (e.kind == kind and e.a == a) return true;
        return false;
    }
};

// --------------------------------------------------------------------------
// Traffic lights (traffic-and-car-ai.md 3.6)

test "lights: the 526-tick cycle runs the eight phases in order" {
    try std.testing.expectEqual(@as(u16, 526), OT.light_cycle);
    const L = lights.Light;
    try std.testing.expectEqual(L.green, lights.phaseLight(0, true));
    try std.testing.expectEqual(L.green, lights.phaseLight(99, true));
    try std.testing.expectEqual(L.amber, lights.phaseLight(100, true));
    try std.testing.expectEqual(L.red, lights.phaseLight(124, true));
    try std.testing.expectEqual(L.red, lights.phaseLight(147, false));
    try std.testing.expectEqual(L.green, lights.phaseLight(148, false));
    try std.testing.expectEqual(L.amber, lights.phaseLight(248, false));
    try std.testing.expectEqual(L.red, lights.phaseLight(272, false));
    for (0..526) |i| {
        const cyc: u16 = @intCast(i);
        // Never green both ways; all red from 296 to the end.
        try std.testing.expect(!(lights.phaseLight(cyc, true) == .green and lights.phaseLight(cyc, false) == .green));
        if (cyc >= 296) try std.testing.expect(lights.phaseLight(cyc, true) == .red and lights.phaseLight(cyc, false) == .red);
    }
}

test "lights: the cycle wraps, the shared bit toggles once a cycle, and a light zone shows the phase" {
    const zones = [_]simmod.level.Zone{.{ .kind = .traffic_light, .x = 48, .y = 48, .w = 4, .h = 4, .name = "j" }};
    const lvl: simmod.Level = .{ .zones = &zones };
    var h = try H.init(&lvl);
    defer h.deinit();
    const ls = &h.sim.state.sp.lights;
    const start = ls.cycle;
    const toggle0 = ls.flags & lights.State.flag_toggle;
    h.run(526);
    try std.testing.expectEqual(start, ls.cycle);
    try std.testing.expect(ls.flags & lights.State.flag_toggle != toggle0);
    // Inside the zone or just before it, heading in: the phase; elsewhere none.
    const want_ns = lights.phaseLight(ls.cycle, true);
    try std.testing.expectEqual(want_ns, S.lights.lightState(h.sim, 49, 47, 1));
    try std.testing.expectEqual(lights.phaseLight(ls.cycle, false), S.lights.lightState(h.sim, 47, 50, 0));
    try std.testing.expectEqual(lights.Light.none, S.lights.lightState(h.sim, 60, 60, 0));
}

test "lights: crossing markers go once on every approach lane facing the light, one lamp a side" {
    const zones = [_]simmod.level.Zone{.{ .kind = .traffic_light, .x = 48, .y = 48, .w = 4, .h = 4, .name = "j" }};
    const lvl: simmod.Level = .{ .zones = &zones };
    var h = try H.init(&lvl);
    defer h.deinit();
    h.run(2);
    // Two lanes a side point into the junction (right-hand traffic).
    try std.testing.expectEqual(@as(u32, 8), h.count(.crossing_marker));
    try std.testing.expectEqual(@as(u32, 4), h.count(.lamp));
    try std.testing.expect(S.lights.markerAt(h.sim, 47, 50, 0) != null); // west side, +x lanes
    try std.testing.expect(S.lights.markerAt(h.sim, 47, 48, 0) == null); // the -x lanes leave
    try std.testing.expect(S.lights.markerAt(h.sim, 48, 47, 0) != null); // +y lanes from the north
    h.run(600);
    try std.testing.expectEqual(@as(u32, 8), h.count(.crossing_marker)); // placed once
}

// --------------------------------------------------------------------------
// Phones (script-objects.md 2.6)

test "phones: a ringing phone is answered by walking onto it, once; the hook and events fire" {
    var h = try H.init(null);
    defer h.deinit();
    const phone = O.spawnObject(h.sim, .phone, 1, blk(44), blk(37), O.ground_z, 0).?;
    h.run(1);
    O.ringPhoneFor(h.sim, phone, .none, 0);
    try std.testing.expect(h.obj(phone).state & 1 != 0);
    h.run(30);
    try std.testing.expect(!O.phoneAnswered(h.sim, phone));
    h.put(blk(44), blk(37));
    h.run(1);
    try std.testing.expect(h.sawEvent(.phone_ring, 0));
    try std.testing.expect(O.phoneAnswered(h.sim, phone));
    try std.testing.expect(O.consumeAnswer(h.sim, phone));
    try std.testing.expect(!O.consumeAnswer(h.sim, phone));
    // Standing on it does not answer again.
    h.run(10);
    try std.testing.expect(!O.phoneAnswered(h.sim, phone));
}

test "phones: a ring for someone else is not answered by the player; a timeout runs out" {
    var h = try H.init(null);
    defer h.deinit();
    const phone = O.spawnObject(h.sim, .phone, 1, blk(40), blk(37), O.ground_z, 0).?;
    const other = O.spawnObject(h.sim, .phone, 1, blk(46), blk(37), O.ground_z, 0).?;
    h.run(1);
    // Ringing for a ped that is not the player.
    var fake = h.ped();
    fake.raw +%= 1;
    O.ringPhoneFor(h.sim, phone, fake, 0);
    h.run(5);
    try std.testing.expect(!O.phoneAnswered(h.sim, phone));
    // Timeout of 10 ticks on the other phone.
    O.ringPhoneFor(h.sim, other, .none, 10);
    h.run(9);
    try std.testing.expect(!O.phoneTimedOut(h.sim, other));
    h.run(1);
    try std.testing.expect(O.phoneTimedOut(h.sim, other));
    try std.testing.expect(h.obj(other).state & 1 == 0); // no longer ringing
    // Cancel (229).
    O.ringPhone(h.sim, phone, false);
    try std.testing.expect(h.obj(phone).state & 1 == 0);
}

test "phones: a dead phone can't ring or be answered and is listed" {
    var h = try H.init(null);
    defer h.deinit();
    const phone = O.spawnObject(h.sim, .phone, 1, blk(40), blk(37), O.ground_z, 0).?;
    h.run(1);
    O.ringPhoneFor(h.sim, phone, .none, 0);
    O.killPhone(h.sim, phone);
    try std.testing.expect(O.isPhoneDead(h.sim, phone));
    O.ringPhoneFor(h.sim, phone, .none, 0);
    h.run(5);
    try std.testing.expect(!O.phoneAnswered(h.sim, phone));
    try std.testing.expectEqual(@as(u32, 1), h.sim.state.sp.objects.dead_len);
    O.killPhone(h.sim, phone);
    try std.testing.expectEqual(@as(u32, 1), h.sim.state.sp.objects.dead_len);
}

// --------------------------------------------------------------------------
// Doors (script-declarations.md 2.9, script-objects.md 2.5)

fn testDoor(h: *H, open_rule: st.OpenRule, close_rule: st.CloseRule, delay: u16) EntityId {
    const anim = O.addDoorAnim(h.sim, 0, 3, 2).?;
    // The west face of block (50, 37), on the street.
    return O.addDoor(h.sim, .{ .bx = 50, .by = 37, .bz = 1, .face = .west, .anim = anim, .open_rule = open_rule, .close_rule = close_rule, .delay = delay }).?;
}

test "doors: any-player door opens for the player through its animation and shuts when he leaves" {
    var h = try H.init(null);
    defer h.deinit();
    const door = testDoor(&h, .any_player, .rule_false, 0);
    h.run(3);
    try std.testing.expectEqual(st.DoorState.closed, O.doorState(h.sim, door).?);
    try std.testing.expect(O.doorBlocks(h.sim, 50, 37, 1, .west));
    try std.testing.expect(O.doorBlocks(h.sim, 49, 37, 1, .east)); // the same face
    h.put(blk(49), blk(37));
    h.run(1);
    try std.testing.expectEqual(st.DoorState.opening, O.doorState(h.sim, door).?);
    // Three frames at two ticks each.
    h.run(5);
    try std.testing.expectEqual(st.DoorState.open, O.doorState(h.sim, door).?);
    try std.testing.expect(!O.doorBlocks(h.sim, 50, 37, 1, .west));
    h.put(blk(40), blk(37));
    h.run(1);
    try std.testing.expectEqual(st.DoorState.closing, O.doorState(h.sim, door).?);
    h.run(6);
    try std.testing.expectEqual(st.DoorState.closed, O.doorState(h.sim, door).?);
}

test "doors: close after a delay; a car-only door ignores a ped on foot" {
    var h = try H.init(null);
    defer h.deinit();
    const door = testDoor(&h, .any_car, .after_delay, 20);
    h.put(blk(49), blk(37));
    h.run(10);
    try std.testing.expectEqual(st.DoorState.closed, O.doorState(h.sim, door).?);
    h.put(blk(40), blk(37));
    const car = h.sim.spawnCarAt(blk(49), blk(37), 0, 0).?;
    h.run(7);
    try std.testing.expectEqual(st.DoorState.open, O.doorState(h.sim, door).?);
    h.sim.state.world.despawn(car);
    h.run(17);
    try std.testing.expectEqual(st.DoorState.open, O.doorState(h.sim, door).?);
    h.run(2);
    try std.testing.expectEqual(st.DoorState.closing, O.doorState(h.sim, door).?);
}

test "doors: manual mode stops the rules; script open, and close only when the rule wants it" {
    var h = try H.init(null);
    defer h.deinit();
    const door = testDoor(&h, .any_player, .rule_false, 0);
    O.setDoor(h.sim, door, .manual);
    h.put(blk(49), blk(37));
    h.run(10);
    try std.testing.expectEqual(st.DoorState.closed, O.doorState(h.sim, door).?);
    O.setDoor(h.sim, door, .open);
    try std.testing.expectEqual(st.DoorState.open, O.doorState(h.sim, door).?);
    // The player is still there: the close rule doesn't want it shut, so
    // 178 does nothing.
    h.run(1);
    O.setDoor(h.sim, door, .closed);
    try std.testing.expectEqual(st.DoorState.open, O.doorState(h.sim, door).?);
    h.put(blk(40), blk(37));
    h.run(1);
    try std.testing.expectEqual(st.DoorState.open, O.doorState(h.sim, door).?); // manual: stays
    O.setDoor(h.sim, door, .closed);
    try std.testing.expectEqual(st.DoorState.closing, O.doorState(h.sim, door).?);
    O.setDoor(h.sim, door, .auto);
    h.run(10);
    try std.testing.expectEqual(st.DoorState.closed, O.doorState(h.sim, door).?);
}

test "doors: a one-character door opens only for its target, and 265 retargets it" {
    var h = try H.init(null);
    defer h.deinit();
    const anim = O.addDoorAnim(h.sim, 0, 1, 1).?;
    var fake = h.ped();
    fake.raw +%= 1;
    const door = O.addDoor(h.sim, .{ .bx = 50, .by = 37, .bz = 1, .face = .west, .anim = anim, .open_rule = .one_char_on_foot, .close_rule = .rule_false, .target = fake }).?;
    h.put(blk(49), blk(37));
    h.run(5);
    try std.testing.expectEqual(st.DoorState.closed, O.doorState(h.sim, door).?);
    O.setDoorTarget(h.sim, door, h.ped());
    h.run(3);
    try std.testing.expectEqual(st.DoorState.open, O.doorState(h.sim, door).?);
}

test "doors: the shared animation list holds five" {
    var h = try H.init(null);
    defer h.deinit();
    for (0..5) |_| try std.testing.expect(O.addDoorAnim(h.sim, 0, 2, 1) != null);
    try std.testing.expect(O.addDoorAnim(h.sim, 0, 2, 1) == null);
}

// --------------------------------------------------------------------------
// Generators (script-declarations.md 2.8, script-objects.md 2.3)

test "generators: a pickup generator makes one at a time, never faster than its minimum after one is taken" {
    var h = try H.init(null);
    defer h.deinit();
    const gen = O.addGenerator(h.sim, .{ .x = blk(44), .y = blk(36), .z = O.ground_z, .model = 70, .min_delay = 40, .max_delay = 60 }).?;
    h.run(2);
    try std.testing.expectEqual(@as(u32, 1), h.count(.pickup));
    h.run(200);
    try std.testing.expectEqual(@as(u32, 1), h.count(.pickup)); // waits for it to go
    // Take it.
    h.put(blk(44), blk(36));
    h.run(1);
    try std.testing.expectEqual(@as(u32, 0), h.count(.pickup));
    h.put(blk(40), blk(37));
    var ticks: u32 = 0;
    while (h.count(.pickup) == 0 and ticks < 200) : (ticks += 1) h.run(1);
    try std.testing.expect(ticks >= 40 and ticks <= 61);
    _ = gen;
}

test "generators: other models spawn every cycle; a count stops it; off stops it; decide power-up" {
    var h = try H.init(null);
    defer h.deinit();
    const gen = O.addGenerator(h.sim, .{ .x = blk(44), .y = blk(36), .z = O.ground_z, .model = 5, .min_delay = 10, .max_delay = 10 }).?;
    h.run(1 + 11 * 3);
    try std.testing.expectEqual(@as(u32, 4), h.count(.decoration));
    O.setGenerator(h.sim, gen, false);
    h.run(50);
    try std.testing.expectEqual(@as(u32, 4), h.count(.decoration));
    O.startGenerator(h.sim, gen, 2, null);
    h.run(100);
    try std.testing.expectEqual(@as(u32, 6), h.count(.decoration));
    // Decide power-up: an unlisted car model gives type 65, 3 spawns.
    O.setCarList(h.sim, &.{ 3, 4 });
    O.decidePowerUp(h.sim, gen, 9);
    try std.testing.expectEqual(@as(?u16, 65), O.objectModel(h.sim, gen));
    const g = &h.sim.state.sp.objects.gens[h.obj(gen).value];
    try std.testing.expectEqual(@as(u16, 3), g.remaining);
    try std.testing.expectEqual(@as(u8, 1), g.one_at_a_time);
}

// --------------------------------------------------------------------------
// Crushers (crushers-and-garages.md 3.2)

test "crusher: squeezes the sides, the car explodes, then the ends, leaving a crushed wreck" {
    var h = try H.init(null);
    defer h.deinit();
    const crusher = O.addCrusher(h.sim, blk(44), blk(36), O.ground_z).?;
    h.run(1);
    const car = h.sim.spawnCarAt(blk(44), blk(36), 0, 0).?;
    h.run(1);
    try std.testing.expect(O.beingCrushed(h.sim, car));
    try std.testing.expect(h.sim.state.world.get(car, c.Collider).?.flags & c.Collider.flag_disabled != 0);
    // 24 ticks of side squeeze (60 px to 36 px) after the tick it starts.
    h.run(23);
    try std.testing.expect(h.sim.state.world.get(car, c.Vehicle).?.flags & c.Vehicle.flag_wrecked == 0);
    h.run(1);
    try std.testing.expect(h.sim.state.world.get(car, c.Vehicle).?.flags & c.Vehicle.flag_wrecked != 0);
    try std.testing.expect(h.sawEvent(.explosion, 1));
    const p = O.crusherPistons(h.sim, crusher).?;
    try std.testing.expect(p.shrink_w > 0 and p.shrink_l == 0);
    try std.testing.expectEqual(OT.piston_closed, p.sides);
    // Open the sides (24), squeeze the ends (24): crushed.
    h.run(48);
    try std.testing.expect(h.sim.state.world.get(car, c.Vehicle).?.flags & c.Vehicle.flag_crushed != 0);
    try std.testing.expect(O.crusherPistons(h.sim, crusher).?.shrink_l > 0);
    // Open the ends: idle, the wreck is left and collides again.
    h.run(24);
    try std.testing.expectEqual(@as(u8, 0), h.obj(crusher).state);
    try std.testing.expect(!O.beingCrushed(h.sim, car));
    try std.testing.expect(h.sim.state.world.isAlive(car));
    try std.testing.expect(h.sim.state.world.get(car, c.Collider).?.flags & c.Collider.flag_disabled == 0);
    // A crushed car is not crushed again.
    h.run(5);
    try std.testing.expectEqual(@as(u8, 0), h.obj(crusher).state);
}

// --------------------------------------------------------------------------
// Oil and mines (weapons.md 3.7, projectiles.md)

test "oil: a patch is there for its life, then goes" {
    var h = try H.init(null);
    defer h.deinit();
    _ = O.dropOil(h.sim, blk(60), blk(34), street, .none).?;
    h.run(1);
    try std.testing.expect(O.oilAt(h.sim, blk(60), blk(34), street));
    try std.testing.expect(!O.oilAt(h.sim, blk(62), blk(34), street));
    h.run(OT.oil_life + 1);
    try std.testing.expect(!O.oilAt(h.sim, blk(60), blk(34), street));
}

test "mines: arm, then blow up the first car over them, credited to the layer; one a tick" {
    var h = try H.init(null);
    defer h.deinit();
    const by = h.ped();
    _ = O.dropMine(h.sim, blk(60), blk(34), street, by).?;
    _ = O.dropMine(h.sim, blk(60) + fx.ratio(1, 8), blk(34), street, by).?;
    const car = h.sim.spawnCarAt(blk(60), blk(34), 0, 0).?;
    h.run(OT.mine_arm_ticks);
    try std.testing.expectEqual(@as(u32, 2), h.count(.mine));
    h.run(1);
    try std.testing.expectEqual(@as(u32, 1), h.count(.mine));
    try std.testing.expect(h.sawEvent(.explosion, 0));
    const v = h.sim.state.world.get(car, c.Vehicle).?;
    try std.testing.expect(v.flags & c.Vehicle.flag_wrecked != 0 or h.sim.state.world.get(car, c.Health).?.hp <= 0);
    try std.testing.expect(eql(h.sim.state.world.get(car, c.Health).?.last_hit_by, by));
}

test "mines: a ped walking onto one sets it off" {
    var h = try H.init(null);
    defer h.deinit();
    _ = O.dropMine(h.sim, blk(44), blk(37), street, .none).?;
    h.run(OT.mine_arm_ticks + 2);
    try std.testing.expectEqual(@as(u32, 1), h.count(.mine));
    h.put(blk(44), blk(37));
    h.run(1);
    try std.testing.expectEqual(@as(u32, 0), h.count(.mine));
}

// --------------------------------------------------------------------------
// Conveyors and destructors (script-declarations.md 2.8)

test "conveyors push inside their area; destructors remove empty cars, not the player's" {
    var h = try H.init(null);
    defer h.deinit();
    _ = O.addArea(h.sim, .conveyor, fx.fromInt(60), fx.fromInt(34), O.ground_z, fx.fromInt(4), fx.fromInt(2), fx.ratio(1, 20), 0).?;
    const push = O.conveyorPush(h.sim, blk(61), blk(34), street).?;
    try std.testing.expectEqual(fx.ratio(1, 20), push.vx);
    try std.testing.expect(O.conveyorPush(h.sim, blk(65), blk(34), street) == null);
    const dest = O.addArea(h.sim, .destructor, fx.fromInt(70), fx.fromInt(34), O.ground_z, fx.fromInt(2), fx.fromInt(2), 0, 0).?;
    const car = h.sim.spawnCarAt(blk(70), blk(34), 0, 0).?;
    h.run(2);
    try std.testing.expect(!h.sim.state.world.isAlive(car));
    O.removeObject(h.sim, dest);
    h.run(1);
    const car2 = h.sim.spawnCarAt(blk(70), blk(34), 0, 0).?;
    h.run(2);
    try std.testing.expect(h.sim.state.world.isAlive(car2));
}

// --------------------------------------------------------------------------
// Determinism, removal, and the deathmatch configuration

test "objects: two sims with the same furniture stay in step; save and load round-trips" {
    const zones = [_]simmod.level.Zone{.{ .kind = .traffic_light, .x = 48, .y = 48, .w = 4, .h = 4, .name = "j" }};
    const mobj = [_]simmod.level.MapObject{.{ .x = blk(42), .y = blk(42), .heading = 0, .object_type = 12 }};
    const lvl: simmod.Level = .{ .zones = &zones, .objects = &mobj };
    var a = try H.init(&lvl);
    defer a.deinit();
    var b = try H.init(&lvl);
    defer b.deinit();
    for ([_]*H{ &a, &b }) |h| {
        _ = O.addGenerator(h.sim, .{ .x = blk(44), .y = blk(36), .z = O.ground_z, .model = 5, .min_delay = 5, .max_delay = 30 }).?;
        _ = testDoor(h, .any_player, .rule_false, 0);
        _ = O.addCrusher(h.sim, blk(42), blk(36), O.ground_z).?;
    }
    for (0..300) |i| {
        if (i == 100) {
            a.put(blk(49), blk(37));
            b.put(blk(49), blk(37));
        }
        a.run(1);
        b.run(1);
        try std.testing.expectEqual(a.hash(), b.hash());
    }
    try std.testing.expectEqual(@as(u32, 1), a.count(.decoration) - countGenerated(&a));
    const buf = try std.testing.allocator.alloc(u8, S.state_size);
    defer std.testing.allocator.free(buf);
    _ = a.sim.save(buf);
    a.run(50);
    const ahead = a.sim.hash();
    try a.sim.load(buf);
    a.run(50);
    try std.testing.expectEqual(ahead, a.sim.hash());
}

fn countGenerated(h: *H) u32 {
    var n: u32 = 0;
    const t = h.sim.state.world.table(S.MapObject);
    for (0..t.len) |i| {
        if (t.slot[i] != simmod.ecs.Slot.alive) continue;
        const o = t.col(c.Object)[i];
        if (o.kind == @intFromEnum(simmod.ids.ObjectKind.decoration) and o.owner.kind() == @intFromEnum(abi.Kind.map_object)) n += 1;
    }
    return n;
}

test "objects: removing a door frees its slot; the API does nothing in dm16" {
    var h = try H.init(null);
    defer h.deinit();
    const door = testDoor(&h, .any_player, .rule_false, 0);
    O.removeObject(h.sim, door);
    h.run(1);
    try std.testing.expect(O.doorState(h.sim, door) == null);
    try std.testing.expect(!O.doorBlocks(h.sim, 50, 37, 1, .west));

    var d = try h_.Harness.init(.authoritative);
    defer d.deinit();
    const D = h_.S.objects;
    const before = d.sim.hash();
    try std.testing.expect(D.spawnObject(d.sim, .phone, 1, 0, 0, 0, 0) == null);
    try std.testing.expect(D.addGenerator(d.sim, .{ .x = 0, .y = 0, .z = 0, .model = 70, .min_delay = 1, .max_delay = 2 }) == null);
    try std.testing.expect(D.addCrusher(d.sim, 0, 0, 0) == null);
    try std.testing.expect(D.addDoorAnim(d.sim, 0, 1, 1) == null);
    try std.testing.expect(!D.oilAt(d.sim, 0, 0, 0));
    try std.testing.expect(D.conveyorPush(d.sim, 0, 0, 0) == null);
    try std.testing.expect(!D.beingCrushed(d.sim, .none));
    try std.testing.expectEqual(lights.Light.none, h_.S.lights.lightState(d.sim, 33, 33, 0));
    d.run(10);
    var e = try h_.Harness.init(.authoritative);
    defer e.deinit();
    e.run(10);
    try std.testing.expectEqual(e.sim.hash(), d.sim.hash());
    _ = before;
}

test "pickups: a script weapon pickup arms the player who walks over it" {
    var h = try H.init(null);
    defer h.deinit();
    const id = O.spawnObject(h.sim, .pickup, OT.weapon_model_lo + 1, blk(44), blk(37), O.ground_z, 0).?;
    h.run(1);
    try std.testing.expect(h.sim.state.world.isAlive(id));
    h.put(blk(44), blk(37));
    h.run(1);
    try std.testing.expect(!h.sim.state.world.isAlive(id));
    try std.testing.expect(h.sim.state.world.get(h.ped(), c.Weapon).?.rounds()[1] > 0);
    try std.testing.expect(h.sawEvent(.pickup, 0));
}

test "barriers: a ped can't walk through one and a car is stopped by it" {
    var h = try H.init(null);
    defer h.deinit();
    // Across the pavement strip at x = 44, running along y.
    _ = O.spawnObject(h.sim, .barrier, 0, fx.fromInt(44), blk(37), O.ground_z, 16384).?;
    h.run(1);
    h.put(blk(42), blk(37));
    const t = h.sim.transformOf(h.ped()).?;
    t.heading = 0;
    h.frames[0].throttle = 127;
    h.run(60);
    h.frames[0].throttle = 0;
    try std.testing.expect(h.sim.transformOf(h.ped()).?.x < fx.fromInt(44));
    // A car driven east along the road into a barrier across it.
    _ = O.spawnObject(h.sim, .barrier, 0, fx.fromInt(64), blk(34), O.ground_z, 16384).?;
    const car = h.sim.spawnCarAt(blk(60), blk(34), 0, 0).?;
    h.sim.state.world.get(car, c.Velocity).?.vx = fx.ratio(2, 10);
    h.run(40);
    try std.testing.expect(h.sim.transformOf(car).?.x < fx.fromInt(64));
}

test "objects: models and door animation frames above 255" {
    var h = try H.init(null);
    defer h.deinit();
    const id = O.spawnObject(h.sim, .decoration, 286, blk(44), blk(37), O.ground_z, 0).?;
    try std.testing.expectEqual(@as(?u16, 286), O.objectModel(h.sim, id));
    const anim = O.addDoorAnim(h.sim, 928, 935, 1).?;
    const door = O.addDoor(h.sim, .{ .bx = 50, .by = 37, .bz = 1, .face = .west, .anim = anim, .open_rule = .unknown, .close_rule = .rule_false }).?;
    const d = &h.sim.state.sp.objects.doors[h.obj(door).value];
    try std.testing.expectEqual(@as(u16, 928), d.frame);
    h.put(blk(49), blk(37));
    h.run(10);
    try std.testing.expectEqual(st.DoorState.open, O.doorState(h.sim, door).?);
    try std.testing.expectEqual(@as(u16, 935), d.frame);
}
