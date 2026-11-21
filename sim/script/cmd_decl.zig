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
//!   26, 27   u32, position (the area's centre) @4, width @16, height
//!            @20, push: one signed byte each for x and y @24 @25
//!   29-32    u32, position @4, rotation @16, model @18, min and max
//!            delay @20 @22, ammo @24
//!   34, 35   u32, position (the area's centre) @4, width @16, height @20
//!   375-379  block x y z bytes @4-@6, face byte @7 (1-4), animation @8,
//!            open rule @9, close rule @10, delay @11, check area centre
//!            @12 @16 (height @20), size @24 @28, flip byte @32,
//!            reversed byte @33; 376/379 add the target @36 (guessed)
//!   40       u32, x @4, y @8 (no height)
//!   211, 213 u16 thread start @6, character @8, car or phone @10
//!   212, 214, 434  thread start @6, x y z @8, width @20, height @24,
//!            character @28
//!   230      start frame @0, end frame @2, speed @4
//!   240, 429-431  u16 unused @0, counter @2
//!   304      u16 unused, stars @2
//!   343      i32 @0;  344, 345, 386-388  count @2
//!   346-349, 389, 390  counter @0;  353  19 model bytes @0
//!   102      zone named by its own string key; u16 car density @0, ordinary,
//!            bad, police car ratios @2-@6, ped density @8, mugger, thief,
//!            Elvis, gang ratios @10-@16, police peds @18, gang cars @20
//!            (the order is ours: the levels' values fit it)
//!   223      gang name key @0 (the rest waits on D2)
//!   6, 9, 14 empty car, character and object variables (no parameters
//!            used; the data shows them all zero)
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

/// One unit of a conveyor's push, blocks per tick (ours).
pub const conveyor_unit: Fx = fx.one >> 6;

pub const done = [_]u16{ 102, 211, 212, 213, 214, 434, 29, 30, 31, 32, 26, 27, 34, 35, 375, 376, 378, 379, 5, 7, 8, 10, 11, 12, 13, 425, 426, 427, 428, 15, 16, 17, 18, 19, 20, 6, 9, 14, 40, 230, 240, 429, 430, 431, 304, 343, 344, 345, 386, 387, 388, 346, 347, 348, 349, 389, 390, 353, 422, 435, 436, 437 };
/// Decoded, waiting on another workstream's API: zone densities (F),
/// cranes (cranes note), conveyors, generators, destructors and doors
/// (B), triggers (A1), gang info (D2), lights (B), trains and radio,
/// sound points (audio), the crane power-up link.
pub const stubbed = [_]u16{ 37, 38, 39, 223, 217, 302, 285, 286, 295, 296, 297, 298, 287, 327, 439 };

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
                // Empty car (6), character (9) and object (14) variables:
                // no note covers them; every use in the levels has all-zero
                // parameters and a later creation fills the slot (ours).
                6, 9, 14 => ctx.setHandle(cmd.num, .none),
                40 => {
                    const pos = H.place(self, .{ .x = p.fx_(4), .y = p.fx_(8), .z = 0, .ground = true }, prelude.T.car_step);
                    if (Self.objects.addCrusher(self, pos.x, pos.y, pos.z)) |id| {
                        H.tag(self, id, cmd.num, c.ScriptTag.flag_keep);
                        ctx.setHandle(cmd.num, id);
                    }
                },
                230 => if (s.door_anim_count < W.State.max_door_anims) {
                    s.door_anims[s.door_anim_count] = .{ .start = p.u16_(0), .end = p.u16_(2), .speed = p.u16_(4) };
                    s.door_anim_count += 1;
                    // B's list keeps frames as bytes; the levels use frame
                    // numbers up to 976 (asked B to widen).
                    _ = Self.objects.addDoorAnim(self, @truncate(p.u16_(0)), @truncate(p.u16_(2)), @truncate(p.u16_(4)));
                },
                240, 429, 430, 431 => {
                    const which: u2 = if (cmd.kind == 240) 0 else @intCast(cmd.kind - 428);
                    s.mission_flags[which] = p.u16_(2);
                    ctx.setMissionFlag(which, p.u16_(2));
                },
                435, 436, 437 => {
                    s.fail_base[cmd.kind - 435] = @truncate(p.u32_(4));
                    ctx.setFailBase(@intCast(cmd.kind - 435), @truncate(p.u32_(4)));
                },
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
                    Self.objects.setCarList(self, s.car_list[0..n]);
                },
                422 => if (s.keyframe_count < W.State.max_keyframes) {
                    s.keyframes[s.keyframe_count] = p.u16_(0);
                    s.keyframe_count += 1;
                },
                29, 30, 31, 32 => generator(self, ctx, cmd),
                26, 27, 34, 35 => area(self, ctx, cmd),
                375, 376, 378, 379 => door(self, ctx, cmd),
                211, 213 => {
                    const t: Trigger = .{ .kind = if (cmd.kind == 211) .car else .phone, .thread = p.u16_(6), .character = ctx.handle(p.u16_(8)), .target = ctx.handle(p.u16_(10)) };
                    // Both must exist (2.10).
                    if (!H.alive(self, t.character) or !H.alive(self, t.target)) return .done;
                    if (cmd.kind == 213) Self.objects.markPhoneSpokenFor(self, t.target);
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
                // 223: gangs are numbered in declaration order; the rest of
                // the gang info (remap, weapons, car) waits on D2.
                223 => {
                    if (s.gang_count < ids.max_gangs) {
                        ctx.registerGang(s.gang_count, p.u16_(0));
                        s.gang_count += 1;
                    }
                    return .stubbed;
                },
                102 => {
                    if (comptime !@hasDecl(Self.spawn, "setZoneDensity")) return .stubbed;
                    // The zone is named by this command's own string key;
                    // 11 u16: car density, ordinary, bad, police car
                    // ratios, ped density, mugger, car thief, Elvis, gang
                    // member, police ped (no slot in F's mix), gang car.
                    _ = Self.spawn.setZoneDensity(self, ctx.string(cmd.num), .{
                        .car_density = p.u16_(0),
                        .car_ratio = .{ p.u16_(2), p.u16_(4), p.u16_(6), p.u16_(20) },
                        .ped_density = p.u16_(8),
                        .ped_ratio = .{ p.u16_(10), p.u16_(12), p.u16_(14), p.u16_(16) },
                    });
                },
                37, 38, 39, 217, 302, 285, 286, 295, 296, 297, 298, 287, 327, 439 => return .stubbed,
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

        /// 29-32: a generator (B runs it).
        fn generator(self: *Self, ctx: anytype, cmd: Cmd) void {
            const p = W.params(cmd);
            const q = p.pos(4);
            const id = Self.objects.addGenerator(self, .{
                .x = q.x,
                .y = q.y,
                .z = if (q.ground) Self.objects.ground_z else q.z,
                .heading = W.heading(p.u16_(16)),
                .model = @truncate(p.u16_(18)),
                .min_delay = p.u16_(20),
                .max_delay = p.u16_(22),
                .ammo = p.u16_(24),
            }) orelse return;
            H.tag(self, id, cmd.num, c.ScriptTag.flag_keep);
            ctx.setHandle(cmd.num, id);
        }

        /// 26/27 conveyors and 34/35 destructors: the script gives the
        /// area's centre and size; conveyors add a push of one signed byte
        /// per axis (ours: 1/64 block a tick per unit).
        fn area(self: *Self, ctx: anytype, cmd: Cmd) void {
            const p = W.params(cmd);
            const q = p.pos(4);
            const w = p.fx_(16);
            const h = p.fx_(20);
            const conveyor = cmd.kind < 30;
            const vx: Fx = if (conveyor) @as(Fx, @as(i8, @bitCast(p.u8_(24)))) * conveyor_unit else 0;
            const vy: Fx = if (conveyor) @as(Fx, @as(i8, @bitCast(p.u8_(25)))) * conveyor_unit else 0;
            const id = Self.objects.addArea(self, if (conveyor) .conveyor else .destructor, q.x - (w >> 1), q.y - (h >> 1), if (q.ground) Self.objects.ground_z else q.z, w, h, vx, vy) orelse return;
            H.tag(self, id, cmd.num, c.ScriptTag.flag_keep);
            ctx.setHandle(cmd.num, id);
        }

        /// 375/376 single and 378/379 double doors. Only 376/379 resolve
        /// the car or character their open rule names (5).
        fn door(self: *Self, ctx: anytype, cmd: Cmd) void {
            const p = W.params(cmd);
            const raw_face = p.u8_(7);
            const w = p.fx_(24);
            const h = p.fx_(28);
            const resolves = cmd.kind == 376 or cmd.kind == 379;
            const flags = p.u32_(32);
            const id = Self.objects.addDoor(self, .{
                .bx = p.u8_(4),
                .by = p.u8_(5),
                .bz = p.u8_(6),
                .face = @fromBackingInt(@intCast(if (raw_face > 0) raw_face - 1 else 0)),
                .anim = p.u8_(8),
                .open_rule = @fromBackingInt(@intCast(p.u8_(9))),
                .close_rule = @fromBackingInt(@intCast(p.u8_(10))),
                .delay = p.u8_(11),
                .area_x = p.fx_(12) - (w >> 1),
                .area_y = p.fx_(16) - (h >> 1),
                .area_w = w,
                .area_h = h,
                .flip = flags & 0xFF != 0,
                .reversed = flags & 0xFF00 != 0,
                .double = cmd.kind >= 378,
                .target = if (resolves) ctx.handle(p.u16_(36)) else .none,
            }) orelse return;
            H.tag(self, id, cmd.num, c.ScriptTag.flag_keep);
            ctx.setHandle(cmd.num, id);
        }
    };
}
