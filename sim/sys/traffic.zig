//! Traffic: how computer-driven cars drive (traffic-and-car-ai.md).
//! Methods of `Sim(cfg)`, aliased in `sim.zig`; `step()` there calls the
//! systems in their fixed order. Owner: workstream F.
//!
//! One pass per AI car per tick, in the note's order (section 4):
//!
//!  1. Halt (3.3): a forced stop (100 ticks after hitting a ped), a script
//!     or stop-task halt, giving up off-road, or yielding at a junction:
//!     brake, with the handbrake above 0.05.
//!  2. Heading: a car task's route or direct bearing (`ai/car_tasks.zig`,
//!     3.7), else the lane arrows (3.4): straight on at a junction where
//!     the road goes on, else a 50/50 left or right pick made once; then
//!     the settle-into-lane after a turn (wait for a gap beside); off the
//!     road, seek road (ahead, left, right, behind; one level down too),
//!     and give up after 200 ticks unless script-created.
//!  3. Junction right-of-way: a car about to enter a junction makes every
//!     AI car on the cross street outside the junction hold for 50 ticks.
//!  4. Look-ahead (3.5): the car's own box placed 1.75 blocks ahead along
//!     its target heading (1 block and 8 degrees into a turn), then 1
//!     block; the nearest body or crossing marker found is the obstacle.
//!     A car ahead: brake (handbrake above 0.4), or, within a block at a
//!     steep angle or the player's, honk and coast. Not in the first 20
//!     ticks, never for buses, not on ramps or while backing out. A task
//!     car ignores its own target and matches its speed. A crossing marker
//!     (3.6): a handbrake stop, once per marker. A crawling queue near a
//!     marker: overtake through a clear lane beside.
//!  5. Getting unstuck: back out of a wall; wiggle against a car it is
//!     stuck to (toward it for 20 ticks, then away).
//!  6. Speed setting (3.2): up 0.01 a tick to the target, down 0.08 a tick,
//!     turned into throttle and brake.
//!
//! Honking is a `special` button press (the horn flag): 1 car in 8 does it,
//! emergency vehicles always.
//!
//! Ours where the note is open (tagged in `tuning/traffic.zig`): the stop
//! at a crossing marker ends once the car is below 0.02 a tick (the note's
//! stop would never end); backing out lasts a bounded 25 ticks after 10 at
//! a standstill; the junction sweep box; the overtake's swing and length;
//! seek road turns toward the road instead of reversing; a car braking for
//! a car ahead never backs out (its desired speed is 0, so the note's
//! "reverse while slower than desired" never holds).

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const input = prelude.input;
const fx = prelude.fx;
const ecs = prelude.ecs;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const Frame = prelude.Frame;
const Button = prelude.Button;
const eql = prelude.eql;
const salt_ai_plan = prelude.salt_ai_plan;
const ids = @import("../ids.zig");
const TF = @import("../tuning/traffic.zig");
const car_tasks_mod = @import("../ai/car_tasks.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        const Api = @This();
        const nil = Self.nil;
        const cell_shift = Self.cell_shift;
        const cells_x = Self.cells_x;
        const cells_y = Self.cells_y;

        pub const dir_heading = [4]u16{ 0, 16384, 32768, 49152 };

        pub const dir_arrow = [4]u4{ map.Arrow.pos_x, map.Arrow.pos_y, map.Arrow.neg_x, map.Arrow.neg_y };

        pub fn arrowCount(a: u4) u32 {
            return @popCount(a);
        }

        pub fn sysTrafficAi(self: *Self) void {
            if (self.predicting()) return; // traffic is never predicted
            self.buildBroadphase();
            self.state.world.each(.{ c.Vehicle, c.Controller, c.Transform, c.Velocity }, self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity) void {
                    Api.driveCar(sim, id, v, ctl, t, vel);
                }
            }.f);
        }

        fn brakeFrame(v: *c.Vehicle, vf: Fx) Frame {
            v.ai_speed = 0;
            const hb: u16 = if (vf > fx.ratio(5, 100)) Button.handbrake_jump else 0;
            return .{ .steer = 0, .throttle = if (vf > fx.ratio(1, 100)) -127 else 0, .buttons = hb, .aim = 0, .seq = 0 };
        }

        /// Does 1 car in 8 (by entity index) honk, or every emergency one?
        pub fn honker(id: EntityId, v: *const c.Vehicle) bool {
            if (v.ai_flags & c.Vehicle.ai_emergency != 0) return true;
            return ((id.index() *% 2654435761) >> 29) == 0;
        }

        /// One AI car, one tick (see the file comment).
        pub fn driveCar(self: *Self, id: EntityId, v: *c.Vehicle, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity) void {
            if (v.flags & c.Vehicle.flag_ai == 0 or ctl.player != c.Controller.no_player) return;
            if (v.flags & (c.Vehicle.flag_wrecked | c.Vehicle.flag_burning) != 0) {
                // A burning car stops; its driver has fled.
                ctl.in = Frame.neutral(0);
                return;
            }
            v.ai_age +|= 1;
            const fwd_x = fx.cos(t.heading);
            const fwd_y = fx.sin(t.heading);
            const vf = fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y);
            const task = Self.car_tasks.driveOf(self, id, t);

            // 1. Halt.
            if (v.halt > 0) {
                v.halt -= 1;
                ctl.in = brakeFrame(v, vf);
                return;
            }
            if (v.ai_yield > 0) {
                v.ai_yield -= 1;
                ctl.in = brakeFrame(v, vf);
                return;
            }
            const held = v.ai_flags & (c.Vehicle.ai_halted | c.Vehicle.ai_abandoned) != 0;
            if (held or (task != null and task.?.hold)) {
                ctl.in = brakeFrame(v, vf);
                return;
            }

            // 2. Heading.
            const cell = map.floorCell(self.grid, t.x, t.y, t.z, T.car_step);
            const arrows = map.arrowsOf(cell);
            const on_road = map.groundOf(cell) == map.Ground.road;
            const on_ramp = map.shapeOf(cell) == map.Shape.slope;
            const lane = on_road and arrowCount(arrows) == 1;
            const old_dir = v.ai_dir & 3;
            var direct: ?u16 = null;
            if (task) |d| direct = d.heading;
            if (on_road) v.ai_lost = 0;
            if (direct == null) {
                if (on_road and task != null and task.?.dir != null) {
                    v.ai_dir = task.?.dir.?;
                    v.ai_plan = if (lane) 0 else c.Vehicle.plan_in_junction;
                } else if (on_road) {
                    direct = Api.junctionDrive(self, id, v, t, arrows);
                } else {
                    // Seek road; give up after 200 ticks unless a script
                    // made the car or it has a task.
                    v.ai_lost +|= 1;
                    if (task == null and v.ai_flags & c.Vehicle.ai_script == 0 and v.ai_lost >= TF.traffic_give_up_ticks) {
                        v.ai_flags |= c.Vehicle.ai_abandoned;
                        ctl.in = brakeFrame(v, vf);
                        return;
                    }
                    if (Api.seekRoad(self, t, v.ai_dir & 3)) |d| v.ai_dir = d;
                }
            }
            if (v.ai_dir & 3 != old_dir) v.ai_flags |= c.Vehicle.ai_settling;
            const want = direct orelse dir_heading[v.ai_dir & 3];
            const turning_exit = direct != null and task == null;
            var target = want;
            // Ours: also straight on through a junction (a cell whose arrows
            // include ours, or none), so two cars side by side there keep
            // their lanes instead of scraping.
            const straight_on = on_road and (arrows == 0 or arrows & dir_arrow[v.ai_dir & 3] != 0) and v.ai_plan & 3 == 0;
            if (direct == null and on_road and (lane or task != null or straight_on) and v.ai_pass == 0) {
                target = Api.laneTarget(self, id, v, t, want);
            }
            if (v.ai_pass > 0) {
                // Overtaking: swing out for the first 12 ticks, then hold
                // the line until the next lane's centring takes over.
                if (v.ai_pass > TF.overtake_ticks - TF.overtake_swing_ticks) {
                    target = want +% @as(u16, @bitCast(@as(i16, v.ai_side) * TF.overtake_swing));
                }
                v.ai_pass -= 1;
                if (v.ai_pass == 0) {
                    v.ai_side = 0;
                    v.ai_flags |= c.Vehicle.ai_settling;
                }
            }
            const diff: i16 = @bitCast(target -% t.heading);
            var steer = std.math.clamp(@divTrunc(@as(i32, diff) * 127, 3500), -127, 127);
            const want_diff: i16 = @bitCast(want -% t.heading);
            const turning = @abs(@as(i32, want_diff)) > 6000;

            // 3. Junction right-of-way.
            if (lane and (direct == null or turning_exit) and Api.junctionAhead(self, t, v.ai_dir & 3)) Api.sweepJunction(self, id, t);

            // 4. Look-ahead.
            var goal: Fx = if (task) |d| d.speed else T.traffic_speed;
            var obstacle = false;
            var neutral = false;
            var honk = false;
            var handbrake_stop = false;
            var face_off = false;
            var blocked_by: u16 = 0;
            const reversing = v.timer >= c.Vehicle.reverse_base;
            const into: i32 = if (want_diff >= 0) 1 else -1;
            const probe_h: u16 = if (turning) t.heading +% @as(u16, @bitCast(@as(i16, @intCast(into * TF.traffic_turn_probe_angle)))) else want;
            const ex_target: EntityId = if (task) |d| d.target else .none;
            const ex_ped: EntityId = if (task) |d| d.exempt_ped else .none;
            if (Api.probeAhead(self, id, t, v, probe_h, if (turning) T.traffic_look_turning else T.traffic_look, on_ramp, ex_target, ex_ped)) |h| {
                switch (h.what) {
                    .car => {
                        const checks = v.ai_age >= TF.traffic_ahead_grace and v.ai_flags & c.Vehicle.ai_bus == 0 and !on_ramp and !reversing;
                        if (checks) {
                            const rel: i16 = @bitCast(h.heading -% t.heading);
                            const steep = @abs(@as(i32, rel)) > 8192;
                            if (h.dist < TF.traffic_close and (steep or h.player)) {
                                neutral = true;
                                honk = true;
                                // Both stopped nose to nose: back out (the
                                // note's second stuck check).
                                if (h.speed < fx.ratio(1, 100)) face_off = true;
                            } else {
                                obstacle = true;
                                if (h.speed < TF.overtake_crawl and task == null) Api.tryOvertake(self, id, v, t, arrows);
                                // Stopped behind a stopped car: a crossing or
                                // facing car soon backs out, one in our own
                                // lane only after a long wait (ours).
                                if (h.speed < fx.ratio(1, 100)) {
                                    blocked_by = if (@abs(@as(i32, rel)) > 8192) T.traffic_stuck_ticks else TF.queue_stuck_ticks;
                                }
                            }
                        }
                    },
                    .ped => {
                        obstacle = true;
                        // Waiting on a ped in the road: honk (ours: the
                        // note says "slow, stop or honk").
                        if (h.dist < TF.traffic_close or vf < TF.marker_release_speed) honk = true;
                        // Ours: a car stopped at an angle to its lane with a
                        // ped (usually on the pavement) in its nose can't
                        // turn on the spot; after a while it backs out.
                        if (turning and fx.abs(vf) < fx.ratio(1, 100)) blocked_by = TF.ped_turn_stuck_ticks;
                    },
                    .marker => if (task == null) {
                        obstacle = true;
                        handbrake_stop = true;
                        // Ours: the stop ends once the car is crawling.
                        if (vf < TF.marker_release_speed) v.ai_mark = @intCast(h.id.index() + 1);
                    },
                }
            }
            if (!obstacle) {
                if (task) |d| if (d.match) |m| {
                    goal = m;
                };
            }

            // 5. Getting unstuck: wiggle against a car stuck to this one.
            var wiggle = false;
            if (!obstacle and !neutral and fx.abs(vf) < TF.wiggle_speed) {
                if (Api.touchingCar(self, id, t, v)) |other| {
                    const idx: u16 = @intCast(other.id.index() + 1);
                    if (v.ai_touch == idx) v.ai_wiggle +|= 1 else {
                        v.ai_touch = idx;
                        v.ai_wiggle = 1;
                    }
                    // Ours: only once stuck for a few ticks, and gently.
                    wiggle = v.ai_wiggle >= TF.wiggle_wait;
                    const side = fx.mul(other.x - t.x, -fwd_y) + fx.mul(other.y - t.y, fwd_x);
                    const toward: i32 = if (side >= 0) 127 else -127;
                    if (wiggle) steer = if (v.ai_wiggle <= TF.wiggle_flip_ticks + TF.wiggle_wait) toward else -toward;
                } else {
                    v.ai_touch = 0;
                    v.ai_wiggle = 0;
                }
            } else {
                v.ai_touch = 0;
                v.ai_wiggle = 0;
            }

            // 6. Speed setting.
            // Ours: traffic slows for a bend or a turn, which tightens its
            // turning circle enough for a one-block lane.
            if (task == null and (turning or (lane and Api.bendAhead(self, t, v.ai_dir & 3) != null))) goal = @min(goal, TF.bend_speed);
            if (obstacle or neutral) goal = 0;
            goal = @min(goal, TF.traffic_speed_max);
            var sp: Fx = v.ai_speed;
            const acc = T.traffic_accel;
            sp = if (sp < goal) @min(sp + acc, goal) else @max(sp - T.traffic_decel, goal);
            v.ai_speed = @intCast(sp);
            var throttle: i32 = if (vf < sp) 100 else if (vf > sp + fx.ratio(2, 100)) -127 else 0;
            if (neutral) throttle = 0;
            var buttons: u16 = 0;
            if (obstacle) {
                if (vf > T.traffic_handbrake_speed or (handbrake_stop and vf > fx.ratio(1, 100))) buttons = Button.handbrake_jump;
                if (v.timer < c.Vehicle.reverse_base) {
                    if (blocked_by > 0 and fx.abs(vf) < fx.ratio(1, 100)) {
                        v.timer += 1;
                        if (v.timer >= blocked_by) v.timer = c.Vehicle.reverse_base + T.traffic_reverse_ticks;
                    } else v.timer = 0;
                }
            }
            if (wiggle) {
                throttle = TF.wiggle_throttle;
                v.timer = 0;
            } else if (v.timer >= c.Vehicle.reverse_base) {
                // Backing out of a wall, the wheels turned the other way.
                v.timer -= 1;
                if (v.timer == c.Vehicle.reverse_base) v.timer = 0;
                throttle = -110;
                steer = -steer;
            } else if ((!obstacle and !neutral or face_off) and fx.abs(vf) < fx.ratio(1, 100)) {
                v.timer += 1;
                if (v.timer >= T.traffic_stuck_ticks) v.timer = c.Vehicle.reverse_base + T.traffic_reverse_ticks;
            } else if (!obstacle and !face_off) v.timer = 0;
            if (honk and Api.honker(id, v)) buttons |= Button.special;
            ctl.in = .{ .steer = @intCast(steer), .throttle = @intCast(throttle), .buttons = buttons, .aim = 0, .seq = 0 };
        }

        inline fn isJunction(a: u4) bool {
            return arrowCount(a) != 1;
        }

        /// The road cell at block (bx, by) at the car's height, if road.
        fn roadCellAt(self: *Self, t: *const c.Transform, bx: i32, by: i32) ?u4 {
            const cell = map.floorCell(self.grid, fx.fromInt(bx) + fx.half, fx.fromInt(by) + fx.half, t.z, T.car_step);
            if (map.groundOf(cell) != map.Ground.road) return null;
            return map.arrowsOf(cell);
        }

        /// The exit lane block for leaving the junction ahead heading `nd`,
        /// having approached heading `dir`: along `dir` from the car's
        /// block (up to `junction_scan` blocks), the first block from which
        /// heading `nd` through junction cells reaches a lane cell whose
        /// arrow is `nd`. For `nd == dir` this is the straight-on exit.
        pub fn exitFor(self: *Self, t: *const c.Transform, dir: u8, nd: u8) ?[2]i32 {
            const bx = fx.toInt(t.x);
            const by = fx.toInt(t.y);
            const sx = [4]i32{ 1, 0, -1, 0 };
            const sy = [4]i32{ 0, 1, 0, -1 };
            var k: i32 = 0;
            var inside = false;
            while (k <= TF.junction_scan) : (k += 1) {
                const px = bx + sx[dir] * k;
                const py = by + sy[dir] * k;
                const pa = Api.roadCellAt(self, t, px, py) orelse return null;
                if (isJunction(pa)) {
                    inside = true;
                } else if (inside) {
                    // Past the junction: straight on only.
                    if (nd == dir and pa & dir_arrow[dir] != 0) return .{ px, py };
                    return null;
                }
                if (nd == dir) continue;
                var m: i32 = 1;
                while (m <= TF.junction_scan) : (m += 1) {
                    const ex = px + sx[nd] * m;
                    const ey = py + sy[nd] * m;
                    const ea = Api.roadCellAt(self, t, ex, ey) orelse break;
                    if (isJunction(ea)) continue;
                    if (ea == dir_arrow[nd]) return .{ ex, ey };
                    break;
                }
            }
            return null;
        }

        /// Driving through a junction (3.4) for ordinary traffic. On a lane
        /// cell the car follows its arrow; one or two blocks before a
        /// junction (the note's far probe) it picks, once, straight on if
        /// the road goes on, else left or right 50/50 (the other if that
        /// way has no exit). A turn steers at the exit lane, one block past
        /// its first block, from the approach on (ours: the AI's turning
        /// circle is about 1.5 blocks, so turning only once inside the
        /// junction swung cars into the far lane); the turn is made when
        /// the car reaches a lane running the new way. Returns the heading
        /// to steer by while turning, else null (follow `ai_dir`).
        pub fn junctionDrive(self: *Self, id: EntityId, v: *c.Vehicle, t: *const c.Transform, arrows: u4) ?u16 {
            const pending = v.ai_plan & c.Vehicle.plan_in_junction != 0;
            const turn = v.ai_plan & 3;
            const dir = v.ai_dir & 3;
            const nd: u8 = if (turn == 1) (dir + 1) & 3 else (dir + 3) & 3;
            if (!isJunction(arrows)) {
                var ld: u8 = 0;
                while (dir_arrow[ld] != arrows) : (ld += 1) {}
                if (pending and turn != 0 and ld == nd) {
                    // On the exit lane: the turn is made.
                    v.ai_dir = nd;
                    v.ai_plan = 0;
                    return null;
                }
                if (pending and turn != 0) {
                    // Still on the approach, or crossing a lane of other
                    // traffic mid-turn: keep steering for the exit.
                    if (Api.exitFor(self, t, dir, nd)) |e| return aimAt(t, e, nd);
                }
                // Run wide onto a lane going the other way: back to the lane
                // beside it that runs our way (ours).
                const facing: u8 = @intCast(((@as(u32, t.heading) + 8192) >> 14) & 3);
                if (ld == (facing + 2) & 3) {
                    if (Api.laneBeside(self, t, facing)) |e| {
                        v.ai_dir = facing;
                        v.ai_plan = 0;
                        return aimAt(t, e, facing);
                    }
                }
                v.ai_dir = ld;
                // A bend in the lane ahead: start turning before it.
                if (Api.bendAhead(self, t, ld)) |b| {
                    v.ai_plan = 0;
                    return aimAt(t, .{ b[0], b[1] }, @intCast(b[2]));
                }
                if (!Api.junctionAhead(self, t, ld)) {
                    v.ai_plan = 0;
                    return null;
                }
                if (!pending or turn == 0 and v.ai_dir != dir) Api.planJunction(self, id, v, t);
            } else if (!pending) {
                Api.planJunction(self, id, v, t);
            }
            const p = v.ai_plan & 3;
            if (p == 0) return null;
            const d = v.ai_dir & 3;
            const n: u8 = if (p == 1) (d + 1) & 3 else (d + 3) & 3;
            if (Api.exitFor(self, t, d, n)) |e| return aimAt(t, e, n);
            // Lost the exit (pushed past it): go straight on and re-plan.
            v.ai_plan = c.Vehicle.plan_in_junction;
            return null;
        }

        /// The nearest lane cell running `dir` one or two blocks to either
        /// side of the car.
        pub fn laneBeside(self: *Self, t: *const c.Transform, dir: u8) ?[2]i32 {
            const sx = [4]i32{ 1, 0, -1, 0 };
            const sy = [4]i32{ 0, 1, 0, -1 };
            const bx = fx.toInt(t.x);
            const by = fx.toInt(t.y);
            var k: i32 = 1;
            while (k <= 2) : (k += 1) {
                for ([2]u8{ (dir + 1) & 3, (dir + 3) & 3 }) |side| {
                    const px = bx + sx[side] * k;
                    const py = by + sy[side] * k;
                    const a = Api.roadCellAt(self, t, px, py) orelse continue;
                    if (a == dir_arrow[dir]) return .{ px, py };
                }
            }
            return null;
        }

        /// A bend in the lane ahead (ours): within `bend_scan` blocks along
        /// `dir`, a lane cell whose one arrow is at right angles to `dir`,
        /// as (x, y, new direction). The arrows alone turn a car only once
        /// it is on the bend cell, too late for its turning circle, so it
        /// swung into the lane beyond.
        pub fn bendAhead(self: *Self, t: *const c.Transform, dir: u8) ?[3]i32 {
            const sx = [4]i32{ 1, 0, -1, 0 };
            const sy = [4]i32{ 0, 1, 0, -1 };
            const bx = fx.toInt(t.x);
            const by = fx.toInt(t.y);
            var k: i32 = 1;
            while (k <= TF.bend_scan) : (k += 1) {
                const px = bx + sx[dir] * k;
                const py = by + sy[dir] * k;
                const a = Api.roadCellAt(self, t, px, py) orelse return null;
                if (a == dir_arrow[dir]) continue;
                if (a == dir_arrow[(dir + 1) & 3]) return .{ px, py, (dir + 1) & 3 };
                if (a == dir_arrow[(dir + 3) & 3]) return .{ px, py, (dir + 3) & 3 };
                return null;
            }
            return null;
        }

        /// Pick straight on, or a turn that has an exit, for the junction
        /// ahead (once per approach).
        fn planJunction(self: *Self, id: EntityId, v: *c.Vehicle, t: *const c.Transform) void {
            const d = v.ai_dir & 3;
            if (Api.exitFor(self, t, d, d) != null) {
                v.ai_plan = c.Vehicle.plan_in_junction;
                return;
            }
            var p = self.turnPick(id);
            const n1: u8 = if (p == 1) (d + 1) & 3 else (d + 3) & 3;
            if (Api.exitFor(self, t, d, n1) == null) {
                p = 3 - p;
                const n2: u8 = if (p == 1) (d + 1) & 3 else (d + 3) & 3;
                if (Api.exitFor(self, t, d, n2) == null) p = 0; // dead end: seek road later
            }
            v.ai_plan = c.Vehicle.plan_in_junction | p;
        }

        fn aimAt(t: *const c.Transform, e: [2]i32, nd: u8) u16 {
            const sx = [4]i32{ 1, 0, -1, 0 };
            const sy = [4]i32{ 0, 1, 0, -1 };
            const ax = fx.fromInt(e[0] + sx[nd]) + fx.half;
            const ay = fx.fromInt(e[1] + sy[nd]) + fx.half;
            return fx.atan2(ay - t.y, ax - t.x);
        }

        /// The old in-junction turn choice, kept for callers; traffic uses
        /// `junctionDrive`.
        pub fn junctionTurn(self: *Self, id: EntityId, v: *c.Vehicle, t: *const c.Transform, arrows: u4) void {
            _ = arrows;
            _ = Api.junctionDrive(self, id, v, t, 0);
        }

        /// Lane centring (and the settle into the lane after a turn): aim at
        /// the middle of the block across the direction of travel. While
        /// settling, a nudge waits for a clear gap half a block that way;
        /// settling ends in the middle 20% with the heading within ~3
        /// degrees.
        pub fn laneTarget(self: *Self, id: EntityId, v: *c.Vehicle, t: *const c.Transform, want: u16) u16 {
            const d = v.ai_dir & 3;
            const across = if (d & 1 == 0) t.y else t.x;
            const off = (across & (fx.one - 1)) - fx.half; // -0.5..0.5
            const sign: i32 = switch (d) {
                0 => -1,
                1 => 1,
                2 => 1,
                else => -1,
            };
            const hd: i16 = @bitCast(want -% t.heading);
            if (v.ai_flags & c.Vehicle.ai_settling != 0 and fx.abs(off) <= TF.settle_band and @abs(@as(i32, hd)) <= TF.settle_heading) {
                v.ai_flags &= ~c.Vehicle.ai_settling;
            }
            if (fx.abs(off) > TF.settle_band) {
                // The gap check: half a block toward the centre; hold the
                // line while it's taken. (The note does this while settling
                // after a turn; ours does it for the continuous nudge too,
                // so two cars squeezed into one lane don't grind together.)
                const gx = if (d & 1 == 0) t.x else t.x - (if (off > 0) fx.half else -fx.half);
                const gy = if (d & 1 == 0) t.y - (if (off > 0) fx.half else -fx.half) else t.y;
                if (Api.bodyNear(self, id, gx, gy, t.z, TF.settle_gap_radius)) return want;
            }
            const corr = std.math.clamp(@divTrunc(off * 6000 * sign, fx.one), -3000, 3000);
            return want +% @as(u16, @truncate(@as(u32, @bitCast(corr))));
        }

        /// Seek road (3.4): straight ahead, left, right, then behind; one
        /// block over at the car's level or one below.
        pub fn seekRoad(self: *Self, t: *const c.Transform, dir: u8) ?u8 {
            const order = [4]u8{ 0, 3, 1, 2 };
            // Ours: the note probes one block; we look up to three out, so
            // a car that ran wide onto a two-block pavement still finds
            // the road beside it.
            var k: i32 = 1;
            while (k <= TF.seek_road_blocks) : (k += 1) {
                for (order) |o| {
                    const d = (dir + o) & 3;
                    const h = dir_heading[d];
                    const px = t.x + fx.cos(h) * k;
                    const py = t.y + fx.sin(h) * k;
                    const cell = map.floorCell(self.grid, px, py, t.z, T.car_step);
                    if (map.groundOf(cell) == map.Ground.road) return d;
                    const below = map.floorCell(self.grid, px, py, t.z - fx.one, T.car_step);
                    if (map.groundOf(below) == map.Ground.road) return d;
                }
            }
            return null;
        }

        /// Is the block one or two ahead (direction `dir`) a junction (road
        /// without a single lane arrow)?
        pub fn junctionAhead(self: *Self, t: *const c.Transform, dir: u8) bool {
            const h = dir_heading[dir & 3];
            var k: i32 = 1;
            while (k <= 2) : (k += 1) {
                const px = t.x + fx.cos(h) * k;
                const py = t.y + fx.sin(h) * k;
                const cell = map.floorCell(self.grid, px, py, t.z, T.car_step);
                if (map.groundOf(cell) != map.Ground.road) return false;
                if (arrowCount(map.arrowsOf(cell)) != 1) return true;
            }
            return false;
        }

        /// Junction right-of-way (3.4): every AI car crossing our path
        /// ahead, not yet inside the junction and not already yielding, is
        /// made to hold for 50 ticks.
        pub fn sweepJunction(self: *Self, self_id: EntityId, t: *const c.Transform) void {
            const sc = &self.scratch;
            const fwd_x = fx.cos(t.heading);
            const fwd_y = fx.sin(t.heading);
            const cxf = t.x + fx.mul(fwd_x, TF.sweep_ahead);
            const cyf = t.y + fx.mul(fwd_y, TF.sweep_ahead);
            const ccx: i32 = std.math.clamp(cxf >> cell_shift, 0, cells_x - 1);
            const ccy: i32 = std.math.clamp(cyf >> cell_shift, 0, cells_y - 1);
            const w = &self.state.world;
            var dy: i32 = -2;
            while (dy <= 2) : (dy += 1) {
                var dx: i32 = -2;
                while (dx <= 2) : (dx += 1) {
                    const nx = ccx + dx;
                    const ny = ccy + dy;
                    if (nx < 0 or ny < 0 or nx >= cells_x or ny >= cells_y) continue;
                    const cell: u32 = @intCast(ny * cells_x + nx);
                    if (sc.cell_stamp[cell] != sc.stamp) continue;
                    var j = sc.cell_head[cell];
                    while (j != nil) : (j = sc.entries[j].next) {
                        const e = sc.entries[j];
                        if (eql(e.id, self_id)) continue;
                        if (fx.abs(e.z - t.z) > fx.half) continue;
                        const rx = e.x - cxf;
                        const ry = e.y - cyf;
                        const along = fx.mul(rx, fwd_x) + fx.mul(ry, fwd_y);
                        const side = fx.mul(rx, -fwd_y) + fx.mul(ry, fwd_x);
                        if (fx.abs(along) > TF.sweep_half_along or fx.abs(side) > TF.sweep_half_side) continue;
                        const ov = w.get(e.id, c.Vehicle) orelse continue;
                        if (ov.flags & c.Vehicle.flag_ai == 0 or ov.ai_yield != 0) continue;
                        const octl = w.get(e.id, c.Controller) orelse continue;
                        if (octl.player != c.Controller.no_player) continue;
                        const ot = w.get(e.id, c.Transform) orelse continue;
                        const rel: i16 = @bitCast(ot.heading -% t.heading);
                        const a = @abs(@as(i32, rel));
                        if (a < 8192 or a > 24576) continue; // not crossing
                        // Only cars still heading toward our path.
                        const line_side = fx.mul(e.x - t.x, -fwd_y) + fx.mul(e.y - t.y, fwd_x);
                        const head_side = fx.mul(fx.cos(ot.heading), -fwd_y) + fx.mul(fx.sin(ot.heading), fwd_x);
                        if ((line_side > 0) == (head_side > 0)) continue;
                        const ocell = map.floorCell(self.grid, ot.x, ot.y, ot.z, T.car_step);
                        if (map.groundOf(ocell) == map.Ground.road and arrowCount(map.arrowsOf(ocell)) != 1) continue; // already in it
                        ov.ai_yield = TF.yield_ticks;
                    }
                }
            }
        }

        pub const Hit = struct {
            what: enum { car, ped, marker },
            id: EntityId,
            dist: Fx,
            heading: u16 = 0,
            speed: Fx = 0,
            player: bool = false,
        };

        /// The look-ahead (3.5): the car's own box placed `look` ahead along
        /// `h`, then 1 block ahead; the nearest body (or, in single player,
        /// crossing marker not already stopped at) inside either.
        pub fn probeAhead(self: *Self, self_id: EntityId, t: *const c.Transform, v: *const c.Vehicle, h: u16, look: Fx, on_ramp: bool, ex_target: EntityId, ex_ped: EntityId) ?Hit {
            const m = T.carModel(v.model);
            const sc = &self.scratch;
            const w = &self.state.world;
            const zr: Fx = if (on_ramp) fx.one else fx.half;
            const probes = [2]struct { h: u16, d: Fx }{ .{ .h = h, .d = look }, .{ .h = t.heading, .d = fx.one } };
            var best: ?Hit = null;
            for (probes) |p| {
                const fwd_x = fx.cos(p.h);
                const fwd_y = fx.sin(p.h);
                const cxf = t.x + fx.mul(fwd_x, p.d);
                const cyf = t.y + fx.mul(fwd_y, p.d);
                const ccx: i32 = std.math.clamp(cxf >> cell_shift, 0, cells_x - 1);
                const ccy: i32 = std.math.clamp(cyf >> cell_shift, 0, cells_y - 1);
                var dy: i32 = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) {
                        const nx = ccx + dx;
                        const ny = ccy + dy;
                        if (nx < 0 or ny < 0 or nx >= cells_x or ny >= cells_y) continue;
                        const cell: u32 = @intCast(ny * cells_x + nx);
                        if (sc.cell_stamp[cell] != sc.stamp) continue;
                        var j = sc.cell_head[cell];
                        while (j != nil) : (j = sc.entries[j].next) {
                            const e = sc.entries[j];
                            if (eql(e.id, self_id) or eql(e.id, ex_target) or eql(e.id, ex_ped)) continue;
                            if (fx.abs(e.z - t.z) > zr) continue;
                            const rx = e.x - cxf;
                            const ry = e.y - cyf;
                            const along = fx.mul(rx, fwd_x) + fx.mul(ry, fwd_y);
                            const side = fx.mul(rx, -fwd_y) + fx.mul(ry, fwd_x);
                            if (fx.abs(along) >= m.half_len + (e.r >> 1) or fx.abs(side) >= m.half_wid + (e.r >> 1)) continue;
                            // Not behind the car's own nose.
                            const ax = e.x - t.x;
                            const ay = e.y - t.y;
                            if (fx.mul(ax, fx.cos(t.heading)) + fx.mul(ay, fx.sin(t.heading)) <= fx.ratio(3, 10)) continue;
                            const dist = fx.length(ax, ay);
                            if (best != null and best.?.dist <= dist) continue;
                            if (w.get(e.id, c.Vehicle)) |ov| {
                                const ot = w.get(e.id, c.Transform).?;
                                const ovel = w.get(e.id, c.Velocity).?;
                                const octl = w.get(e.id, c.Controller).?;
                                const player = !ov.driver.isNone() and octl.player != c.Controller.no_player;
                                best = .{ .what = .car, .id = e.id, .dist = dist, .heading = ot.heading, .speed = fx.length(ovel.vx, ovel.vy), .player = player };
                            } else {
                                best = .{ .what = .ped, .id = e.id, .dist = dist };
                            }
                        }
                    }
                }
                if (comptime Self.single_player) {
                    if (Api.markerIn(self, t, fwd_x, fwd_y, cxf, cyf, m, v.ai_mark)) |mk| {
                        if (best == null or mk.dist < best.?.dist) best = mk;
                    }
                }
            }
            return best;
        }

        /// A crossing marker (an `Object` of kind `crossing_marker`, placed
        /// by workstream B's light setup) inside a probe box, if it is not
        /// the one the car last stopped at.
        fn markerIn(self: *Self, t: *const c.Transform, fwd_x: Fx, fwd_y: Fx, cxf: Fx, cyf: Fx, m: *const T.CarModel, last: u16) ?Hit {
            const Ctx = struct { t: *const c.Transform, fwd_x: Fx, fwd_y: Fx, cxf: Fx, cyf: Fx, hl: Fx, hw: Fx, last: u16, best: ?Hit = null };
            var ctx = Ctx{ .t = t, .fwd_x = fwd_x, .fwd_y = fwd_y, .cxf = cxf, .cyf = cyf, .hl = m.half_len, .hw = m.half_wid, .last = last };
            self.state.world.each(.{ c.Object, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, o: *c.Object, ot: *c.Transform) void {
                    if (o.kind != @intFromEnum(ids.ObjectKind.crossing_marker)) return;
                    if (cx.last == id.index() + 1) return;
                    if (fx.abs(ot.z - cx.t.z) > fx.one) return;
                    const rx = ot.x - cx.cxf;
                    const ry = ot.y - cx.cyf;
                    const along = fx.mul(rx, cx.fwd_x) + fx.mul(ry, cx.fwd_y);
                    const side = fx.mul(rx, -cx.fwd_y) + fx.mul(ry, cx.fwd_x);
                    if (fx.abs(along) >= cx.hl or fx.abs(side) >= cx.hw) return;
                    const dist = fx.length(ot.x - cx.t.x, ot.y - cx.t.y);
                    if (cx.best == null or dist < cx.best.?.dist) cx.best = .{ .what = .marker, .id = id, .dist = dist };
                }
            }.f);
            return ctx.best;
        }

        /// Is a crossing marker within `dist` ahead of the car, near its
        /// line?
        fn markerAhead(self: *Self, t: *const c.Transform, dist: Fx) bool {
            if (comptime !Self.single_player) return false;
            const Ctx = struct { t: *const c.Transform, dist: Fx, found: bool = false };
            var ctx = Ctx{ .t = t, .dist = dist };
            self.state.world.each(.{ c.Object, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, _: EntityId, o: *c.Object, ot: *c.Transform) void {
                    if (o.kind != @intFromEnum(ids.ObjectKind.crossing_marker)) return;
                    const rx = ot.x - cx.t.x;
                    const ry = ot.y - cx.t.y;
                    const along = fx.mul(rx, fx.cos(cx.t.heading)) + fx.mul(ry, fx.sin(cx.t.heading));
                    const side = fx.mul(rx, -fx.sin(cx.t.heading)) + fx.mul(ry, fx.cos(cx.t.heading));
                    if (along > 0 and along < cx.dist + fx.one and fx.abs(side) < fx.ratio(25, 10)) cx.found = true;
                }
            }.f);
            return ctx.found;
        }

        /// The crossing-queue overtake (3.5): near a crossing marker, with
        /// two more road tiles ahead in our direction, swing out into a
        /// clear lane beside (probed 0.7 then 2 blocks over) that runs the
        /// same way.
        fn tryOvertake(self: *Self, id: EntityId, v: *c.Vehicle, t: *const c.Transform, arrows: u4) void {
            if (v.ai_pass != 0 or arrowCount(arrows) != 1) return;
            if (!Api.markerAhead(self, t, TF.overtake_probe)) return;
            const d = v.ai_dir & 3;
            const h = dir_heading[d];
            var k: i32 = 1;
            while (k <= 2) : (k += 1) {
                const cell = map.floorCell(self.grid, t.x + fx.cos(h) * k, t.y + fx.sin(h) * k, t.z, T.car_step);
                if (map.groundOf(cell) != map.Ground.road or map.arrowsOf(cell) & dir_arrow[d] == 0) return;
            }
            const sides = [2]i8{ -1, 1 };
            for (sides) |s| {
                const sh = h +% @as(u16, @bitCast(@as(i16, s) * 16384));
                const sx = fx.cos(sh);
                const sy = fx.sin(sh);
                const lane_cell = map.floorCell(self.grid, t.x + sx, t.y + sy, t.z, T.car_step);
                if (map.groundOf(lane_cell) != map.Ground.road or map.arrowsOf(lane_cell) != dir_arrow[d]) continue;
                const near = TF.overtake_side_near;
                const far = TF.overtake_side_far;
                if (Api.bodyNear(self, id, t.x + fx.mul(sx, near), t.y + fx.mul(sy, near), t.z, fx.half)) continue;
                if (Api.bodyNear(self, id, t.x + fx.mul(sx, far), t.y + fx.mul(sy, far), t.z, fx.half)) continue;
                if (Api.bodyNear(self, id, t.x + fx.mul(sx, fx.one) + fx.cos(h) * 2, t.y + fx.mul(sy, fx.one) + fx.sin(h) * 2, t.z, fx.one)) continue;
                v.ai_pass = TF.overtake_ticks;
                v.ai_side = s;
                return;
            }
        }

        /// Any body other than `self_id` within `r` of (x, y)?
        pub fn bodyNear(self: *Self, self_id: EntityId, x: Fx, y: Fx, z: Fx, r: Fx) bool {
            const sc = &self.scratch;
            const ccx: i32 = std.math.clamp(x >> cell_shift, 0, cells_x - 1);
            const ccy: i32 = std.math.clamp(y >> cell_shift, 0, cells_y - 1);
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = ccx + dx;
                    const ny = ccy + dy;
                    if (nx < 0 or ny < 0 or nx >= cells_x or ny >= cells_y) continue;
                    const cell: u32 = @intCast(ny * cells_x + nx);
                    if (sc.cell_stamp[cell] != sc.stamp) continue;
                    var j = sc.cell_head[cell];
                    while (j != nil) : (j = sc.entries[j].next) {
                        const e = sc.entries[j];
                        if (eql(e.id, self_id)) continue;
                        if (fx.abs(e.z - z) > fx.half) continue;
                        if (fx.length(e.x - x, e.y - y) < r + e.r) return true;
                    }
                }
            }
            return false;
        }

        /// A car overlapping this one (circles), if any: the collision the
        /// wiggle reacts to.
        pub fn touchingCar(self: *Self, self_id: EntityId, t: *const c.Transform, v: *const c.Vehicle) ?Self.Entry {
            const sc = &self.scratch;
            const w = &self.state.world;
            const r = T.carModel(v.model).radius;
            const ccx: i32 = std.math.clamp(t.x >> cell_shift, 0, cells_x - 1);
            const ccy: i32 = std.math.clamp(t.y >> cell_shift, 0, cells_y - 1);
            var best: ?Self.Entry = null;
            var best_d: Fx = std.math.maxInt(Fx);
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = ccx + dx;
                    const ny = ccy + dy;
                    if (nx < 0 or ny < 0 or nx >= cells_x or ny >= cells_y) continue;
                    const cell: u32 = @intCast(ny * cells_x + nx);
                    if (sc.cell_stamp[cell] != sc.stamp) continue;
                    var j = sc.cell_head[cell];
                    while (j != nil) : (j = sc.entries[j].next) {
                        const e = sc.entries[j];
                        if (eql(e.id, self_id)) continue;
                        if (fx.abs(e.z - t.z) > fx.half) continue;
                        if (w.get(e.id, c.Vehicle) == null) continue;
                        const d = fx.length(e.x - t.x, e.y - t.y);
                        if (d < fx.mul(r + e.r, TF.touch_ratio) and d < best_d) {
                            best = e;
                            best_d = d;
                        }
                    }
                }
            }
            return best;
        }

        /// Left (1) or right (2), 50/50.
        pub fn turnPick(self: *Self, id: EntityId) u8 {
            return 1 + @as(u8, @truncate(self.randBelow(id, salt_ai_plan, 2)));
        }

        /// Is there road running direction `dir` `dist` blocks ahead?
        pub fn roadAhead(self: *Self, t: *const c.Transform, dir: u8, dist: Fx) bool {
            const h = dir_heading[dir & 3];
            const cell = map.floorCell(self.grid, t.x + fx.mul(fx.cos(h), dist), t.y + fx.mul(fx.sin(h), dist), t.z, T.car_step);
            // A junction cell drawn without arrows lets traffic go any way.
            const a = map.arrowsOf(cell);
            return map.groundOf(cell) == map.Ground.road and (a == 0 or a & dir_arrow[dir & 3] != 0);
        }

        /// Is there a body in the box ahead of a car? (Kept for callers;
        /// the traffic AI uses `probeAhead`.)
        pub fn bodyAhead(self: *Self, self_id: EntityId, t: *const c.Transform, look: Fx) bool {
            const sc = &self.scratch;
            const fwd_x = fx.cos(t.heading);
            const fwd_y = fx.sin(t.heading);
            const cxf = t.x + fx.mul(fwd_x, look >> 1);
            const cyf = t.y + fx.mul(fwd_y, look >> 1);
            const ccx: i32 = std.math.clamp(cxf >> cell_shift, 0, cells_x - 1);
            const ccy: i32 = std.math.clamp(cyf >> cell_shift, 0, cells_y - 1);
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = ccx + dx;
                    const ny = ccy + dy;
                    if (nx < 0 or ny < 0 or nx >= cells_x or ny >= cells_y) continue;
                    const cell: u32 = @intCast(ny * cells_x + nx);
                    if (sc.cell_stamp[cell] != sc.stamp) continue;
                    var j = sc.cell_head[cell];
                    while (j != nil) : (j = sc.entries[j].next) {
                        const e = sc.entries[j];
                        if (eql(e.id, self_id)) continue;
                        if (fx.abs(e.z - t.z) > fx.half) continue;
                        const rx = e.x - t.x;
                        const ry = e.y - t.y;
                        const along = fx.mul(rx, fwd_x) + fx.mul(ry, fwd_y);
                        const side = fx.mul(rx, -fwd_y) + fx.mul(ry, fwd_x);
                        if (along > fx.ratio(3, 10) and along < look and fx.abs(side) < T.traffic_look_side + (e.r >> 1)) return true;
                    }
                }
            }
            return false;
        }
    };
}
