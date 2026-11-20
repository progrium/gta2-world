//! Declaration commands (script-declarations.md): applied once, in
//! command-number order, by the VM's level-start pass. Owner: workstream
//! A2. A declaration's handle is stored under its own command number.
//!
//! Layouts (from the player's .scr files; offsets into the parameters):
//!   5        u32 unused, position @4, heading u16 @16, remap @18
//!   7, 8     as 41/42 (characters), occupation @20
//!   10-13, 425-428  u32 unused (or a name), position @4, heading @16,
//!            remap @18, model @20, trailer model @22 (0xFFFF none)
//!   15-20    u32 unused, position @4, model @16, rotation @18, value i32 @20
//!   26, 27   u32, position @4, then the area and speed (not decoded)
//!   29-32    u32, position @4, rotation @16, model @18, min and max
//!            delay @20 @22, ammo @24
//!   34, 35   u32, position @4, then the area (not decoded)
//!   40       u32, x @4, y @8 (no height)
//!   211, 213 u16 thread start @6, character @8, car or phone @10
//!   212, 214, 434  thread start @6, x y z @8, width @20, height @24,
//!            character @28
//!   230      start frame @0, end frame @2, speed @4
//!   240, 429-431  u16 unused @0, counter @2
//!   304      u16 unused, stars @2
//!   343      i32 @0;  344, 345, 386-388  count @2
//!   346-349, 389, 390  counter @0;  353  19 model bytes @0
//!   435-437  u16 unused, u32 message base @4;  422  id @0

const std = @import("std");
const prelude = @import("../prelude.zig");
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const W = @import("world.zig");
const Cmd = W.Cmd;
const Outcome = W.Outcome;

pub const done = [_]u16{ 5, 7, 8, 10, 11, 12, 13, 425, 426, 427, 428, 15, 16, 17, 18, 19, 20, 23, 40, 230, 240, 429, 430, 431, 304, 343, 344, 345, 386, 387, 388, 346, 347, 348, 349, 389, 390, 353, 422, 435, 436, 437 };
/// Decoded, waiting on another workstream's API: zone densities (F),
/// cranes (cranes note), conveyors, generators, destructors and doors
/// (B), triggers (A1), gang info (D2), lights (B), trains and radio,
/// sound points (audio), the crane power-up link.
pub const stubbed = [_]u16{ 102, 37, 38, 39, 26, 27, 29, 30, 31, 32, 34, 35, 375, 376, 378, 379, 211, 212, 213, 214, 434, 223, 217, 302, 285, 286, 295, 296, 297, 298, 287, 327, 439 };

/// A trigger declaration (2.10), handed to the VM when it can take it
/// (`ctx.addTrigger`, A1).
pub const Trigger = struct {
    pub const Kind = enum(u8) { car, phone, block, area_on_foot, area_any };
    kind: Kind,
    /// Command number where the new thread starts.
    thread: u16,
    character: EntityId,
    /// The car or phone (car and phone triggers).
    target: EntityId = .none,
    /// The area, centre and size (block and area triggers).
    x: Fx = 0,
    y: Fx = 0,
    z: Fx = 0,
    w: Fx = 0,
    h: Fx = 0,
};

fn ctxHas(comptime Ctx: type, comptime name: []const u8) bool {
    const T = switch (@typeInfo(Ctx)) {
        .pointer => |p| p.child,
        else => Ctx,
    };
    return @hasDecl(T, name);
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const H = W.Helpers(Self);
        const Cars = @import("cmd_cars.zig").Sys(Self);
        const Chars = @import("cmd_chars.zig").Sys(Self);
        const Objs = @import("cmd_objects.zig").Sys(Self);
        const Player = @import("cmd_player.zig").Sys(Self);

        pub fn exec(self: *Self, ctx: anytype, cmd: Cmd) Outcome {
            const p = W.params(cmd);
            const s = H.st(self);
            switch (cmd.kind) {
                5 => playerPed(self, ctx, cmd),
                7, 8 => _ = Chars.create(self, ctx, cmd, cmd.num, false),
                10, 11, 12, 13 => _ = Cars.create(self, ctx, cmd, cmd.num, false),
                425, 426, 427, 428 => if (Cars.create(self, ctx, cmd, cmd.num, false)) |id| H.tag(self, id, cmd.num, W.tag_parked),
                15, 16, 17, 18, 19, 20 => _ = Objs.create(self, ctx, cmd, cmd.num, cmd.kind >= 17, false),
                23 => ctx.setHandle(cmd.num, .none),
                40 => {
                    const pos = H.place(self, .{ .x = p.fx_(4), .y = p.fx_(8), .z = 0, .ground = true }, prelude.T.car_step);
                    if (Self.objects.spawnObject(self, .crusher, 0, pos.x, pos.y, pos.z, 0)) |id| {
                        H.tag(self, id, cmd.num, c.ScriptTag.flag_keep);
                        ctx.setHandle(cmd.num, id);
                    }
                },
                230 => if (s.door_anim_count < W.State.max_door_anims) {
                    s.door_anims[s.door_anim_count] = .{ .start = p.u16_(0), .end = p.u16_(2), .speed = p.u16_(4) };
                    s.door_anim_count += 1;
                },
                240, 429, 430, 431 => {
                    const which: u2 = if (cmd.kind == 240) 0 else @intCast(cmd.kind - 428);
                    s.mission_flags[which] = p.u16_(2);
                    ctx.setMissionFlag(which, p.u16_(2));
                },
                435, 436, 437 => s.fail_base[cmd.kind - 435] = @truncate(p.u32_(4)),
                304 => Player.setMaxWanted(self, p.u16_(2)),
                343 => s.finish_score = p.i32_(0),
                344 => s.totals[0] = p.u16_(2),
                345 => s.totals[1] = p.u16_(2),
                386, 387, 388 => s.totals[2 + cmd.kind - 386] = p.u16_(2),
                346, 347, 348, 349 => s.done_flags[cmd.kind - 346] = p.u16_(0),
                389, 390 => s.done_flags[4 + cmd.kind - 389] = p.u16_(0),
                353 => {
                    var n: u8 = 0;
                    while (n < W.State.max_car_list) : (n += 1) s.car_list[n] = p.u8_(n);
                    s.car_list_len = n;
                },
                422 => if (s.keyframe_count < W.State.max_keyframes) {
                    s.keyframes[s.keyframe_count] = p.u16_(0);
                    s.keyframe_count += 1;
                },
                29, 30, 31, 32 => {
                    generator(self, ctx, cmd);
                    return .stubbed;
                },
                26, 27, 34, 35 => {
                    area(self, ctx, cmd, if (cmd.kind < 30) .conveyor else .destructor);
                    return .stubbed;
                },
                211, 213 => {
                    const t: Trigger = .{ .kind = if (cmd.kind == 211) .car else .phone, .thread = p.u16_(6), .character = ctx.handle(p.u16_(8)), .target = ctx.handle(p.u16_(10)) };
                    // Both must exist (2.10).
                    if (!H.alive(self, t.character) or !H.alive(self, t.target)) return .done;
                    return addTrigger(ctx, t);
                },
                212, 214, 434 => {
                    const ch = ctx.handle(p.u16_(28));
                    if (!H.alive(self, ch)) return .done;
                    const t: Trigger = .{
                        .kind = switch (cmd.kind) {
                            212 => .block,
                            214 => .area_on_foot,
                            else => .area_any,
                        },
                        .thread = p.u16_(6),
                        .character = ch,
                        .x = p.fx_(8),
                        .y = p.fx_(12),
                        .z = p.fx_(16),
                        .w = p.fx_(20),
                        .h = p.fx_(24),
                    };
                    return addTrigger(ctx, t);
                },
                // Decoded elsewhere or waiting on an owner's API.
                102, 37, 38, 39, 375, 376, 378, 379, 223, 217, 302, 285, 286, 295, 296, 297, 298, 287, 327, 439 => return .stubbed,
                else => return .unhandled,
            }
            return .done;
        }

        fn addTrigger(ctx: anytype, t: Trigger) Outcome {
            if (comptime ctxHas(@TypeOf(ctx), "addTrigger")) {
                ctx.addTrigger(t);
                return .done;
            }
            return .stubbed;
        }

        /// 5: the player's ped. Moves the player's existing ped there, or
        /// makes one for slot 0.
        fn playerPed(self: *Self, ctx: anytype, cmd: Cmd) void {
            const p = W.params(cmd);
            const pos = H.place(self, p.pos(4), prelude.T.ped_step);
            const deg: i32 = p.u16_(16);
            const remap = p.u16_(18);
            const w = &self.state.world;
            var id = ctx.player(0);
            if (w.get(id, c.Transform)) |t| {
                t.* = .{ .x = pos.x, .y = pos.y, .z = pos.z, .heading = W.heading(deg) };
                if (w.get(id, c.Appearance)) |a| a.remap = remap;
            } else {
                id = H.spawnPedAt(self, pos, deg, remap, 0) orelse return;
                self.state.players[0].ped = id;
            }
            Self.objectives.setOccupation(self, id, .player);
            H.tag(self, id, cmd.num, c.ScriptTag.flag_keep);
            ctx.setHandle(cmd.num, id);
        }

        /// 29-32: a generator object (B runs it). Its delays and ammo wait
        /// on B's generator API.
        fn generator(self: *Self, ctx: anytype, cmd: Cmd) void {
            const p = W.params(cmd);
            const pos = H.place(self, p.pos(4), prelude.T.ped_step);
            if (Self.objects.spawnObject(self, .generator, @truncate(p.u16_(18)), pos.x, pos.y, pos.z, W.heading(p.u16_(16)))) |id| {
                H.tag(self, id, cmd.num, c.ScriptTag.flag_keep);
                ctx.setHandle(cmd.num, id);
            }
        }

        fn area(self: *Self, ctx: anytype, cmd: Cmd, kind: ids.ObjectKind) void {
            const p = W.params(cmd);
            const pos = H.place(self, p.pos(4), prelude.T.ped_step);
            if (Self.objects.spawnObject(self, kind, 0, pos.x, pos.y, pos.z, 0)) |id| {
                H.tag(self, id, cmd.num, c.ScriptTag.flag_keep);
                ctx.setHandle(cmd.num, id);
            }
        }
    };
}
