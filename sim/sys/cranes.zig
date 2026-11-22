//! Cranes (crushers-and-garages.md 3.4's outline, script-declarations.md
//! 2.7, docs/research/public-sources.md 6). A level script declares each
//! crane (types 37-39) at its base, with a home rotation and up to two drop
//! targets, and optionally a link to an earlier "home" crane. The crane's
//! state is in `state.sp.vehicles.cranes`; its hook is a map object of kind
//! `crane` that stands at the hook, so scripts hold an ordinary handle and
//! the hook's position replicates.
//!
//! What a crane does is ours, from the outline and the public notes:
//!
//! - A crane with no home crane is a pick-up crane: a car that has sat
//!   still in its reach (a square 4 blocks out from the base, from play),
//!   not driven by traffic, is grabbed, lifted, swung to the first target
//!   (or the second, if that is the only one) and set down there, usually
//!   on a crusher. Anyone inside rides along and cannot get out.
//! - A crane linked to a home crane picks up the crushed wreck at the home
//!   crane's first target and drops it at its own target (onto a
//!   conveyor). If the script gave it a power-up (439), the generator
//!   then decides a reward by the wreck's model (the car list, 223).
//! - A crane with no targets at all (type 39; for transporters, which are
//!   not built) stays at home.
//!
//! The hook moves on three axes, the jib's swing, the trolley along the
//! jib and the lift, each easing toward its target at a capped speed and
//! stopping exactly (the camera's rule, camera.md 3.4, as the outline
//! says). All speeds and timings are ours (`tuning/vehicles.zig`).

const std = @import("std");
const prelude = @import("../prelude.zig");
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const TV = @import("../tuning/vehicles.zig");

/// One crane. No implicit padding: the state is hashed byte for byte.
pub const Crane = extern struct {
    /// The hook (a `crane` map object), none for an unused slot.
    hook: EntityId = .none,
    /// The car on the hook, or none.
    car: EntityId = .none,
    /// The car it is going for, or waiting on.
    want: EntityId = .none,
    /// The power-up generator (439), or none.
    gen: EntityId = .none,
    /// Base, and its floor height.
    bx: Fx = 0,
    by: Fx = 0,
    bz: Fx = 0,
    /// The trolley's distance out along the jib, and its speed.
    radius: Fx = 0,
    trolley: Fx = 0,
    /// The hook's height above the base floor, and its speed.
    lift: Fx = 0,
    lift_v: Fx = 0,
    /// Drop targets (slot 0 first, slot 1 second): position and the
    /// heading the car is set down at.
    tx: [2]Fx = .{ 0, 0 },
    ty: [2]Fx = .{ 0, 0 },
    theading: [2]u16 = .{ 0, 0 },
    /// The jib's angle and swing speed (angle units), home angle.
    angle: u16 = 0,
    home: u16 = 0,
    swing: i16 = 0,
    /// Ticks in the phase (waiting, gripping, resting).
    timer: u16 = 0,
    /// `Phase`.
    phase: u8 = 0,
    /// Bit 0: slot 0 set; bit 1: slot 1 set.
    targets: u8 = 0,
    /// Index + 1 of the home crane, 0 for none.
    link: u8 = 0,
    /// 1 for a declared crane (the state starts zeroed, so the ids above
    /// mean nothing in an unused slot).
    used: u8 = 0,
};

pub const Phase = enum(u8) { idle = 0, reach = 1, lower = 2, grab = 3, raise = 4, carry = 5, set_down = 6, release = 7, home = 8, _ };

pub const State = extern struct {
    cranes: [TV.max_cranes]Crane = @splat(.{}),
};

pub fn Sys(comptime Self: type) type {
    return struct {
        const Me = @This();
        const sp = Self.city;

        fn st(self: *Self) *State {
            return &self.state.sp.vehicles;
        }

        /// Index of the crane whose hook is `hook`.
        fn indexOf(self: *Self, hook: EntityId) ?usize {
            if (comptime !sp) return null;
            if (hook.isNone()) return null;
            for (&st(self).cranes, 0..) |*cr, i| {
                if (cr.used != 0 and eql(cr.hook, hook)) return i;
            }
            return null;
        }

        /// Declare a crane at base (x, y) with home heading `home`; `link`
        /// is the home crane's hook or none. Returns the hook's handle.
        pub fn addCrane(self: *Self, x: Fx, y: Fx, home: u16, link: EntityId) ?EntityId {
            if (comptime !sp) return null;
            const s = st(self);
            const slot = for (&s.cranes, 0..) |*cr, i| {
                if (cr.used == 0) break i;
            } else return null;
            const bz = groundAt(self, x, y);
            const hx = x + fx.mul(fx.cos(home), TV.home_radius);
            const hy = y + fx.mul(fx.sin(home), TV.home_radius);
            const hook = Self.objects.spawnObject(self, .crane, 0, hx, hy, bz + TV.carry_height, home) orelse return null;
            s.cranes[slot] = .{ .hook = hook, .bx = x, .by = y, .bz = bz, .radius = TV.home_radius, .lift = TV.carry_height, .angle = home, .home = home, .used = 1 };
            if (indexOf(self, link)) |li| s.cranes[slot].link = @intCast(li + 1);
            return hook;
        }

        /// Set drop target `which` (0 first, 1 second) of the crane `hook`.
        pub fn setTarget(self: *Self, hook: EntityId, which: u1, x: Fx, y: Fx, heading: u16) void {
            const i = indexOf(self, hook) orelse return;
            const cr = &st(self).cranes[i];
            cr.tx[which] = x;
            cr.ty[which] = y;
            cr.theading[which] = heading;
            cr.targets |= @as(u8, 1) << which;
        }

        /// The crane's power-up generator (439).
        pub fn setPowerUp(self: *Self, hook: EntityId, gen: EntityId) void {
            const i = indexOf(self, hook) orelse return;
            st(self).cranes[i].gen = gen;
        }

        /// The car on crane `hook`'s hook, or none (188).
        pub fn carOn(self: *Self, hook: EntityId) EntityId {
            const i = indexOf(self, hook) orelse return .none;
            const cr = &st(self).cranes[i];
            if (Me.isPhase(cr, .raise) or Me.isPhase(cr, .carry) or Me.isPhase(cr, .set_down)) return cr.car;
            return .none;
        }

        /// Is `car` held by a crane?
        pub fn lifted(self: *Self, car: EntityId) bool {
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            return v.xflags & c.Vehicle.xf_lifted != 0;
        }

        fn isPhase(cr: *const Crane, p: Phase) bool {
            return cr.phase == @intFromEnum(p);
        }

        fn groundAt(self: *Self, x: Fx, y: Fx) Fx {
            const f = map.floorAt(self.grid, x, y, fx.fromInt(map.size_z - 1), T.car_step);
            return if (f < 0) 0 else f;
        }

        /// The slot this crane drops at: the first target, else the second.
        fn dropSlot(cr: *const Crane) ?u1 {
            if (cr.targets & 1 != 0) return 0;
            if (cr.targets & 2 != 0) return 1;
            return null;
        }

        pub fn sysCranes(self: *Self) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            for (&st(self).cranes) |*cr| {
                if (cr.used == 0) continue;
                // (A hook declared this tick is still spawning: `get`
                // finds it, `isAlive` does not.)
                if (self.state.world.get(cr.hook, c.Transform) == null) {
                    Me.letGo(self, cr);
                    cr.* = .{};
                    continue;
                }
                Me.stepCrane(self, cr);
            }
        }

        fn stepCrane(self: *Self, cr: *Crane) void {
            const w = &self.state.world;
            const slot = dropSlot(cr) orelse return Me.place(self, cr);
            switch (@as(Phase, @enumFromInt(cr.phase))) {
                .idle => {
                    const cand = Me.candidate(self, cr);
                    if (cand.isNone() or !eql(cand, cr.want)) {
                        cr.want = cand;
                        cr.timer = 0;
                    }
                    // Waits on the candidate until it has been still long
                    // enough (a wreck from the crusher goes at once).
                    if (!cand.isNone() and Me.stillFor(cr)) cr.phase = @intFromEnum(Phase.reach);
                },
                .reach => {
                    Me.holdWreck(self, cr.want);
                    const t = (w.get(cr.want, c.Transform) orelse return Me.giveUp(cr)).*;
                    if (!Me.stillOk(self, cr.want)) return Me.giveUp(cr);
                    if (Me.moveTo(cr, t.x, t.y, TV.carry_height)) cr.phase = @intFromEnum(Phase.lower);
                },
                .lower => {
                    Me.holdWreck(self, cr.want);
                    const t = (w.get(cr.want, c.Transform) orelse return Me.giveUp(cr)).*;
                    if (!Me.stillOk(self, cr.want)) return Me.giveUp(cr);
                    if (Me.moveTo(cr, t.x, t.y, t.z - cr.bz)) {
                        cr.phase = @intFromEnum(Phase.grab);
                        cr.timer = TV.grip_ticks;
                    }
                },
                .grab => {
                    Me.holdWreck(self, cr.want);
                    if (!w.isAlive(cr.want)) return Me.giveUp(cr);
                    if (cr.timer > 0) {
                        cr.timer -= 1;
                    } else {
                        Me.pickUp(self, cr);
                        cr.phase = @intFromEnum(Phase.raise);
                    }
                },
                .raise => {
                    if (!w.isAlive(cr.car)) return Me.lost(cr);
                    if (Me.moveTo(cr, Me.hookX(cr), Me.hookY(cr), TV.carry_height)) cr.phase = @intFromEnum(Phase.carry);
                },
                .carry => {
                    if (!w.isAlive(cr.car)) return Me.lost(cr);
                    if (Me.moveTo(cr, cr.tx[slot], cr.ty[slot], TV.carry_height)) cr.phase = @intFromEnum(Phase.set_down);
                },
                .set_down => {
                    if (!w.isAlive(cr.car)) return Me.lost(cr);
                    const floor = groundAt(self, cr.tx[slot], cr.ty[slot]);
                    if (Me.moveTo(cr, cr.tx[slot], cr.ty[slot], floor - cr.bz)) {
                        cr.phase = @intFromEnum(Phase.release);
                        cr.timer = TV.grip_ticks;
                    }
                },
                .release => {
                    if (cr.timer > 0) {
                        cr.timer -= 1;
                    } else {
                        Me.drop(self, cr, slot);
                        cr.phase = @intFromEnum(Phase.home);
                        cr.timer = 0;
                    }
                },
                .home => {
                    const hx = cr.bx + fx.mul(fx.cos(cr.home), TV.home_radius);
                    const hy = cr.by + fx.mul(fx.sin(cr.home), TV.home_radius);
                    cr.want = .none;
                    if (Me.moveTo(cr, hx, hy, TV.carry_height)) {
                        // Rests at home a while before looking again.
                        if (cr.timer < TV.rest_ticks) {
                            cr.timer += 1;
                        } else {
                            cr.phase = @intFromEnum(Phase.idle);
                            cr.timer = 0;
                        }
                    }
                },
                _ => cr.phase = @intFromEnum(Phase.home),
            }
            Me.place(self, cr);
        }

        /// A wreck a crane is going for is not cleared away meanwhile.
        fn holdWreck(self: *Self, car: EntityId) void {
            const v = self.state.world.get(car, c.Vehicle) orelse return;
            if (v.flags & c.Vehicle.flag_wrecked != 0 and v.timer < TV.hold_wreck) v.timer = TV.hold_wreck;
        }

        fn giveUp(cr: *Crane) void {
            cr.want = .none;
            cr.timer = 0;
            cr.phase = @intFromEnum(Phase.home);
        }

        /// The car went while on the hook (removed by a script).
        fn lost(cr: *Crane) void {
            cr.car = .none;
            giveUp(cr);
        }

        fn hookX(cr: *const Crane) Fx {
            return cr.bx + fx.mul(fx.cos(cr.angle), cr.radius);
        }
        fn hookY(cr: *const Crane) Fx {
            return cr.by + fx.mul(fx.sin(cr.angle), cr.radius);
        }

        /// One tick of the hook toward (x, y) at height `h` above the base
        /// floor. True once all three axes are there.
        fn moveTo(cr: *Crane, x: Fx, y: Fx, h: Fx) bool {
            const dx = x - cr.bx;
            const dy = y - cr.by;
            const r = @min(fx.length(dx, dy), TV.reach * 3 / 2);
            const a = if (dx == 0 and dy == 0) cr.angle else fx.atan2(dy, dx);
            // Swing.
            const da: i32 = @as(i16, @bitCast(a -% cr.angle));
            var sw: i32 = cr.swing;
            sw = ease(sw, da, TV.swing_max, TV.swing_accel);
            cr.swing = @intCast(sw);
            cr.angle +%= @as(u16, @bitCast(@as(i16, @intCast(sw))));
            // Trolley and lift.
            var tv: i32 = cr.trolley;
            tv = ease(tv, r - cr.radius, TV.trolley_max, TV.trolley_accel);
            cr.trolley = tv;
            cr.radius += tv;
            var lv: i32 = cr.lift_v;
            lv = ease(lv, h - cr.lift, TV.lift_max, TV.lift_accel);
            cr.lift_v = lv;
            cr.lift += lv;
            return cr.angle == a and cr.radius == r and cr.lift == h;
        }

        /// Speed toward a remaining distance `d`: up by `accel` a tick to
        /// `max`, never past what is left, so the axis stops exactly.
        fn ease(v: i32, d: i32, max: i32, accel: i32) i32 {
            if (d == 0) return 0;
            const want = std.math.clamp(d, -max, max);
            var nv = v;
            if (nv < want) nv = @min(nv + accel, want) else if (nv > want) nv = @max(nv - accel, want);
            // Never overshoot, and never move away from the target.
            if (d > 0) nv = std.math.clamp(nv, 1, d) else nv = std.math.clamp(nv, d, -1);
            return nv;
        }

        /// The hook object, and the car on it, at the hook.
        fn place(self: *Self, cr: *Crane) void {
            const w = &self.state.world;
            const x = hookX(cr);
            const y = hookY(cr);
            const z = cr.bz + cr.lift;
            if (w.get(cr.hook, c.Transform)) |t| t.* = .{ .x = x, .y = y, .z = z, .heading = cr.angle };
            if (cr.car.isNone()) return;
            const ct = w.get(cr.car, c.Transform) orelse return;
            ct.x = x;
            ct.y = y;
            ct.z = z;
            if (w.get(cr.car, c.Velocity)) |v| v.* = std.mem.zeroes(c.Velocity);
            const v = w.get(cr.car, c.Vehicle).?;
            // A wreck on the hook is not cleared away mid-air.
            if (v.flags & c.Vehicle.flag_wrecked != 0 and v.timer < 2) v.timer = 2;
            // Riders ride along.
            if (!v.driver.isNone()) {
                if (w.get(v.driver, c.Transform)) |dt| dt.* = ct.*;
            }
        }

        fn pickUp(self: *Self, cr: *Crane) void {
            const w = &self.state.world;
            cr.car = cr.want;
            cr.want = .none;
            const v = w.get(cr.car, c.Vehicle) orelse return;
            Self.trailers.detach(self, cr.car);
            v.xflags |= c.Vehicle.xf_lifted;
            v.flags &= ~c.Vehicle.flag_ai;
            if (w.get(cr.car, c.Collider)) |col| col.flags = (col.flags | c.Collider.flag_disabled) & ~c.Collider.flag_grounded;
        }

        fn drop(self: *Self, cr: *Crane, slot: u1) void {
            const w = &self.state.world;
            const car = cr.car;
            Me.letGo(self, cr);
            const t = w.get(car, c.Transform) orelse return;
            t.heading = cr.theading[slot];
            t.z = groundAt(self, t.x, t.y);
            const v = w.get(car, c.Vehicle) orelse return;
            // A crushed wreck put down by a crane with a power-up: the
            // generator decides the reward by its model.
            if (v.flags & c.Vehicle.flag_crushed != 0 and !cr.gen.isNone()) Self.objects.decidePowerUp(self, cr.gen, v.model);
        }

        /// Let go of the car where it hangs.
        fn letGo(self: *Self, cr: *Crane) void {
            const w = &self.state.world;
            const car = cr.car;
            cr.car = .none;
            const v = w.get(car, c.Vehicle) orelse return;
            v.xflags &= ~c.Vehicle.xf_lifted;
            if (w.get(car, c.Collider)) |col| col.flags &= ~c.Collider.flag_disabled;
        }

        /// The car this crane should pick up next, or none.
        fn candidate(self: *Self, cr: *Crane) EntityId {
            const s = st(self);
            const Ctx = struct {
                sim: *Self,
                cr: *const Crane,
                /// From the home crane's first target: crushed wrecks only.
                from: ?[2]Fx,
                best: EntityId = .none,
                d: Fx = std.math.maxInt(Fx),
            };
            var from: ?[2]Fx = null;
            if (cr.link != 0) {
                const home = &s.cranes[cr.link - 1];
                if (home.targets & 1 == 0) return .none;
                from = .{ home.tx[0], home.ty[0] };
            }
            var ctx = Ctx{ .sim = self, .cr = cr, .from = from };
            self.state.world.each(.{ c.Vehicle, c.Transform, c.Velocity }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, v: *c.Vehicle, t: *c.Transform, vel: *c.Velocity) void {
                    if (v.xflags & c.Vehicle.xf_lifted != 0 or !v.towId().isNone()) return;
                    if (v.flags & c.Vehicle.flag_ai != 0) return;
                    if (Self.speedOf(vel) > TV.still_speed) return;
                    if (fx.abs(t.z - cx.cr.bz) > fx.one) return;
                    if (Self.objects.beingCrushed(cx.sim, id)) return;
                    // A wreck about to be cleared.
                    if (v.flags & c.Vehicle.flag_wrecked != 0 and v.timer < 2 and v.flags & c.Vehicle.flag_crushed == 0) return;
                    var d: Fx = 0;
                    if (cx.from) |p| {
                        if (v.flags & c.Vehicle.flag_crushed == 0) return;
                        d = @max(fx.abs(t.x - p[0]), fx.abs(t.y - p[1]));
                        if (d > fx.one) return;
                    } else {
                        if (@max(fx.abs(t.x - cx.cr.bx), fx.abs(t.y - cx.cr.by)) > TV.reach) return;
                        // Not a car already put down at one of its targets.
                        for (0..2) |k| {
                            if (cx.cr.targets & (@as(u8, 1) << @intCast(k)) == 0) continue;
                            if (@max(fx.abs(t.x - cx.cr.tx[k]), fx.abs(t.y - cx.cr.ty[k])) <= fx.one) return;
                        }
                        if (v.flags & c.Vehicle.flag_crushed != 0) return;
                        d = fx.length(t.x - cx.cr.bx, t.y - cx.cr.by);
                    }
                    if (d < cx.d) {
                        cx.d = d;
                        cx.best = id;
                    }
                }
            }.f);
            return ctx.best;
        }

        /// Has the candidate been still long enough? Counts up `timer`
        /// (wrecks from a crusher go at once).
        fn stillFor(cr: *Crane) bool {
            if (cr.link != 0) return true;
            if (cr.timer < TV.wait_ticks) {
                cr.timer += 1;
                return false;
            }
            cr.timer = 0;
            return true;
        }

        /// Is the car still there to grab (not driven off, not taken)?
        fn stillOk(self: *Self, car: EntityId) bool {
            const w = &self.state.world;
            const v = w.get(car, c.Vehicle) orelse return false;
            if (v.xflags & c.Vehicle.xf_lifted != 0) return false;
            const vel = w.get(car, c.Velocity) orelse return false;
            return Self.speedOf(vel) <= TV.still_speed * 4;
        }
    };
}
