//! Ped AI movement helpers (D1): what an objective handler writes into a
//! ped's controls. Handlers never move a ped themselves; they set its
//! `Controller.in` (direct mode: an aim heading and a throttle) and the
//! on-foot control system (`sys/ped_control.zig`) does the rest, exactly as
//! for a player. A ped whose controls were written this tick is marked
//! `flag_steered`, so the ambient wanderer leaves it alone.

const std = @import("std");
const prelude = @import("../prelude.zig");
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const Button = prelude.Button;
const A = @import("../tuning/ped_ai.zig");

/// One AI ped's components, fetched once per tick.
pub const P = struct {
    id: EntityId,
    o: *c.Objective,
    ctl: *c.Controller,
    t: *c.Transform,
    vel: *c.Velocity,
    ped: *c.Pedestrian,
    wpn: *c.Weapon,
    ride: *c.Riding,
    h: *c.Health,
};

pub fn Sys(comptime Self: type) type {
    return struct {
        pub fn ref(self: *Self, id: EntityId) ?P {
            if (comptime !Self.Ped.has(c.Objective)) return null;
            const w = &self.state.world;
            return .{
                .id = id,
                .o = w.get(id, c.Objective) orelse return null,
                .ctl = w.get(id, c.Controller) orelse return null,
                .t = w.get(id, c.Transform) orelse return null,
                .vel = w.get(id, c.Velocity) orelse return null,
                .ped = w.get(id, c.Pedestrian) orelse return null,
                .wpn = w.get(id, c.Weapon) orelse return null,
                .ride = w.get(id, c.Riding) orelse return null,
                .h = w.get(id, c.Health) orelse return null,
            };
        }

        pub fn bearing(t: *const c.Transform, x: Fx, y: Fx) u16 {
            return fx.atan2(y - t.y, x - t.x);
        }

        pub fn angleDiff(a: u16, b: u16) u16 {
            const d: i16 = @bitCast(a -% b);
            return @abs(d);
        }

        fn write(p: P, aim: u16, throttle: i8, buttons: u16) void {
            p.ctl.in = .{ .steer = 0, .throttle = throttle, .buttons = Button.direct | buttons, .aim = aim, .seq = 0 };
            p.o.flags |= c.Objective.flag_steered;
        }

        /// Stand still facing `aim`, optionally holding fire.
        pub fn stand(p: P, aim: u16, fire: bool) void {
            write(p, aim, 0, if (fire) Button.fire else 0);
        }

        /// Stand still where it is.
        pub fn halt(p: P) void {
            stand(p, p.t.heading, false);
        }

        /// The heading to walk toward `heading` from where the ped stands:
        /// straight on if the way is clear, else the first clear detour.
        pub fn clearHeading(self: *Self, p: P, heading: u16) u16 {
            if (!blockedAlong(self, p, heading)) return heading;
            for (A.detours) |d| {
                const h = heading +% @as(u16, @truncate(@as(u32, @bitCast(d))));
                if (!blockedAlong(self, p, h)) return h;
            }
            return heading;
        }

        fn blockedAlong(self: *Self, p: P, heading: u16) bool {
            const ax = p.t.x + fx.mul(fx.cos(heading), A.probe);
            const ay = p.t.y + fx.mul(fx.sin(heading), A.probe);
            if (self.pedBlocked(p.t.x, p.t.y, ax, ay, p.t.z)) return true;
            // A drop of more than a step, or deep water, counts as blocked.
            if (map.floorAt(self.grid, ax, ay, p.t.z, prelude.T.ped_step) < p.t.z - prelude.T.snap_down) return true;
            return map.waterAt(self.grid, ax, ay, p.t.z);
        }

        /// Walk (or run) toward (x, y) at `throttle`.
        pub fn goToward(self: *Self, p: P, x: Fx, y: Fx, throttle: i8, run: bool) void {
            const h = clearHeading(self, p, bearing(p.t, x, y));
            write(p, h, throttle, if (run) Button.run else 0);
        }

        /// Run directly away from (x, y).
        pub fn runFrom(self: *Self, p: P, x: Fx, y: Fx) void {
            const away = bearing(p.t, x, y) +% 32768;
            write(p, clearHeading(self, p, away), 127, Button.run);
        }

        /// Close on (x, y) as a chaser (ped-ai.md 3.7): stop within 1/8
        /// block unless mid-jump, otherwise slow down in three steps over
        /// the last half block.
        pub fn chase(self: *Self, p: P, x: Fx, y: Fx, dist: Fx) void {
            if (dist <= A.chase_stop and p.ped.jump == 0) return stand(p, bearing(p.t, x, y), false);
            const tier: usize = if (dist > A.chase_tier1) 0 else if (dist > A.chase_tier2) 1 else if (dist > A.chase_tier3) 2 else 3;
            goToward(self, p, x, y, A.chase_throttle[tier], tier == 0);
        }

        /// Hold fire and face (x, y) with an aim offset.
        pub fn aimAt(p: P, x: Fx, y: Fx, offset: u16, fire: bool) void {
            stand(p, bearing(p.t, x, y) +% offset, fire);
        }
    };
}
