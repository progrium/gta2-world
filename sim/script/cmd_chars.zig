//! Runtime character commands (script-characters.md). Owner: workstream
//! A2. A thin layer over objectives (D1), groups and gangs (D2), weapons
//! and health (G).
//!
//! Layouts (from the player's .scr files; offsets into the parameters).
//! Every character, car or object is a u16 handle.
//!   41, 42   variable @0, position @4, heading @16, remap @18, occupation @20
//!   131      character @0, objective @2
//!   132      character @0, objective @2, target @4, variant byte @6
//!   133      character @0, objective @2, x y z @4
//!   315      character @0, objective @2, car @4, angle (degrees) @6, distance @8
//!   357      character @0, facing @2 (always 0 in the data), position @4
//!   138      entity @0, weapon @2;  266  entity @0, weapon @2, ammo @4
//!   126      character @0, health @2;  363, 432, 306, 384, 385  character @0, on @2
//!   258, 232, 242  character @0, name (string key) @2
//!   262, 393 gang name (string key) @0, steps i16 @2, character @4
//!   198, 199, 231  character @0, level i16 @2, gang name @4
//!   151, 152, 153, 234, 237, 244, 156  character @0, value @2
//!   235, 236, 259, 252, 264  character @0, character @2
//!   307      character @0, speed @4;  359, 408, 410  character @0, value @4
//!   364      character @0, remap @2, graphic @4;  121  character, car @2
//!   122      character, model @2;  145-150  character @0, x y z @4, w @16, h @20
//!   367, 381, 382  character @0, character @2, w @4, h @8
//! Guessed (no level uses them): 225 like 262; 383 like 307; 409 and 176
//! like 145; 320 weapon @4 (like 358); 411 weapon @2; 199 like 198.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const W = @import("world.zig");
const Cmd = W.Cmd;
const Outcome = W.Outcome;
const Obj = @import("../ai/objectives.zig");

pub const done = [_]u16{ 41, 42, 131, 132, 133, 315, 360, 357, 138, 266, 256, 420, 126, 127, 125, 202, 203, 324, 363, 371, 355, 432, 153, 235, 236, 259, 234, 419, 409, 151, 152, 121, 122, 123, 243, 124, 242, 145, 146, 147, 148, 149, 150, 367, 381, 382, 156, 364, 410, 237 };
/// Waiting on: gang names (D2's gang info), respect by gang (D2), group
/// formation (D1), favourite car (D1/F), threat settings and speeds (D1),
/// drive style (F), kill-frenzy weapon (G), combat memory and hit records
/// (D1, A1), bus state (F), spotting the player (D1), attack state (D1).
pub const stubbed = [_]u16{ 258, 232, 225, 262, 393, 198, 199, 231, 359, 408, 383, 307, 306, 411, 412, 252, 255, 264, 320, 244, 384, 385, 369, 370, 176, 165, 251 };

/// Script objective numbers as D1's kinds. Read from how the levels use
/// them (which command form and which target each number comes with);
/// ours until D1 confirms: 12 and 24 go to a point (24 by any means), 14
/// drive there, 26 guard the spot (with or without a point), 25 and 27
/// wait, 19 and 20 kill a character (on foot, by any means), 3 flee from
/// one, 16 destroy a car, 35 get in a car (the variant picks a seat), 36
/// get out, 55 and 56 follow (56 alongside a car).
pub fn objective(raw: u16) Obj.Kind {
    return switch (raw) {
        3 => .flee_ped,
        12, 24 => .go_to,
        14 => .drive_to,
        16 => .destroy_car,
        19, 20 => .kill_ped,
        25, 27 => .wait,
        26 => .guard,
        35 => .enter_car,
        36 => .leave_car,
        55, 56 => .follow,
        else => .none,
    };
}

/// Script occupation numbers as ours. The levels use 3, 18, 28, 33, 41,
/// 43, 45 (creation) and 36, 39 (410) without saying which is which;
/// until D1's ped AI pins them every created character is a civilian
/// (a guess listed in the hand-off).
pub fn occupation(raw: u16) ids.Occupation {
    _ = raw;
    return .civilian;
}

/// Script weapon numbers as `tuning.weapons` indices; vehicle weapons
/// (15 and up) return null. Ours: the order the level scripts hand them
/// out in is not in the notes.
pub fn weapon(raw: u16) ?u8 {
    return switch (raw) {
        0 => T.weapon_pistol,
        1 => T.weapon_smg,
        2 => T.weapon_rocket,
        3 => T.weapon_electro,
        4 => T.weapon_molotov,
        5 => T.weapon_grenade,
        6 => T.weapon_shotgun,
        8 => T.weapon_flamethrower,
        9 => T.weapon_silenced,
        10 => T.weapon_dual_pistol,
        else => null,
    };
}

/// 2.3: an ammo amount of exactly 100 means the weapon's own pickup amount.
pub const ammo_default: u16 = 100;
/// 4: invincibility from 363.
pub const invincible_ticks: u16 = 9999;
/// 4: the "stunned" health line (125).
pub const stunned_hp: i32 = 25;

pub fn Sys(comptime Self: type) type {
    return struct {
        const H = W.Helpers(Self);

        /// The character creation forms (declarations 7/8, runtime 41/42).
        pub fn create(self: *Self, ctx: anytype, cmd: Cmd, handle: u16, runtime: bool) ?EntityId {
            const p = W.params(cmd);
            const id = H.spawnPedAt(self, p.pos(4), p.u16_(16), p.u16_(18), c.Controller.no_player) orelse return null;
            Self.objectives.setOccupation(self, id, occupation(p.u16_(20)));
            var flags: u16 = c.ScriptTag.flag_keep;
            if (runtime and !ctx.declaring()) {
                flags |= c.ScriptTag.flag_mission;
                ctx.addCleanup(id);
            }
            H.tag(self, id, handle, flags);
            ctx.setHandle(handle, id);
            return id;
        }

        /// 254: the character (or every member of the group it leads) is
        /// in a car.
        pub fn groupInCar(self: *Self, leader: EntityId) bool {
            if (!self.state.world.isAlive(leader)) return false;
            if (H.carOf(self, leader).isNone()) return false;
            const Ctx = struct { leader: EntityId, ok: *bool };
            var ok = true;
            H.eachPed(self, Ctx{ .leader = leader, .ok = &ok }, struct {
                fn f(cx: Ctx, sim: *Self, id: EntityId) void {
                    const g = sim.state.world.get(id, c.Group) orelse return;
                    if (eql(g.leader, cx.leader) and !eql(id, cx.leader) and H.carOf(sim, id).isNone()) cx.ok.* = false;
                }
            }.f);
            return ok;
        }

        fn groupCount(self: *Self, leader: EntityId) u32 {
            const Ctx = struct { leader: EntityId, n: *u32 };
            var n: u32 = 0;
            H.eachPed(self, Ctx{ .leader = leader, .n = &n }, struct {
                fn f(cx: Ctx, sim: *Self, id: EntityId) void {
                    const g = sim.state.world.get(id, c.Group) orelse return;
                    const h = sim.state.world.get(id, c.Health) orelse return;
                    if (eql(g.leader, cx.leader) and h.hp > 0) cx.n.* += 1;
                }
            }.f);
            return n;
        }

        fn dead(self: *Self, ped: EntityId) bool {
            const h = self.state.world.get(ped, c.Health) orelse return true;
            return h.hp <= 0;
        }

        pub fn exec(self: *Self, ctx: anytype, cmd: Cmd) Outcome {
            const p = W.params(cmd);
            const w = &self.state.world;
            const ped = ctx.handle(p.u16_(0));
            switch (cmd.kind) {
                41, 42 => _ = create(self, ctx, cmd, p.u16_(0), true),
                // 2.2 Objectives. A fresh one also cancels pending cleanup.
                131, 132, 133, 315 => {
                    const kind = objective(p.u16_(2));
                    var o: Obj.Objective = .{ .kind = kind };
                    switch (cmd.kind) {
                        132 => o.target = ctx.handle(p.u16_(4)),
                        133 => {
                            o.x = p.fx_(4);
                            o.y = p.fx_(8);
                            o.z = p.fx_(12);
                        },
                        315 => {
                            o.target = ctx.handle(p.u16_(4));
                            // Angle and distance to hold beside the car;
                            // D1's follow objective takes them as x and y.
                            o.x = @as(Fx, W.heading(p.u16_(6)));
                            o.y = p.fx_(8);
                        },
                        else => {},
                    }
                    if (w.get(ped, c.ScriptTag)) |t| t.flags &= ~c.ScriptTag.flag_mission;
                    Self.objectives.setObjective(self, ped, o);
                    if (kind == .none and p.u16_(2) != 0) return .stubbed;
                },
                360 => Self.objectives.setObjective(self, ped, .{ .kind = .wait }),
                357 => {
                    const t = w.get(ped, c.Transform) orelse return .done;
                    const car = H.carOf(self, ped);
                    if (!car.isNone()) {
                        self.releaseCar(car);
                        w.get(ped, c.Riding).?.vehicle = .none;
                        w.get(ped, c.Collider).?.flags = c.Collider.flag_grounded;
                        if (H.playerSlot(self, ped)) |s| self.state.players[s].car = .none;
                    }
                    const q = H.place(self, p.pos(4), T.ped_step);
                    t.* = .{ .x = q.x, .y = q.y, .z = q.z, .heading = W.heading(p.u16_(2)) };
                },
                // 2.3 Weapons.
                138, 266 => {
                    const k = weapon(p.u16_(2)) orelse return .stubbed;
                    const wpn = w.get(ped, c.Weapon) orelse return .stubbed; // a car: G's vehicle weapons
                    const amount = if (cmd.kind == 266) p.u16_(4) else ammo_default;
                    if (H.playerSlot(self, ped) != null) {
                        const rounds: u16 = if (amount == ammo_default) T.weapons[k].pickup_rounds else amount;
                        const r = &wpn.rounds()[k];
                        if (r.* != T.infinite_ammo) r.* = @min(T.max_ammo_tenths, r.* +| rounds *| 10);
                    } else {
                        // AI peds keep no ammo: the weapon is forced.
                        for (wpn.rounds()) |*r| r.* = 0;
                        wpn.rounds()[k] = T.infinite_ammo;
                    }
                    wpn.kind = k;
                },
                256 => if (w.get(ped, c.Weapon)) |wpn| {
                    for (wpn.rounds()) |*r| r.* = 0;
                },
                420 => {
                    const wpn = w.get(ped, c.Weapon) orelse return cond(ctx, false);
                    const k = weapon(p.u16_(2));
                    ctx.setCond(k != null and wpn.kind == k.?);
                },
                // 2.4 Health, death and arrest.
                126 => {
                    const h = w.get(ped, c.Health) orelse return cond(ctx, false);
                    ctx.setCond(h.hp >= p.u16_(2));
                },
                127 => ctx.setCond(dead(self, ped)),
                125 => {
                    const h = w.get(ped, c.Health) orelse return cond(ctx, false);
                    const pd = w.get(ped, c.Pedestrian).?;
                    ctx.setCond(pd.state == c.Pedestrian.state_down or pd.state == c.Pedestrian.state_over or h.hp <= stunned_hp);
                },
                202, 203, 324, 355 => {
                    const pd = w.get(ped, c.Pedestrian) orelse return cond(ctx, false);
                    ctx.setCond(switch (cmd.kind) {
                        202 => pd.state == c.Pedestrian.state_falling,
                        203 => pd.state == c.Pedestrian.state_drowning,
                        324 => pd.burn > 0,
                        else => pd.state == c.Pedestrian.state_arrested or (if (H.playerSlot(self, ped)) |s| Self.career.isOut(self, s) and !dead(self, ped) else false),
                    });
                },
                363 => if (w.get(ped, c.Pedestrian)) |pd| {
                    pd.invulnerable = if (p.u16_(2) != 0) invincible_ticks else 0;
                },
                371 => self.killPed(ped, .none),
                // The handle must be valid though it is never read (5).
                432 => if (w.isAlive(ped)) {
                    ctx.notifyDeathArrest().* = p.u16_(2) != 0;
                },
                // 2.5 Groups.
                153 => {
                    var n = p.u16_(2);
                    const t = (w.get(ped, c.Transform) orelse return .done).*;
                    while (n > 0) : (n -= 1) {
                        const f = H.spawnPedAt(self, .{ .x = t.x, .y = t.y, .z = t.z, .ground = false }, 0, 0xFFFF, c.Controller.no_player) orelse break;
                        w.get(f, c.Group).?.leader = ped;
                        H.tag(self, f, 0, c.ScriptTag.flag_keep);
                        Self.objectives.setObjective(self, f, .{ .kind = .follow, .target = ped });
                    }
                },
                235, 236 => {
                    const other = ctx.handle(p.u16_(2));
                    const g = w.get(other, c.Group) orelse return .done;
                    if (cmd.kind == 235) {
                        g.leader = ped;
                        Self.objectives.setObjective(self, other, .{ .kind = .follow, .target = ped });
                    } else if (eql(g.leader, ped)) g.leader = .none;
                },
                259 => {
                    const new_leader = ctx.handle(p.u16_(2));
                    const old = if (w.get(ped, c.Group)) |g| (if (g.leader.isNone()) ped else g.leader) else ped;
                    const Ctx = struct { old: EntityId, new: EntityId };
                    H.eachPed(self, Ctx{ .old = old, .new = new_leader }, struct {
                        fn f(cx: Ctx, sim: *Self, id: EntityId) void {
                            const g = sim.state.world.get(id, c.Group) orelse return;
                            if (eql(g.leader, cx.old) or eql(id, cx.old)) g.leader = if (eql(id, cx.new)) .none else cx.new;
                        }
                    }.f);
                },
                234 => ctx.setCond(groupCount(self, ped) >= p.u16_(2)),
                237 => {}, // Written and never read anywhere (6).
                419 => {
                    const Ctx = struct { leader: EntityId };
                    H.eachPed(self, Ctx{ .leader = ped }, struct {
                        fn f(cx: Ctx, sim: *Self, id: EntityId) void {
                            const g = sim.state.world.get(id, c.Group) orelse return;
                            if (eql(g.leader, cx.leader)) g.leader = .none;
                        }
                    }.f);
                },
                // Only the leader's position decides (5).
                409 => {
                    const t = w.get(ped, c.Transform) orelse return cond(ctx, false);
                    ctx.setCond(H.inRect(t, p.fx_(4), p.fx_(8), p.fx_(16), p.fx_(20)));
                },
                151, 152 => if (Self.objectives.objectiveOf(self, ped).kind == .none) return .stubbed,
                // 2.8 State queries involving a car.
                121 => ctx.setCond(!H.carOf(self, ped).isNone() and eql(H.carOf(self, ped), ctx.handle(p.u16_(2)))),
                122 => {
                    const v = w.get(H.carOf(self, ped), c.Vehicle) orelse return cond(ctx, false);
                    ctx.setCond(v.model == p.u16_(2));
                },
                123 => ctx.setCond(!H.carOf(self, ped).isNone()),
                243 => {
                    const v = w.get(H.carOf(self, ped), c.Vehicle) orelse return cond(ctx, false);
                    ctx.setCond(v.flags & c.Vehicle.flag_horn != 0);
                },
                // 2.9 Other queries.
                124 => {
                    const v = w.get(ped, c.Velocity) orelse return cond(ctx, false);
                    ctx.setCond(v.vx == 0 and v.vy == 0 and v.vz == 0);
                },
                242 => {
                    const t = w.get(ped, c.Transform) orelse return cond(ctx, false);
                    ctx.setCond(inZone(self, ctx.string(p.u16_(2)), fx.toInt(t.x), fx.toInt(t.y)));
                },
                145, 146, 147, 148, 149, 150 => ctx.setCond(arrived(self, ped, cmd.kind, p.fx_(4), p.fx_(8), p.fx_(12), p.fx_(16), p.fx_(20), true)),
                367, 381, 382 => {
                    const t = w.get(ctx.handle(p.u16_(2)), c.Transform) orelse return cond(ctx, false);
                    const k: u16 = switch (cmd.kind) {
                        382 => 145,
                        367 => 146,
                        else => 147,
                    };
                    ctx.setCond(arrived(self, ped, k, t.x, t.y, t.z, p.fx_(4), p.fx_(8), false));
                },
                // 2.10 Appearance.
                156 => if (w.get(ped, c.Appearance)) |a| {
                    a.remap = p.u16_(2);
                },
                364 => if (w.get(ped, c.Appearance)) |a| {
                    a.remap = p.u16_(2);
                    // The graphic set (civilian, default, police) is the
                    // renderer's (H); the sprite base waits on it.
                },
                410 => Self.objectives.setOccupation(self, ped, occupation(p.u16_(4))),
                // Conditions waiting on another system read false.
                320 => {
                    ctx.setCond(H.hitOnce(self, ped, @truncate(p.u16_(4))));
                    return if (@hasDecl(Self.script, "hitBy")) .done else .stubbed;
                },
                232, 198, 199, 231, 255, 264, 244, 369, 176, 165, 251 => return condStub(ctx, false),
                258, 225, 262, 393, 359, 408, 383, 307, 306, 411, 412, 252, 384, 385, 370 => return .stubbed,
                else => return .unhandled,
            }
            return .done;
        }

        fn cond(ctx: anytype, b: bool) Outcome {
            ctx.setCond(b);
            return .done;
        }
        fn condStub(ctx: anytype, b: bool) Outcome {
            ctx.setCond(b);
            return .stubbed;
        }

        /// The "has this character arrived" family (145-150, 367/381/382):
        /// in the rectangle, at that height level, by the right means;
        /// 148-150 also stationary.
        fn arrived(self: *Self, ped: EntityId, kind: u16, x: Fx, y: Fx, z: Fx, wd: Fx, ht: Fx, level: bool) bool {
            const w = &self.state.world;
            const car = H.carOf(self, ped);
            const body = if (car.isNone()) ped else car;
            const t = w.get(body, c.Transform) orelse return false;
            if (!H.inRect(t, x, y, wd, ht)) return false;
            if (level and fx.toInt(t.z) != fx.toInt(z)) return false;
            const mode = (kind - 145) % 3; // 0 any, 1 on foot, 2 in a car
            if (mode == 1 and !car.isNone()) return false;
            if (mode == 2 and car.isNone()) return false;
            if (kind >= 148) {
                const v = w.get(body, c.Velocity) orelse return false;
                if (v.vx != 0 or v.vy != 0) return false;
            }
            return true;
        }

        fn inZone(self: *Self, name: []const u8, bx: i32, by: i32) bool {
            const l = self.level orelse return false;
            for (l.zones) |z| {
                if (z.contains(bx, by) and std.ascii.eqlIgnoreCase(z.name, name)) return true;
            }
            return false;
        }
    };
}
