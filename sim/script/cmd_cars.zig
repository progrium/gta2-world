//! Runtime car commands (script-cars.md). Owner: workstream A2. A thin
//! layer over the car tasks (F), objectives (D1), explosions and damage
//! (G) and the car components.
//!
//! Layouts (from the player's .scr files; offsets into the parameters).
//! Every car or character is a u16 handle.
//!   43-46, 394-397  variable @0, position @4, heading @16, remap @18,
//!            model @20, trailer model @22
//!   100, 170, 175, 253, 305, 310, 154, 190, 191, 267, 417, 250, 130, 366  car @0
//!   167, 171  character @0, car @2;  166, 368  character @0
//!   330      character variable @0, remap @4, occupation @6, car @8
//!   316, 246, 247  car @0, car @2;  278, 311-313, 361, 374  car @0, value @2
//!   303      car @0, i32 @4;  129  car @0, level @2;  157  car, model @2
//!   158      car, remap @2;  241  car, weapon @2;  358  car @0, weapon @4
//!   139      car @0, position @4;  270, 189  car @0, x y z @4, w @16, h @20
//!   206, 209 car @0, counter @2;  207  character @0, counter @2
//!   128      character @0, variable @2;  188  variable @0, crane @2
//!   144, 398, 403-405  entity @0;  142, 399, 406  position @0
//! Guessed (no level uses them): 169 block x y z as u16 @2 @4 @6; 155
//! remap @2; 159 model @2 remap @4; 200 quarter @2; 208 speed (fx) @4.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const W = @import("world.zig");
const Cmd = W.Cmd;
const Outcome = W.Outcome;

pub const done = [_]u16{ 43, 44, 45, 46, 394, 395, 396, 397, 100, 175, 170, 169, 368, 167, 171, 166, 330, 254, 253, 155, 144, 398, 403, 404, 405, 142, 399, 406, 129, 157, 158, 159, 139, 270, 189, 208, 206, 207, 209, 250, 130, 154, 190, 191, 128, 267, 358, 366, 305 };
/// Waiting on: trailers and cranes (C, cranes note), car flags that no
/// component holds yet (jammed throttle, roof number, alarm, proofs,
/// siren, door locks beyond the script tag), car bombs and vehicle
/// weapons (G), crushing (B), hit records (A1), dents (C).
pub const stubbed = [_]u16{ 188, 374, 316, 246, 247, 303, 310, 278, 311, 312, 313, 361, 200, 241, 417 };

/// The explosion kinds `explodeAt` takes (0 small, 1 car).
const explosion_small: u8 = 0;
const explosion_large: u8 = 1;

pub fn Sys(comptime Self: type) type {
    return struct {
        const H = W.Helpers(Self);
        const Chars = @import("cmd_chars.zig").Sys(Self);

        /// The car creation forms (declarations 10-13, 425-428 and runtime
        /// 43-46, 394-397): one layout. A runtime creation outside the
        /// declaration pass joins the mission cleanup list.
        pub fn create(self: *Self, ctx: anytype, cmd: Cmd, handle: u16, runtime: bool) ?EntityId {
            const p = W.params(cmd);
            const id = H.spawnCar(self, p.pos(4), p.u16_(16), p.u16_(20), p.u16_(18)) orelse return null;
            // The trailer model is spawned and attached by C's trailers
            // (car-height 3.7); until then it is left out.
            var flags: u16 = c.ScriptTag.flag_keep;
            if (runtime and !ctx.declaring()) {
                flags |= c.ScriptTag.flag_mission;
                ctx.addCleanup(id);
            }
            H.tag(self, id, handle, flags);
            // F's traffic never gives up on a script car off-road.
            if (comptime @hasDecl(c.Vehicle, "ai_script")) self.state.world.get(id, c.Vehicle).?.ai_flags |= c.Vehicle.ai_script;
            ctx.setHandle(handle, id);
            return id;
        }

        /// Put `ped` in `car`: as the driver if the seat is free, else as a
        /// passenger (riding, not driving).
        pub fn seat(self: *Self, ped: EntityId, car: EntityId) void {
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle) orelse return;
            if (v.driver.isNone()) return self.board(ped, car);
            w.get(ped, c.Riding).?.vehicle = car;
            w.get(ped, c.Collider).?.flags = c.Collider.flag_disabled;
            w.get(ped, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            w.get(ped, c.Transform).?.* = w.get(car, c.Transform).?.*;
        }

        /// A script-created driver for an empty car (100, 170).
        fn ensureDriver(self: *Self, car: EntityId) void {
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle) orelse return;
            if (!v.driver.isNone()) return;
            const t = w.get(car, c.Transform).?.*;
            const ped = H.spawnPedAt(self, .{ .x = t.x, .y = t.y, .z = t.z, .ground = false }, 0, 0xFFFF, c.Controller.no_player) orelse return;
            Self.objectives.setOccupation(self, ped, .driver);
            H.tag(self, ped, 0, c.ScriptTag.flag_keep);
            self.board(ped, car);
        }

        pub fn exec(self: *Self, ctx: anytype, cmd: Cmd) Outcome {
            const p = W.params(cmd);
            const w = &self.state.world;
            switch (cmd.kind) {
                // 2.1 Creating a car. The gang forms (394-397) take the
                // gang's car model from D2's gang info when it lands; the
                // model in the command stands in.
                43, 44, 45, 46, 394, 395, 396, 397 => _ = create(self, ctx, cmd, p.u16_(0), true),
                // 2.2 AI control.
                100, 170, 175 => {
                    const car = ctx.handle(p.u16_(0));
                    if (!w.isAlive(car)) return .done;
                    if (cmd.kind != 175) ensureDriver(self, car);
                    Self.car_tasks.setCarTask(self, car, if (cmd.kind == 170) .stop else .none, .none, 0, 0);
                },
                169 => {
                    const car = ctx.handle(p.u16_(0));
                    const bx: i32 = p.u16_(2);
                    const by: i32 = p.u16_(4);
                    Self.car_tasks.setCarTask(self, car, .go_to, .none, fx.fromInt(bx) + fx.half, fx.fromInt(by) + fx.half);
                },
                368 => {
                    const car = H.carOf(self, ctx.handle(p.u16_(0)));
                    if (!car.isNone()) Self.car_tasks.setCarTask(self, car, .stop, .none, 0, 0);
                },
                // 2.3 Driver and passengers.
                167 => Self.objectives.setObjective(self, ctx.handle(p.u16_(0)), .{ .kind = .enter_car, .target = ctx.handle(p.u16_(2)) }),
                171 => {
                    const ped = ctx.handle(p.u16_(0));
                    const car = ctx.handle(p.u16_(2));
                    if (w.isAlive(ped) and w.isAlive(car) and H.carOf(self, ped).isNone()) seat(self, ped, car);
                },
                166 => {
                    const ped = ctx.handle(p.u16_(0));
                    if (!H.carOf(self, ped).isNone()) Self.objectives.setObjective(self, ped, .{ .kind = .leave_car, .target = H.carOf(self, ped) });
                },
                330 => {
                    const car = ctx.handle(p.u16_(8));
                    const t = (w.get(car, c.Transform) orelse return .done).*;
                    const ped = H.spawnPedAt(self, .{ .x = t.x, .y = t.y, .z = t.z, .ground = false }, 0, p.u16_(4), c.Controller.no_player) orelse return .done;
                    Self.objectives.setOccupation(self, ped, @import("cmd_chars.zig").occupation(p.u16_(6)));
                    var flags: u16 = c.ScriptTag.flag_keep;
                    if (!ctx.declaring()) {
                        flags |= c.ScriptTag.flag_mission;
                        ctx.addCleanup(ped);
                    }
                    H.tag(self, ped, p.u16_(0), flags);
                    ctx.setHandle(p.u16_(0), ped);
                    seat(self, ped, car);
                },
                254 => ctx.setCond(Chars.groupInCar(self, ctx.handle(p.u16_(0)))),
                253 => killPassengers(self, ctx.handle(p.u16_(0))),
                // 2.5 Cosmetic: the remap (no despawn check, 5).
                155 => {
                    const r = p.u16_(2);
                    if (r != 0xFF and r != 0xFFFF) {
                        if (w.get(ctx.handle(p.u16_(0)), c.Appearance)) |a| a.remap = r;
                    }
                },
                // 2.6 Explosions: a car always gets the plain size (5).
                144, 398, 403, 404, 405 => {
                    const id = ctx.handle(p.u16_(0));
                    const t = (w.get(id, c.Transform) orelse return .done).*;
                    const kind = if (H.isCar(id)) explosion_small else sizeOf(cmd.kind);
                    self.explodeAt(t.x, t.y, t.z, .none, kind);
                },
                142, 399, 406 => {
                    const pos = H.place(self, p.pos(0), T.ped_step);
                    self.explodeAt(pos.x, pos.y, pos.z, .none, sizeOf(cmd.kind));
                },
                // 2.7 Conditions.
                129 => {
                    const car = ctx.handle(p.u16_(0));
                    ctx.setCond(w.isAlive(car) and H.carDamage(self, car) >= 320 * @as(i32, p.u16_(2)));
                },
                157, 158, 159 => {
                    const car = ctx.handle(p.u16_(0));
                    const v = w.get(car, c.Vehicle);
                    const a = w.get(car, c.Appearance);
                    ctx.setCond(switch (cmd.kind) {
                        157 => v != null and v.?.model == p.u16_(2),
                        158 => w.isAlive(car) and a != null and a.?.remap == p.u16_(2),
                        else => w.isAlive(car) and v != null and a != null and v.?.model == p.u16_(2) and a.?.remap == p.u16_(4),
                    });
                },
                139 => {
                    const t = w.get(ctx.handle(p.u16_(0)), c.Transform) orelse return cond(ctx, false);
                    const q = H.place(self, p.pos(4), T.car_step);
                    ctx.setCond(@abs(t.x - q.x) <= fx.one and @abs(t.y - q.y) <= fx.one);
                },
                270, 189 => {
                    const car = ctx.handle(p.u16_(0));
                    const t = w.get(car, c.Transform) orelse return cond(ctx, false);
                    const inside = H.inRect(t, p.fx_(4), p.fx_(8), p.fx_(16), p.fx_(20)) and @abs(t.z - p.fx_(12)) <= fx.one;
                    ctx.setCond(inside and (cmd.kind == 270 or H.wrecked(self, car)));
                },
                208 => {
                    const v = w.get(ctx.handle(p.u16_(0)), c.Velocity) orelse return cond(ctx, false);
                    ctx.setCond(Self.speedOf(v) > p.fx_(4));
                },
                206, 207, 209 => {
                    const id = ctx.handle(p.u16_(0));
                    const car = if (cmd.kind == 207) H.carOf(self, id) else id;
                    const out = ctx.counter(p.u16_(2)) orelse return .done;
                    if (cmd.kind == 209) {
                        const v = w.get(car, c.Vehicle) orelse return .done;
                        out.* = toScript(T.carModel(v.model).max_speed);
                    } else {
                        const v = w.get(car, c.Velocity) orelse return .done;
                        out.* = toScript(Self.speedOf(v));
                    }
                },
                250, 130 => {
                    const v = w.get(ctx.handle(p.u16_(0)), c.Vehicle);
                    ctx.setCond(v != null and !v.?.driver.isNone());
                },
                154 => {
                    const car = ctx.handle(p.u16_(0));
                    ctx.setCond(H.wrecked(self, car) or sunk(self, car));
                },
                190 => ctx.setCond(sunk(self, ctx.handle(p.u16_(0)))),
                191 => {
                    const col = w.get(ctx.handle(p.u16_(0)), c.Collider);
                    ctx.setCond(col != null and col.?.flags & c.Collider.flag_grounded == 0);
                },
                128 => {
                    const car = H.carOf(self, ctx.handle(p.u16_(0)));
                    const old = ctx.handle(p.u16_(2));
                    if (!old.isNone() and !prelude.eql(old, car)) {
                        if (w.get(old, c.ScriptTag)) |t| t.flags &= ~c.ScriptTag.flag_keep;
                    }
                    if (!car.isNone()) H.tag(self, car, p.u16_(2), c.ScriptTag.flag_keep);
                    ctx.setHandle(p.u16_(2), car);
                },
                // Waiting on another system: report a false condition so
                // a thread polling one does not branch on garbage.
                358, 366 => {
                    ctx.setCond(H.hitOnce(self, ctx.handle(p.u16_(0)), if (cmd.kind == 358) @truncate(p.u32_(4)) else null));
                    return if (@hasDecl(Self.script, "hitBy")) .done else .stubbed;
                },
                267 => ctx.setCond(Self.objects.beingCrushed(self, ctx.handle(p.u16_(0)))),
                305 => ctx.setCond(Self.car_weapons.bombArmed(self, ctx.handle(p.u16_(0)))),
                188, 246, 247, 200, 241, 417 => return condStub(ctx, false),
                374, 316, 303, 310, 278, 311, 312, 313, 361 => return .stubbed,
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

        /// Large for 142 (and the first of each pair), small for the rest
        /// (ours: which variant is which size is not in the notes).
        fn sizeOf(kind: u16) u8 {
            return switch (kind) {
                142, 144, 403 => explosion_large,
                else => explosion_small,
            };
        }

        /// Sunk or lifted out of play (154, 190).
        fn sunk(self: *Self, car: EntityId) bool {
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            return v.sink > 0 and v.flags & c.Vehicle.flag_in_water != 0;
        }

        /// 253: every passenger (not the driver). The every-bus rule waits
        /// for public transport.
        fn killPassengers(self: *Self, car: EntityId) void {
            const v = self.state.world.get(car, c.Vehicle) orelse return;
            const Ctx = struct { car: EntityId, driver: EntityId };
            H.eachPed(self, Ctx{ .car = car, .driver = v.driver }, struct {
                fn f(cx: Ctx, sim: *Self, id: EntityId) void {
                    if (prelude.eql(id, cx.driver)) return;
                    if (prelude.eql(H.carOf(sim, id), cx.car)) sim.killPed(id, .none);
                }
            }.f);
        }

        /// Sim speed (fx per tick) in the script's own fixed point.
        fn toScript(v: Fx) i32 {
            return v >> (fx.frac_bits - W.script_frac_bits);
        }
    };
}
