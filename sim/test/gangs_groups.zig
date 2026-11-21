//! Tests: groups, formations, recruiting and group attacks (ped-ai.md
//! 3.11-3.12), in a small single-player configuration. Workstream D2.
//! The objectives API is D1's; until it lands these check the group
//! bookkeeping, not the resulting movement.

const std = @import("std");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const map = h_.map;
const c = h_.c;
const T = h_.T;
const Frame = h_.Frame;
const testmap = h_.testmap;
const EntityId = abi.EntityId;
const blk = h_.blk;
const eql = h_.eql;
const ids = simmod.ids;
const groups_mod = @import("../ai/groups.zig");

const cfg: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 8, .ped_capacity = 32, .projectile_capacity = 16, .pickup_capacity = 4, .map_object_capacity = 4 };
const Sp = simmod.Sim(cfg);
const Gr = Sp.groups;

const H = struct {
    grid: *map.Grid,
    sim: *Sp,
    frames: [1]Frame = .{Frame.neutral(0)},

    fn init() !H {
        const g = try std.testing.allocator.create(map.Grid);
        testmap.build(g);
        const s = try std.testing.allocator.create(Sp);
        s.init(g, .{ .seed = 5, .mode = .authoritative });
        var h: H = .{ .grid = g, .sim = s };
        h.sim.step(&h.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(60, 37) }});
        h.sim.state.world.get(h.me(), c.Group).?.* = .{};
        h.sim.state.world.get(h.me(), c.Appearance).?.remap = 7;
        return h;
    }
    fn deinit(h: *H) void {
        std.testing.allocator.destroy(h.sim);
        std.testing.allocator.destroy(h.grid);
    }
    fn me(h: *H) EntityId {
        return h.sim.pedOf(0).?;
    }
    fn run(h: *H, n: u32) void {
        for (0..n) |_| h.sim.step(&h.frames, &.{});
    }
    /// A civilian standing at (x, y) blocks.
    fn civ(h: *H, x: Fx, y: Fx) EntityId {
        const id = h.sim.spawnPed(c.Controller.no_player, 0).?;
        h.sim.state.world.applyPending();
        h.sim.state.world.get(id, c.Group).?.* = .{};
        const t = h.sim.transformOf(id).?;
        t.* = .{ .x = x, .y = y, .z = h.sim.transformOf(h.me()).?.z, .heading = 0 };
        return id;
    }
    fn gr(h: *H, id: EntityId) *c.Group {
        return h.sim.state.world.get(id, c.Group).?;
    }
};
const Fx = fx.Fx;

test "groups: slots fill in order, the cap is 8 followers, leave and disband" {
    var h = try H.init();
    defer h.deinit();
    var m: [9]EntityId = undefined;
    for (&m, 0..) |*p, i| p.* = h.civ(blk(50 + @as(i32, @intCast(i))), blk(37));
    for (m[0..8], 1..) |p, slot| {
        try std.testing.expect(Gr.join(h.sim, p, h.me()));
        try std.testing.expectEqual(@as(u8, @intCast(slot)), h.gr(p).slot);
    }
    try std.testing.expect(!Gr.join(h.sim, m[8], h.me()));
    try std.testing.expectEqual(@as(u8, 8), Gr.size(h.sim, h.me()));
    Gr.leave(h.sim, m[2]);
    try std.testing.expectEqual(@as(u8, 7), Gr.size(h.sim, h.me()));
    // The freed slot is taken next.
    try std.testing.expect(Gr.join(h.sim, m[8], h.me()));
    try std.testing.expectEqual(@as(u8, 3), h.gr(m[8]).slot);
    Gr.disband(h.sim, h.me());
    try std.testing.expectEqual(@as(u8, 0), Gr.size(h.sim, h.me()));
}

test "formation: a stationary leader pulls everyone in; moving, the wedge or the chain" {
    var h = try H.init();
    defer h.deinit();
    var m: [8]EntityId = undefined;
    for (&m, 0..) |*p, i| {
        p.* = h.civ(blk(50 + @as(i32, @intCast(i))), blk(37));
        _ = Gr.join(h.sim, p.*, h.me());
    }
    for (m) |p| try std.testing.expect(eql(Gr.formationTarget(h.sim, p), h.me()));
    h.sim.state.world.get(h.me(), c.Velocity).?.vx = T.ped_run;
    // Normal: three trail the leader, five trail the front rank.
    for (m[0..3]) |p| try std.testing.expect(eql(Gr.formationTarget(h.sim, p), h.me()));
    for (m[3..], 4..) |p, slot| {
        const parent = groups_mod.wedge_parent[slot];
        try std.testing.expect(eql(Gr.formationTarget(h.sim, p), m[parent - 1]));
    }
    // Chain: nose to tail.
    Gr.setChain(h.sim, h.me(), true);
    try std.testing.expect(eql(Gr.formationTarget(h.sim, m[0]), h.me()));
    for (m[1..], 1..) |p, i| try std.testing.expect(eql(Gr.formationTarget(h.sim, p), m[i - 1]));
    // A missing link falls back to the leader.
    Gr.leave(h.sim, m[3]);
    try std.testing.expect(eql(Gr.formationTarget(h.sim, m[4]), h.me()));
}

test "recruiting: the nearest eligible peds in the box, dual pistols, the recruiter's look and gang" {
    var h = try H.init();
    defer h.deinit();
    const t = h.sim.transformOf(h.me()).?;
    h.gr(h.me()).gang = 3;
    const near = [_]EntityId{
        h.civ(t.x + fx.one, t.y), h.civ(t.x - fx.fromInt(2), t.y), h.civ(t.x, t.y + fx.fromInt(3)), h.civ(t.x + fx.fromInt(3), t.y - fx.fromInt(3)),
    };
    const nearest_extra = h.civ(t.x + fx.fromInt(4) - fx.ratio(1, 10), t.y + fx.fromInt(4) - fx.ratio(1, 10));
    const outside = h.civ(t.x + fx.fromInt(5), t.y);
    // A gang member is not an ordinary background ped.
    const ganger = h.civ(t.x + fx.half, t.y);
    h.gr(ganger).gang = 1;
    try std.testing.expectEqual(@as(u8, 4), Sp.gangs.instantGang(h.sim, 0));
    for (near) |p| {
        try std.testing.expect(eql(h.gr(p).leader, h.me()));
        try std.testing.expectEqual(@as(u8, 3), h.gr(p).gang);
        try std.testing.expect(h.gr(p).flags & c.Group.flag_follower != 0);
        try std.testing.expect(h.gr(p).flags & c.Group.flag_no_jump != 0);
        const wp = h.sim.state.world.get(p, c.Weapon).?;
        try std.testing.expectEqual(T.weapon_dual_pistol, wp.kind);
        try std.testing.expect(wp.rounds()[T.weapon_dual_pistol] > 0);
        try std.testing.expectEqual(@as(u8, 7), h.sim.state.world.get(p, c.Appearance).?.remap);
    }
    try std.testing.expect(h.gr(nearest_extra).leader.isNone());
    try std.testing.expect(h.gr(ganger).leader.isNone());
    // Again: the one left in the box joins; the one outside does not.
    try std.testing.expectEqual(@as(u8, 1), Gr.recruit(h.sim, h.me(), 4));
    try std.testing.expect(eql(h.gr(nearest_extra).leader, h.me()));
    try std.testing.expect(h.gr(outside).leader.isNone());
}

test "recruiting poaches another group's follower" {
    var h = try H.init();
    defer h.deinit();
    const t = h.sim.transformOf(h.me()).?;
    const boss = h.civ(t.x + fx.fromInt(10), t.y);
    const f = h.civ(t.x + fx.one, t.y);
    try std.testing.expect(Gr.join(h.sim, f, boss));
    try std.testing.expectEqual(@as(u8, 1), Gr.recruit(h.sim, h.me(), 1));
    try std.testing.expect(eql(h.gr(f).leader, h.me()));
    try std.testing.expectEqual(@as(u8, 0), Gr.size(h.sim, boss));
}

test "groups: a dead leader frees his followers" {
    var h = try H.init();
    defer h.deinit();
    const boss = h.civ(blk(52), blk(37));
    const f = h.civ(blk(53), blk(37));
    _ = Gr.join(h.sim, f, boss);
    h.sim.state.world.get(boss, c.Health).?.hp = 0;
    h.run(2);
    try std.testing.expect(h.gr(f).leader.isNone());
}

test "group attack: members pair off against a rival group, both sides fighting" {
    var h = try H.init();
    defer h.deinit();
    const a = h.civ(blk(50), blk(37));
    const b = h.civ(blk(54), blk(37));
    var am: [3]EntityId = undefined;
    var bm: [3]EntityId = undefined;
    for (&am, &bm, 0..) |*x, *y, i| {
        x.* = h.civ(blk(50), blk(36) + fx.fromInt(@intCast(i)) - fx.half);
        y.* = h.civ(blk(54), blk(36) + fx.fromInt(@intCast(i)) - fx.half);
        _ = Gr.join(h.sim, x.*, a);
        _ = Gr.join(h.sim, y.*, b);
    }
    Gr.attack(h.sim, a, bm[1]);
    for (am) |x| try std.testing.expect(h.gr(x).flags & c.Group.flag_fighting != 0);
    try std.testing.expect(h.gr(bm[0]).flags & c.Group.flag_fighting != 0);
    // A lone target far from a member's leader: that member goes back.
    const lone = h.civ(blk(70), blk(37));
    const far = h.civ(blk(58), blk(37));
    _ = Gr.join(h.sim, far, a);
    h.gr(far).flags = 0;
    Gr.attack(h.sim, a, lone);
    try std.testing.expect(h.gr(far).flags & c.Group.flag_fighting == 0);
    try std.testing.expect(h.gr(am[0]).flags & c.Group.flag_fighting != 0);
}

test "end to end: recruits follow a walking leader; a gang fight starts (needs D1's objectives)" {
    if (!@hasDecl(Sp.objectives, "attack")) return error.SkipZigTest;
    var h = try H.init();
    defer h.deinit();
    const t = h.sim.transformOf(h.me()).?;
    const a = h.civ(t.x + fx.one, t.y);
    const b = h.civ(t.x - fx.one, t.y);
    try std.testing.expectEqual(@as(u8, 2), Gr.recruit(h.sim, h.me(), 2));
    // Walk east along the pavement for 80 ticks.
    h.frames[0].throttle = 127;
    h.sim.transformOf(h.me()).?.heading = 0;
    h.run(80);
    h.frames[0].throttle = 0;
    h.run(60);
    const lt = h.sim.transformOf(h.me()).?;
    for ([_]EntityId{ a, b }) |p| {
        const pt = h.sim.transformOf(p).?;
        try std.testing.expect(fx.length(pt.x - lt.x, pt.y - lt.y) < fx.fromInt(2));
    }
    // A rival pair: an attack order makes both sides fight.
    const boss = h.civ(lt.x + fx.fromInt(3), lt.y);
    const thug = h.civ(lt.x + fx.fromInt(3), lt.y + fx.half);
    _ = Gr.join(h.sim, thug, boss);
    Gr.attack(h.sim, h.me(), thug);
    try std.testing.expect(Sp.objectives.isAttacking(h.sim, a));
    try std.testing.expect(Sp.objectives.isAttacking(h.sim, thug));
}
