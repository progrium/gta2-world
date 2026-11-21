//! Tests: A2's script world commands (sim/script/world.zig and the five
//! family files), driven through a stand-in for the VM's context with
//! hand-built parameter bytes in the layouts read from the player's
//! .scr files. No game data.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const testmap = h_.testmap;
const Frame = h_.Frame;
const EntityId = abi.EntityId;
const eql = h_.eql;
const W = @import("../script/world.zig");
const Cmd = W.Cmd;

const cfg: abi.Config = .{ .name = "sp-test", .max_players = 1, .car_capacity = 16, .ped_capacity = 32, .projectile_capacity = 16, .pickup_capacity = 4, .map_object_capacity = 16 };
const S = simmod.Sim(cfg);

/// The VM's side of the seam, as A2 uses it.
const Ctx = struct {
    sim: *S,
    handles: [6000]EntityId = @splat(.none),
    cond: bool = false,
    counters: [16]i32 = @splat(0),
    cleanup: [32]EntityId = @splat(.none),
    n_cleanup: usize = 0,
    decl: bool = false,
    death: bool = false,
    notify: bool = false,
    mission_flags: [4]u16 = @splat(0),
    fail_base: [3]u16 = @splat(0),
    gangs: [8]u16 = @splat(0),
    triggers: usize = 0,
    last_trigger: W.decl.Trigger = undefined,

    pub fn declaring(x: *Ctx) bool {
        return x.decl;
    }
    pub fn handle(x: *Ctx, num: u16) EntityId {
        return x.handles[num];
    }
    pub fn setHandle(x: *Ctx, num: u16, id: EntityId) void {
        x.handles[num] = id;
    }
    pub fn setCond(x: *Ctx, b: bool) void {
        x.cond = b;
    }
    pub fn counter(x: *Ctx, num: u16) ?*i32 {
        return if (num < x.counters.len) &x.counters[num] else null;
    }
    pub fn addCleanup(x: *Ctx, id: EntityId) void {
        x.cleanup[x.n_cleanup] = id;
        x.n_cleanup += 1;
    }
    pub fn string(x: *Ctx, off: u16) []const u8 {
        _ = x;
        return if (off == 10) "downtown" else "";
    }
    pub fn deathArrestFlag(x: *Ctx) *bool {
        return &x.death;
    }
    pub fn notifyDeathArrest(x: *Ctx) *bool {
        return &x.notify;
    }
    pub fn setMissionFlag(x: *Ctx, which: u2, num: u16) void {
        x.mission_flags[which] = num;
    }
    pub fn setFailBase(x: *Ctx, gang: u2, base: u16) void {
        x.fail_base[gang] = base;
    }
    pub fn registerGang(x: *Ctx, index: u8, key: u16) void {
        x.gangs[index] = key;
    }
    pub fn player(x: *Ctx, slot: u8) EntityId {
        return x.sim.pedOf(slot) orelse .none;
    }
    pub fn addTrigger(x: *Ctx, t: W.decl.Trigger) void {
        x.triggers += 1;
        x.last_trigger = t;
    }
};

const Env = struct {
    grid: *map.Grid,
    sim: *S,
    ctx: *Ctx,

    fn init() !Env {
        const gpa = std.testing.allocator;
        const g = try gpa.create(map.Grid);
        testmap.build(g);
        const s = try gpa.create(S);
        s.init(g, .{ .seed = 11, .mode = .authoritative });
        const x = try gpa.create(Ctx);
        x.* = .{ .sim = s };
        return .{ .grid = g, .sim = s, .ctx = x };
    }
    fn deinit(e: *Env) void {
        const gpa = std.testing.allocator;
        gpa.destroy(e.ctx);
        gpa.destroy(e.sim);
        gpa.destroy(e.grid);
    }
    fn join(e: *Env) void {
        var frames = [_]Frame{Frame.neutral(0)};
        e.sim.step(&frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(40, 40) }});
    }
    fn run(e: *Env, kind: u16, num: u16, b: []const u8) W.Outcome {
        return W.exec(S, e.sim, e.ctx, .{ .num = num, .kind = kind, .params = b });
    }
    fn get(e: *Env, id: EntityId, comptime C: type) *C {
        return e.sim.state.world.get(id, C).?;
    }
};

/// Parameter bytes, little-endian, written at offsets.
const B = struct {
    b: [48]u8 = @splat(0),
    n: usize = 0,
    fn u16_(x: *B, o: usize, v: u16) *B {
        std.mem.writeInt(u16, x.b[o..][0..2], v, .little);
        x.n = @max(x.n, o + 2);
        return x;
    }
    fn i32_(x: *B, o: usize, v: i32) *B {
        std.mem.writeInt(i32, x.b[o..][0..4], v, .little);
        x.n = @max(x.n, o + 4);
        return x;
    }
    /// A script position in blocks (x, y), with the ground sentinel.
    fn pos2d(x: *B, o: usize, bx: i32, by: i32) *B {
        _ = x.i32_(o, bx * W.script_one + W.script_one / 2);
        _ = x.i32_(o + 4, by * W.script_one + W.script_one / 2);
        return x.i32_(o + 8, W.ground_sentinel);
    }
    fn s(x: *const B) []const u8 {
        return x.b[0..x.n];
    }
};

fn blk(i: i32) fx.Fx {
    return fx.fromInt(i) + fx.half;
}

test "script world: headings follow the lane arrows (90 is +x, 0 is +y)" {
    try std.testing.expectEqual(@as(u16, 0), W.heading(90));
    try std.testing.expectEqual(@as(u16, 16384), W.heading(0));
    try std.testing.expectEqual(@as(u16, 32768), W.heading(270));
    try std.testing.expectEqual(@as(u16, 49152), W.heading(180));
    try std.testing.expectEqual(@as(u16, 16384), W.heading(360));
    try std.testing.expectEqual(fx.one, W.fromScript(W.script_one));
    var b: B = .{};
    const p = W.P{ .b = b.pos2d(0, 3, 4).s() };
    const q = p.pos(0);
    try std.testing.expect(q.ground);
    try std.testing.expectEqual(blk(3), q.x);
    try std.testing.expectEqual(blk(4), q.y);
}

test "script world: the player ped declaration moves the player and is found by its number" {
    var e = try Env.init();
    defer e.deinit();
    e.join();
    e.ctx.decl = true;
    var b: B = .{};
    _ = b.pos2d(4, 42, 41).u16_(16, 90).u16_(18, 7);
    try std.testing.expectEqual(W.Outcome.done, e.run(5, 1, b.s()));
    const id = e.ctx.handles[1];
    try std.testing.expect(eql(id, e.sim.pedOf(0).?));
    const t = e.get(id, c.Transform);
    try std.testing.expectEqual(blk(42), t.x);
    try std.testing.expectEqual(blk(41), t.y);
    try std.testing.expectEqual(@as(u16, 0), t.heading);
    try std.testing.expectEqual(@as(u16, 7), e.get(id, c.Appearance).remap);
    try std.testing.expectEqual(@as(u16, 1), e.get(id, c.ScriptTag).handle);
}

test "script world: parked cars sit on the ground; mission cars join the cleanup list" {
    var e = try Env.init();
    defer e.deinit();
    e.ctx.decl = true;
    var b: B = .{};
    _ = b.pos2d(4, 40, 44).u16_(16, 180).u16_(18, 3).u16_(20, 0).u16_(22, W.no_model);
    try std.testing.expectEqual(W.Outcome.done, e.run(426, 20, b.s()));
    const car = e.ctx.handles[20];
    try std.testing.expect(!car.isNone());
    const t = e.get(car, c.Transform);
    try std.testing.expectEqual(blk(40), t.x);
    try std.testing.expectEqual(@as(u16, 49152), t.heading);
    try std.testing.expect(t.z >= 0);
    try std.testing.expectEqual(@as(u16, 3), e.get(car, c.Appearance).remap);
    const tag = e.get(car, c.ScriptTag);
    try std.testing.expect(tag.flags & W.tag_parked != 0 and tag.flags & c.ScriptTag.flag_keep != 0);
    try std.testing.expectEqual(@as(usize, 0), e.ctx.n_cleanup);

    // A runtime creation in a thread goes into variable 30, and the cleanup list.
    e.ctx.decl = false;
    _ = b.u16_(0, 30);
    try std.testing.expectEqual(W.Outcome.done, e.run(44, 77, b.s()));
    const m = e.ctx.handles[30];
    try std.testing.expect(!m.isNone() and e.ctx.handles[77].isNone());
    try std.testing.expectEqual(@as(usize, 1), e.ctx.n_cleanup);
    try std.testing.expect(e.get(m, c.ScriptTag).flags & c.ScriptTag.flag_mission != 0);
}

test "script world: car conditions read damage, place, driver and wreck" {
    var e = try Env.init();
    defer e.deinit();
    var b: B = .{};
    _ = b.u16_(0, 30).pos2d(4, 40, 44).u16_(16, 90);
    _ = e.run(44, 77, b.s());
    e.sim.state.world.applyPending();
    const car = e.ctx.handles[30];
    // 129: damage at least 320 x level.
    e.get(car, c.Health).hp = T.car_damage_max - 320 * 10;
    var q: B = .{};
    _ = e.run(129, 1, q.u16_(0, 30).u16_(2, 10).s());
    try std.testing.expect(e.ctx.cond);
    _ = e.run(129, 1, q.u16_(2, 11).s());
    try std.testing.expect(!e.ctx.cond);
    // 139: within a block of a point.
    var p: B = .{};
    _ = e.run(139, 1, p.u16_(0, 30).pos2d(4, 41, 44).s());
    try std.testing.expect(e.ctx.cond);
    _ = e.run(139, 1, p.pos2d(4, 43, 44).s());
    try std.testing.expect(!e.ctx.cond);
    // 270: inside a rectangle.
    var r: B = .{};
    const t = e.get(car, c.Transform);
    _ = r.u16_(0, 30).i32_(4, 40 * W.script_one + W.script_one / 2).i32_(8, 44 * W.script_one + W.script_one / 2);
    _ = r.i32_(12, t.z >> 2).i32_(16, 2 * W.script_one).i32_(20, 2 * W.script_one);
    _ = e.run(270, 1, r.s());
    try std.testing.expect(e.ctx.cond);
    _ = e.run(189, 1, r.s());
    try std.testing.expect(!e.ctx.cond); // there, but not wrecked
    // 250/130: no driver until 100 puts one in.
    var d: B = .{};
    _ = e.run(250, 1, d.u16_(0, 30).s());
    try std.testing.expect(!e.ctx.cond);
    _ = e.run(100, 1, d.s());
    _ = e.run(130, 1, d.s());
    try std.testing.expect(e.ctx.cond);
    // 154: wrecked once the damage is full.
    _ = e.run(154, 1, d.s());
    try std.testing.expect(!e.ctx.cond);
    e.get(car, c.Health).hp = 0;
    _ = e.run(154, 1, d.s());
    try std.testing.expect(e.ctx.cond);
}

test "script world: characters are created, armed, grouped, warped and killed" {
    var e = try Env.init();
    defer e.deinit();
    e.join();
    var b: B = .{};
    _ = b.u16_(0, 40).pos2d(4, 42, 42).u16_(16, 0).u16_(18, 2).u16_(20, 18);
    try std.testing.expectEqual(W.Outcome.done, e.run(42, 100, b.s()));
    const ped = e.ctx.handles[40];
    try std.testing.expect(!ped.isNone());
    try std.testing.expectEqual(@as(u16, 16384), e.get(ped, c.Transform).heading);
    // 138: an AI ped's weapon is forced, with no ammo count.
    var w: B = .{};
    _ = e.run(138, 1, w.u16_(0, 40).u16_(2, 6).s());
    const wpn = e.get(ped, c.Weapon);
    try std.testing.expectEqual(T.weapon_shotgun, wpn.kind);
    try std.testing.expectEqual(T.infinite_ammo, wpn.rounds()[T.weapon_shotgun]);
    _ = e.run(420, 1, w.s());
    try std.testing.expect(e.ctx.cond);
    // 266 on the player: the amount is added (100 = the pickup amount).
    e.ctx.handles[1] = e.sim.pedOf(0).?;
    var a: B = .{};
    _ = e.run(266, 1, a.u16_(0, 1).u16_(2, 1).u16_(4, 100).s());
    const pw = e.get(e.ctx.handles[1], c.Weapon);
    try std.testing.expectEqual(T.weapons[T.weapon_smg].pickup_rounds * 10, pw.rounds()[T.weapon_smg]);
    // 153: followers; 234 counts the living ones; 419 disbands.
    var g: B = .{};
    _ = e.run(153, 1, g.u16_(0, 40).u16_(2, 3).s());
    e.sim.state.world.applyPending();
    _ = e.run(234, 1, g.s());
    try std.testing.expect(e.ctx.cond);
    _ = e.run(234, 1, g.u16_(2, 4).s());
    try std.testing.expect(!e.ctx.cond);
    _ = e.run(419, 1, g.s());
    _ = e.run(234, 1, g.u16_(2, 1).s());
    try std.testing.expect(!e.ctx.cond);
    // 145-150: arrived in a rectangle at that level, on foot.
    var r: B = .{};
    const t = e.get(ped, c.Transform);
    _ = r.u16_(0, 40).i32_(4, 42 * W.script_one + W.script_one / 2).i32_(8, 42 * W.script_one + W.script_one / 2);
    _ = r.i32_(12, t.z >> 2).i32_(16, W.script_one).i32_(20, W.script_one);
    _ = e.run(146, 1, r.s());
    try std.testing.expect(e.ctx.cond);
    _ = e.run(147, 1, r.s());
    try std.testing.expect(!e.ctx.cond); // not in a car
    // 357: warp; 363 invincible; 371 kills; 127 dead.
    var v: B = .{};
    _ = e.run(357, 1, v.u16_(0, 40).pos2d(4, 45, 42).s());
    try std.testing.expectEqual(blk(45), e.get(ped, c.Transform).x);
    var k: B = .{};
    _ = e.run(127, 1, k.u16_(0, 40).s());
    try std.testing.expect(!e.ctx.cond);
    _ = e.run(371, 1, k.s());
    _ = e.run(127, 1, k.s());
    try std.testing.expect(e.ctx.cond);
}

test "script world: drivers, passengers and the in-car queries" {
    var e = try Env.init();
    defer e.deinit();
    var b: B = .{};
    _ = e.run(44, 1, b.u16_(0, 30).pos2d(4, 40, 44).s());
    var p: B = .{};
    _ = e.run(42, 1, p.u16_(0, 40).pos2d(4, 41, 44).s());
    _ = e.run(42, 1, p.u16_(0, 41).s());
    e.sim.state.world.applyPending();
    var s: B = .{};
    _ = e.run(171, 1, s.u16_(0, 40).u16_(2, 30).s());
    _ = e.run(171, 1, s.u16_(0, 41).s());
    const car = e.ctx.handles[30];
    try std.testing.expect(eql(e.get(car, c.Vehicle).driver, e.ctx.handles[40]));
    var q: B = .{};
    _ = e.run(121, 1, q.u16_(0, 41).u16_(2, 30).s());
    try std.testing.expect(e.ctx.cond);
    _ = e.run(123, 1, q.s());
    try std.testing.expect(e.ctx.cond);
    // 253 kills the passenger, not the driver.
    var k: B = .{};
    _ = e.run(253, 1, k.u16_(0, 30).s());
    try std.testing.expectEqual(@as(i32, 0), e.get(e.ctx.handles[41], c.Health).hp);
    try std.testing.expect(e.get(e.ctx.handles[40], c.Health).hp > 0);
    // 128 stores the character's car in a variable and protects it.
    var r: B = .{};
    _ = e.run(128, 1, r.u16_(0, 40).u16_(2, 50).s());
    try std.testing.expect(eql(e.ctx.handles[50], car));
    // 140 removes it.
    _ = e.run(140, 1, r.u16_(0, 50).s());
    e.sim.state.world.applyPending();
    try std.testing.expect(!e.sim.state.world.isAlive(car));
}

test "script world: player locks, wanted level, the fail flag and mission bookkeeping" {
    var e = try Env.init();
    defer e.deinit();
    e.join();
    e.ctx.handles[1] = e.sim.pedOf(0).?;
    var b: B = .{};
    _ = e.run(407, 1, b.u16_(0, 1).u16_(2, 0).s());
    try std.testing.expect(e.sim.state.sp.world.flags & W.State.flag_no_controls != 0);
    // With controls off the player's input does nothing.
    const before = e.get(e.ctx.handles[1], c.Transform).*;
    var frames = [_]Frame{Frame.neutral(0)};
    frames[0].throttle = 127;
    for (0..20) |_| e.sim.step(&frames, &.{});
    try std.testing.expectEqual(before.x, e.get(e.ctx.handles[1], c.Transform).x);
    _ = e.run(407, 1, b.u16_(2, 1).s());
    try std.testing.expect(e.sim.state.sp.world.flags & W.State.flag_no_controls == 0);
    _ = e.run(400, 1, b.u16_(2, 0).s());
    try std.testing.expect(e.sim.state.sp.world.flags & W.State.flag_no_enter != 0);
    // 443 reads the VM's flag; 432 needs a live character.
    e.ctx.death = true;
    _ = e.run(443, 1, &.{});
    try std.testing.expect(e.ctx.cond);
    _ = e.run(432, 1, b.u16_(2, 1).s());
    try std.testing.expect(e.ctx.notify);
    _ = e.run(432, 1, b.u16_(0, 99).u16_(2, 0).s());
    try std.testing.expect(e.ctx.notify); // invalid handle: no-op
    // 304 caps the level; 0 also forces police on.
    var d: B = .{};
    e.ctx.decl = true;
    _ = e.run(304, 1, d.u16_(2, 4).s());
    try std.testing.expectEqual(@as(u8, 4), e.sim.state.sp.world.max_wanted);
    _ = e.run(304, 1, d.u16_(2, 0).s());
    try std.testing.expect(e.sim.state.sp.world.flags & W.State.flag_police_forced != 0);
    // Bookkeeping declarations.
    var m: B = .{};
    _ = e.run(240, 1, m.u16_(0, 1).u16_(2, 144).s());
    try std.testing.expectEqual(@as(u16, 144), e.ctx.mission_flags[0]);
    _ = e.run(430, 1, m.s());
    try std.testing.expectEqual(@as(u16, 144), e.ctx.mission_flags[2]);
    var fb: B = .{};
    _ = e.run(436, 1, fb.i32_(4, 4200).s());
    try std.testing.expectEqual(@as(u16, 4200), e.ctx.fail_base[1]);
    var gi: B = .{};
    _ = e.run(223, 45, gi.u16_(0, 238).s());
    _ = e.run(223, 46, gi.u16_(0, 239).s());
    try std.testing.expectEqual(@as(u16, 239), e.ctx.gangs[1]);
    var f: B = .{};
    _ = e.run(343, 1, f.i32_(0, 5_000_000).s());
    try std.testing.expectEqual(@as(i32, 5_000_000), e.sim.state.sp.world.finish_score);
    _ = e.run(230, 1, f.u16_(0, 928).u16_(2, 935).u16_(4, 2).s());
    try std.testing.expectEqual(@as(u16, 935), e.sim.state.sp.world.door_anims[0].end);
    // A car trigger reaches the VM only when both ends exist.
    var t: B = .{};
    _ = e.run(211, 1, t.u16_(6, 843).u16_(8, 1).u16_(10, 60).s());
    try std.testing.expectEqual(@as(usize, 0), e.ctx.triggers);
    var cb: B = .{};
    _ = e.run(10, 60, cb.pos2d(4, 40, 44).s());
    _ = e.run(211, 1, t.s());
    try std.testing.expectEqual(@as(usize, 1), e.ctx.triggers);
    try std.testing.expectEqual(@as(u16, 843), e.ctx.last_trigger.thread);
}

test "script world: every listed command runs on empty parameters and none is unknown" {
    var e = try Env.init();
    defer e.deinit();
    e.join();
    const zero: [40]u8 = @splat(0);
    inline for (.{ W.decl, W.cars, W.chars, W.objects, W.player }) |F| {
        for (F.done ++ F.stubbed) |k| {
            const r = e.run(k, 3000, &zero);
            try std.testing.expect(r != .unhandled);
            try std.testing.expect(W.coverage(k) != .unhandled);
        }
    }
    try std.testing.expectEqual(W.Outcome.unhandled, e.run(59, 1, &zero)); // A1's
    try std.testing.expectEqual(W.Outcome.unhandled, W.coverage(59));
    // dm16 has no script world at all.
    try std.testing.expectEqual(W.Outcome.unhandled, W.exec(simmod.Sim16, undefined, e.ctx, .{ .num = 1, .kind = 141 }));
}

test "script world: doors, generators, areas and phones reach B's objects" {
    var e = try Env.init();
    defer e.deinit();
    e.ctx.decl = true;
    // 378: a double door on block (40, 44, 2), face byte 1, animation 0,
    // open rule 0 (any player), close rule 2, check area 1x1 at the block.
    var d: B = .{};
    d.b[4] = 40;
    d.b[5] = 44;
    d.b[6] = 2;
    d.b[7] = 1;
    d.b[10] = 2;
    _ = d.i32_(12, 40 * W.script_one + W.script_one / 2).i32_(16, 44 * W.script_one + W.script_one / 2).i32_(20, 2 * W.script_one);
    _ = d.i32_(24, W.script_one).i32_(28, W.script_one).i32_(32, 0);
    try std.testing.expectEqual(W.Outcome.done, e.run(378, 417, d.s()));
    const door = e.ctx.handles[417];
    try std.testing.expect(S.objects.doorState(e.sim, door) != null);
    var o: B = .{};
    _ = e.run(177, 1, o.u16_(0, 417).s());
    try std.testing.expectEqual(@as(@TypeOf(S.objects.doorState(e.sim, door).?), .open), S.objects.doorState(e.sim, door).?);
    // 30: a generator of model 210 every 1800 ticks.
    var g: B = .{};
    _ = g.pos2d(4, 42, 42).u16_(16, 0).u16_(18, 210).u16_(20, 1800).u16_(22, 1800).u16_(24, 15);
    try std.testing.expectEqual(W.Outcome.done, e.run(30, 226, g.s()));
    try std.testing.expectEqual(@as(u32, 210), @as(u32, S.objects.objectModel(e.sim, e.ctx.handles[226]).?));
    // 27: a conveyor pushing +x.
    var a: B = .{};
    _ = a.pos2d(4, 41, 41).i32_(16, 2 * W.script_one).i32_(20, 2 * W.script_one);
    a.b[24] = 1;
    a.n = 28;
    try std.testing.expectEqual(W.Outcome.done, e.run(27, 211, a.s()));
    const t = e.get(e.ctx.handles[211], c.Transform);
    const push = S.objects.conveyorPush(e.sim, blk(41), blk(41), t.z).?;
    try std.testing.expectEqual(W.decl.conveyor_unit, push.vx);
    // A phone model (178) becomes a phone; rung by 168 it is ringing but
    // neither answered nor timed out yet.
    var ph: B = .{};
    _ = ph.pos2d(4, 43, 43).u16_(16, 178);
    _ = e.run(16, 300, ph.s());
    const phone = e.ctx.handles[300];
    try std.testing.expect(!phone.isNone());
    var r: B = .{};
    try std.testing.expectEqual(@as(u8, @backingInt(@import("../ids.zig").ObjectKind.phone)), e.get(phone, c.Object).kind);
    _ = e.run(168, 1, r.u16_(0, 300).u16_(4, 50).s());
    try std.testing.expect(e.get(phone, c.Object).state & 1 != 0); // ringing
    _ = e.run(227, 1, r.s());
    try std.testing.expect(!e.ctx.cond);
    _ = e.run(228, 1, r.s());
    try std.testing.expect(!e.ctx.cond);
}

test "script world: wanted stars, score and multiplier go through the career and wanted APIs" {
    var e = try Env.init();
    defer e.deinit();
    e.join();
    e.ctx.handles[1] = e.sim.pedOf(0).?;
    var b: B = .{};
    _ = e.run(164, 1, b.u16_(0, 1).u16_(2, 3).s());
    try std.testing.expectEqual(@as(u8, 3), S.wanted.stars(e.sim, 0));
    _ = e.run(421, 1, b.u16_(2, 2).s());
    try std.testing.expectEqual(@as(u8, 3), S.wanted.stars(e.sim, 0)); // 421 never lowers
    _ = e.run(164, 1, b.u16_(2, 9).s());
    try std.testing.expectEqual(@as(u8, 3), S.wanted.stars(e.sim, 0)); // out of range: ignored
    _ = e.run(163, 1, b.s());
    try std.testing.expectEqual(@as(u8, 0), S.wanted.stars(e.sim, 0));
    const before = S.career.score(e.sim, 0);
    var m: B = .{};
    _ = e.run(392, 1, m.u16_(0, 1).i32_(4, 500).s());
    try std.testing.expectEqual(before + 500, S.career.score(e.sim, 0));
    _ = e.run(194, 1, m.i32_(4, before + 499).s());
    try std.testing.expect(e.ctx.cond);
}
