//! Car crushers (crushers-and-garages.md 3.1-3.2). Owner: workstream B.
//! A crusher is one map object at the centre; the four pistons are drawn
//! from its state (`crusherPistons`). Per tick while active: the east and
//! west pistons close 1/64 block from 0.9375 to 0.5625, shrinking the car's
//! width 2 px a tick once the gap minus 0.4375 is no more than half its
//! width; fully closed, the car explodes; they open again; the north and
//! south pistons do the same to its length and mark it crushed; they open
//! and the crusher is idle, leaving a crushed wreck.
//!
//! `Object` fields on a crusher: `state` the phase, `timer` the moving
//! pair's distance from the centre in px (1/64 block, 60 open, 36 closed),
//! `aux` the width shrink (low byte) and length shrink (high byte) in px,
//! `owner` the car. A car being crushed ignores collisions and is kept from
//! despawning; crushing is not a crime (`beingCrushed`, for workstream E).
//!
//! Ours: "touching the centre marker" (`crusher_reach`), and the smallest
//! size a crushed sprite keeps. The crushed wreck then ages like any wreck
//! (the note leaves when it despawns open).

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const OT = @import("../tuning/objects.zig");

pub const Phase = enum(u8) { idle = 0, squeeze_sides = 1, open_sides = 2, squeeze_ends = 3, open_ends = 4, _ };

/// Piston distances in px (1/64 block).
const open_px: u16 = @intCast(OT.piston_open >> (fx.frac_bits - 6));
const closed_px: u16 = @intCast(OT.piston_closed >> (fx.frac_bits - 6));
const face_px: i32 = OT.piston_face >> (fx.frac_bits - 6);
comptime {
    if (open_px != 60 or closed_px != 36 or face_px != 28) @compileError("piston px");
    if (OT.piston_speed != fx.one >> 6) @compileError("pistons move one px a tick");
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.single_player;
        const objects = Self.objects;

        /// Type 40: a crusher centred at (x, y) on the floor at `z` (or the
        /// ground with `objects.ground_z`).
        pub fn addCrusher(self: *Self, x: Fx, y: Fx, z: Fx) ?EntityId {
            if (comptime !sp) return null;
            const id = objects.spawnObject(self, .crusher, 0, x, y, z, 0) orelse return null;
            const o = self.state.world.get(id, c.Object).?;
            o.timer = open_px;
            o.owner = .none;
            return id;
        }

        /// Start the crusher's cycle on the car on it, if it is idle and
        /// there is one (it also starts by itself each tick).
        pub fn runCrusher(self: *Self, crusher: EntityId) void {
            if (comptime !sp) return;
            const o = crusherOf(self, crusher) orelse return;
            const t = self.state.world.get(crusher, c.Transform) orelse return;
            tryStart(self, o, t);
        }

        /// Is `car` in a crusher's grip? Cars destroyed while being crushed
        /// are not reported as crimes (wanted-level.md).
        pub fn beingCrushed(self: *Self, car: EntityId) bool {
            if (comptime !sp) return false;
            const Ctx = struct { car: EntityId, hit: bool = false };
            var ctx = Ctx{ .car = car };
            self.state.world.each(.{c.Object}, &ctx, struct {
                fn f(cx: *Ctx, _: EntityId, o: *c.Object) void {
                    if (objects.kindOf(o) == .crusher and o.state != @intFromEnum(Phase.idle) and eql(o.owner, cx.car)) cx.hit = true;
                }
            }.f);
            return ctx.hit;
        }

        /// What the client draws: the phase, the side and end piston
        /// distances from the centre (fixed point), and the car's width
        /// and length shrink in px.
        pub fn crusherPistons(self: *Self, crusher: EntityId) ?struct { phase: Phase, sides: Fx, ends: Fx, shrink_w: u8, shrink_l: u8, car: EntityId } {
            if (comptime !sp) return null;
            const o = crusherOf(self, crusher) orelse return null;
            const phase: Phase = @enumFromInt(o.state);
            const moving = @as(Fx, o.timer) << (fx.frac_bits - 6);
            const sides_move = phase == .squeeze_sides or phase == .open_sides;
            return .{
                .phase = phase,
                .sides = if (sides_move) moving else OT.piston_open,
                .ends = if (sides_move or phase == .idle) OT.piston_open else moving,
                .shrink_w = @truncate(o.aux),
                .shrink_l = @truncate(o.aux >> 8),
                .car = o.owner,
            };
        }

        pub fn sysCrushers(self: *Self) void {
            if (comptime !sp) return;
            self.state.world.each(.{ c.Object, c.Transform }, self, struct {
                fn f(sim: *Self, _: EntityId, o: *c.Object, t: *c.Transform) void {
                    if (objects.kindOf(o) != .crusher) return;
                    if (o.state == @intFromEnum(Phase.idle)) return tryStart(sim, o, t);
                    step(sim, o);
                }
            }.f);
        }

        // ------------------------------------------------------------------

        fn crusherOf(self: *Self, id: EntityId) ?*c.Object {
            const o = objects.objectOf(self, id) orelse return null;
            return if (objects.kindOf(o) == .crusher) o else null;
        }

        fn tryStart(self: *Self, o: *c.Object, t: *const c.Transform) void {
            if (o.state != @intFromEnum(Phase.idle)) return;
            const Ctx = struct { sim: *Self, t: c.Transform, hit: EntityId = .none };
            var ctx = Ctx{ .sim = self, .t = t.* };
            self.state.world.each(.{ c.Vehicle, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, v: *c.Vehicle, ct: *c.Transform) void {
                    if (!cx.hit.isNone()) return;
                    if (v.flags & c.Vehicle.flag_crushed != 0) return;
                    // A wreck about to be cleared is "already despawning".
                    if (v.flags & c.Vehicle.flag_wrecked != 0 and v.timer == 0) return;
                    if (fx.abs(ct.z - cx.t.z) > fx.half) return;
                    if (fx.abs(ct.x - cx.t.x) > OT.crusher_reach or fx.abs(ct.y - cx.t.y) > OT.crusher_reach) return;
                    if (beingCrushed(cx.sim, id)) return;
                    cx.hit = id;
                }
            }.f);
            if (ctx.hit.isNone()) return;
            const w = &self.state.world;
            o.owner = ctx.hit;
            o.state = @intFromEnum(Phase.squeeze_sides);
            o.timer = open_px;
            o.aux = 0;
            if (w.get(ctx.hit, c.Collider)) |col| col.flags |= c.Collider.flag_disabled;
            if (w.get(ctx.hit, c.Velocity)) |vel| vel.* = std.mem.zeroes(c.Velocity);
        }

        fn step(self: *Self, o: *c.Object) void {
            const w = &self.state.world;
            const v = w.get(o.owner, c.Vehicle) orelse {
                // The car went (removed by a script): back to idle.
                o.state = @intFromEnum(Phase.idle);
                o.timer = open_px;
                o.owner = .none;
                return;
            };
            // A wreck in the crusher is kept from despawning.
            if (v.flags & c.Vehicle.flag_wrecked != 0 and v.timer < 2) v.timer = 2;
            if (w.get(o.owner, c.Velocity)) |vel| vel.* = std.mem.zeroes(c.Velocity);
            const m = T.carModel(v.model);
            var shrink_w: u8 = @truncate(o.aux);
            var shrink_l: u8 = @truncate(o.aux >> 8);
            switch (@as(Phase, @enumFromInt(o.state))) {
                .squeeze_sides => {
                    o.timer -= 1;
                    shrink_w = shrink(shrink_w, o.timer, m.half_wid);
                    if (o.timer == closed_px) {
                        // Explodes as a car explosion, credited to whoever
                        // last hit it (sysHealth wrecks it this tick).
                        if (v.flags & c.Vehicle.flag_wrecked == 0) {
                            if (w.get(o.owner, c.Health)) |h| h.hp = 0;
                        }
                        o.state = @intFromEnum(Phase.open_sides);
                    }
                },
                .open_sides => {
                    o.timer += 1;
                    if (o.timer == open_px) o.state = @intFromEnum(Phase.squeeze_ends);
                },
                .squeeze_ends => {
                    o.timer -= 1;
                    shrink_l = shrink(shrink_l, o.timer, m.half_len);
                    if (o.timer == closed_px) {
                        v.flags |= c.Vehicle.flag_crushed;
                        o.state = @intFromEnum(Phase.open_ends);
                    }
                },
                .open_ends => {
                    o.timer += 1;
                    if (o.timer == open_px) {
                        if (w.get(o.owner, c.Collider)) |col| col.flags &= ~c.Collider.flag_disabled;
                        o.state = @intFromEnum(Phase.idle);
                        o.owner = .none;
                    }
                },
                else => {},
            }
            o.aux = @as(u16, shrink_w) | (@as(u16, shrink_l) << 8);
        }

        /// 2 px more shrink once the piston gap minus the face offset is no
        /// more than half the (shrunk) size, down to `crush_min_px`.
        fn shrink(cur: u8, gap_px: u16, half: Fx) u8 {
            const full_px: i32 = (half >> (fx.frac_bits - 6)) * 2;
            const size = full_px - cur;
            if (@as(i32, gap_px) - face_px > @divTrunc(size, 2)) return cur;
            if (size - OT.crush_shrink_px < OT.crush_min_px) return cur;
            return cur + OT.crush_shrink_px;
        }
    };
}
