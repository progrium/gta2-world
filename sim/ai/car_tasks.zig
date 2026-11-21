//! Car tasks (single player): chase, follow, patrol, go to, park, stop
//! (traffic-and-car-ai.md 3.7). Owner: workstream F; A2 and E call this
//! API.
//!
//! A task car drives with the ordinary traffic rules (`sys/traffic.zig`),
//! fed by `driveOf` instead of the lane arrows: the route planner's
//! direction (`ai/route.zig`) or, close to a chase or follow target, the
//! bearing to it; a speed cap from the task (the driver's preferred speed);
//! its own target never counts as an obstacle, and close behind it the car
//! matches its speed. `sysCarTasks` keeps the bookkeeping: re-planning the
//! route (a bounded number of plans a tick), arrival, and the off-road
//! snap to the nearest road out of every player's sight (police-ai.md 3.1:
//! 100 or 300 ticks).
//!
//! Ours where the note is silent: what follow and patrol do differently
//! from chase (follow keeps a gap behind, patrol wanders once at its point
//! and routes back when it strays), arrival distances, default speeds,
//! and that a chase or follow whose target is gone reverts to ordinary
//! traffic. Park in garage drives to the point and stops until the garage
//! note lands.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const TF = @import("../tuning/traffic.zig");
const route = @import("route.zig");

pub const Task = enum(u8) { none = 0, wander = 1, chase = 2, follow = 3, patrol = 4, go_to = 5, park_in_garage = 6, stop = 7, _ };

/// Options for `setCarTaskOpts`.
pub const TaskOpts = struct {
    /// Preferred speed in fx blocks a tick (the driver's stat), 0 for the
    /// task's default; capped at 0.7.
    speed: Fx = 0,
    /// Snap to the road after 100 ticks off it, not 300 (cop cars, or any
    /// car at three stars or more).
    fast_snap: bool = false,
    /// The target is a ped to kill: never slow for it.
    kill_target: bool = false,
};

/// What the traffic AI drives a task car by this tick (`driveOf`).
pub const Drive = struct {
    /// Routed road direction (0 +x, 1 +y, 2 -x, 3 -y), if any.
    dir: ?u2 = null,
    /// Steer straight at this heading instead (close to the target).
    heading: ?u16 = null,
    /// The speed setting's target.
    speed: Fx,
    /// Never an obstacle.
    target: EntityId = .none,
    /// A ped target that is also not an obstacle (kill tasks).
    exempt_ped: EntityId = .none,
    /// Close behind the target: match this forward speed.
    match: ?Fx = null,
    /// Brake and hold (stop task, or arrived at a go-to point).
    hold: bool = false,
};

inline fn pack(x: i32, y: i32, l: i32) u32 {
    return (@as(u32, @intCast(x & 0xFF)) | (@as(u32, @intCast(y & 0xFF)) << 8) | (@as(u32, @intCast(l & 0xFF)) << 16)) + 1;
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const Api = @This();
        /// Give a car a task toward `target` (an entity) or (x, y). The car
        /// is put under AI control unless a player drives it; `.none`
        /// returns it to ordinary traffic.
        pub fn setCarTask(self: *Self, car: EntityId, task: Task, target: EntityId, x: Fx, y: Fx) void {
            const w = &self.state.world;
            const ct = w.get(car, c.CarTask) orelse return;
            const keep_speed = ct.speed;
            const keep_flags = ct.flags & (c.CarTask.flag_fast_snap | c.CarTask.flag_kill_target);
            ct.* = .{ .target = target, .x = x, .y = y, .task = @intFromEnum(task), .speed = keep_speed, .flags = keep_flags };
            if (task == .chase) ct.flags |= c.CarTask.flag_against_flow;
            const v = w.get(car, c.Vehicle) orelse return;
            const ctl = w.get(car, c.Controller) orelse return;
            if (ctl.player == c.Controller.no_player and v.flags & c.Vehicle.flag_wrecked == 0) {
                v.flags |= c.Vehicle.flag_ai;
                v.ai_flags &= ~(c.Vehicle.ai_abandoned | c.Vehicle.ai_halted);
                v.ai_lost = 0;
                if (task == .stop) v.ai_flags |= c.Vehicle.ai_halted;
            }
        }

        /// Speed, snap time and kill-target options for the car's task
        /// (kept across `setCarTask`).
        pub fn setCarTaskOpts(self: *Self, car: EntityId, opts: TaskOpts) void {
            const ct = self.state.world.get(car, c.CarTask) orelse return;
            ct.speed = @intCast(std.math.clamp(opts.speed, 0, TF.traffic_speed_max));
            ct.flags &= ~(c.CarTask.flag_fast_snap | c.CarTask.flag_kill_target);
            if (opts.fast_snap) ct.flags |= c.CarTask.flag_fast_snap;
            if (opts.kill_target) ct.flags |= c.CarTask.flag_kill_target;
        }

        pub fn carTaskOf(self: *const Self, car: EntityId) Task {
            const ct = @constCast(self).state.world.get(car, c.CarTask) orelse return .none;
            return @enumFromInt(ct.task);
        }

        /// Go-to, park and patrol: at the point. Chase and follow: caught
        /// up (within 3 blocks of the target).
        pub fn carArrived(self: *const Self, car: EntityId) bool {
            const ct = @constCast(self).state.world.get(car, c.CarTask) orelse return false;
            return ct.arrived != 0;
        }

        /// Where the task's target is now (its car if it is riding one).
        pub fn targetPos(self: *Self, ct: *const c.CarTask) ?struct { t: c.Transform, vel: ?*c.Velocity, id: EntityId } {
            const w = &self.state.world;
            if (ct.target.isNone()) return .{ .t = .{ .x = ct.x, .y = ct.y, .z = 0, .heading = 0 }, .vel = null, .id = .none };
            var id = ct.target;
            if (w.get(id, c.Riding)) |r| {
                if (!r.vehicle.isNone() and w.get(r.vehicle, c.Transform) != null) id = r.vehicle;
            }
            const t = w.get(id, c.Transform) orelse return null;
            return .{ .t = t.*, .vel = w.get(id, c.Velocity), .id = id };
        }

        /// How the traffic AI should drive `car` this tick, or null for
        /// ordinary traffic (no task, wander, or a patrol on its beat).
        pub fn driveOf(self: *Self, car: EntityId, t: *const c.Transform) ?Drive {
            if (comptime !Self.single_player) return null;
            const ct = self.state.world.get(car, c.CarTask) orelse return null;
            const task: Task = @enumFromInt(ct.task);
            switch (task) {
                .none, .wander => return null,
                .stop => return .{ .speed = 0, .hold = true },
                else => {},
            }
            const tp = Api.targetPos(self, ct) orelse return null;
            const chasing = task == .chase or task == .follow;
            const default_speed = if (chasing) TF.task_chase_speed else TF.task_drive_speed;
            var d: Drive = .{ .speed = if (ct.speed != 0) ct.speed else default_speed, .target = tp.id };
            if (ct.flags & c.CarTask.flag_kill_target != 0) d.exempt_ped = ct.target;
            if (ct.route_dir != c.CarTask.no_dir) {
                d.dir = @intCast(ct.route_dir);
                // Steer at the middle of the route's block two moves on
                // (one on, if the car has already reached the next block
                // and the plan hasn't caught up): the turn starts early
                // and corners are cut, as the AI's steering can't turn
                // inside one block (ours).
                if (ct.route_from != 0) {
                    const f = ct.route_from - 1;
                    var ax: i32 = @intCast(f & 0xFF);
                    var ay: i32 = @intCast((f >> 8) & 0xFF);
                    const dirs = [3]u8{ ct.route_dir, ct.next_dir, ct.third_dir };
                    const ahead = ax + route.step_x[dirs[0] & 3] == fx.toInt(t.x) and ay + route.step_y[dirs[0] & 3] == fx.toInt(t.y);
                    const n: usize = if (ahead) 3 else 2;
                    for (dirs[0..n]) |dd| {
                        if (dd == c.CarTask.no_dir) break;
                        ax += route.step_x[dd & 3];
                        ay += route.step_y[dd & 3];
                    }
                    const px = fx.fromInt(ax) + fx.half;
                    const py = fx.fromInt(ay) + fx.half;
                    if (px != t.x or py != t.y) d.heading = fx.atan2(py - t.y, px - t.x);
                }
                // Slow for a turn here or one block on (ours: the AI's
                // steering doesn't soften with speed).
                const facing: u8 = @intCast(((@as(u32, t.heading) + 8192) >> 14) & 3);
                const turn_next = (ct.next_dir != c.CarTask.no_dir and ct.next_dir != ct.route_dir) or
                    (ct.third_dir != c.CarTask.no_dir and ct.next_dir != c.CarTask.no_dir and ct.third_dir != ct.next_dir);
                if (turn_next or facing != ct.route_dir) d.speed = @min(d.speed, TF.task_turn_speed);
            }
            switch (task) {
                .go_to, .park_in_garage => if (ct.arrived != 0) {
                    d.hold = true;
                    d.speed = 0;
                },
                .patrol => if (ct.arrived != 0) return null,
                .chase, .follow => {
                    const dx = tp.t.x - t.x;
                    const dy = tp.t.y - t.y;
                    const near = @max(@abs(fx.toInt(tp.t.x) - fx.toInt(t.x)), @abs(fx.toInt(tp.t.y) - fx.toInt(t.y))) <= TF.task_direct_blocks;
                    if (near and fx.abs(tp.t.z - t.z) < fx.half) {
                        d.heading = fx.atan2(dy, dx);
                        if (tp.vel) |vel| {
                            // Match the target's speed along our heading.
                            const ts = fx.mul(vel.vx, fx.cos(t.heading)) + fx.mul(vel.vy, fx.sin(t.heading));
                            const dist = fx.length(dx, dy);
                            const gap = if (task == .follow) TF.task_follow_gap else fx.one;
                            var m: Fx = @max(ts, 0);
                            // Close the gap at up to the preferred speed;
                            // inside it, match (or stop for a stopped one).
                            if (dist > gap) m = @min(d.speed, m + fx.mul(dist - gap, fx.ratio(1, 10)));
                            d.match = m;
                        }
                    }
                },
                else => {},
            }
            return d;
        }

        /// Car tasks, once a tick, after the traffic AI: targets, arrival,
        /// route plans (bounded), and the off-road snap.
        pub fn sysCarTasks(self: *Self) void {
            if (comptime !Self.single_player) return;
            if (self.predicting()) return;
            const Ctx = struct { sim: *Self, plans: u32 = 0 };
            var ctx = Ctx{ .sim = self };
            self.state.world.each(.{ c.CarTask, c.Vehicle, c.Transform, c.Velocity }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, ct: *c.CarTask, v: *c.Vehicle, t: *c.Transform, vel: *c.Velocity) void {
                    const sim = cx.sim;
                    const task: Task = @enumFromInt(ct.task);
                    switch (task) {
                        .none, .wander, .stop => return,
                        else => {},
                    }
                    if (v.flags & c.Vehicle.flag_wrecked != 0) return;
                    const tp = Api.targetPos(sim, ct) orelse {
                        // The target is gone: back to ordinary traffic.
                        ct.task = @intFromEnum(Task.none);
                        ct.route_dir = c.CarTask.no_dir;
                        return;
                    };
                    const bx = fx.toInt(t.x);
                    const by = fx.toInt(t.y);
                    const gx = fx.toInt(tp.t.x);
                    const gy = fx.toInt(tp.t.y);
                    const dist = @max(@abs(gx - bx), @abs(gy - by));
                    switch (task) {
                        .go_to, .park_in_garage => if (dist <= TF.task_arrive_blocks) {
                            ct.arrived = 1;
                        },
                        .patrol => {
                            if (dist <= TF.task_arrive_blocks) ct.arrived = 1;
                            if (dist > TF.patrol_leash_blocks) ct.arrived = 0;
                        },
                        .chase, .follow => ct.arrived = @intFromBool(dist <= TF.task_direct_blocks),
                        else => {},
                    }
                    // Off the road: count, then snap out of sight.
                    const l = route.levelUnder(sim.grid, t.x, t.y, t.z, T.car_step);
                    const on_road = route.roadAt(sim.grid, bx, by, l);
                    if (on_road) {
                        ct.lost = 0;
                    } else {
                        ct.lost +|= 1;
                        const wait = if (ct.flags & c.CarTask.flag_fast_snap != 0) TF.task_snap_fast else TF.task_snap_slow;
                        if (ct.lost >= wait and !Api.seenByPlayer(sim, bx, by)) {
                            if (route.nearestRoad(sim.grid, bx, by, l, TF.snap_radius)) |n| {
                                Api.snapTo(sim, id, t, vel, n);
                                ct.lost = 0;
                                ct.timer = 0;
                            }
                        }
                    }
                    // Re-plan on a new block, a new goal, or the timer.
                    if (ct.timer > 0) ct.timer -= 1;
                    if (!on_road) return;
                    const from = pack(bx, by, l);
                    const to = pack(gx, gy, 0);
                    if (ct.route_from == from and ct.route_to == to and ct.timer > 0) return;
                    if (cx.plans >= TF.route_plans_per_tick) return;
                    cx.plans += 1;
                    const facing: u2 = @intCast(((@as(u32, t.heading) + 8192) >> 14) & 3);
                    var opts: route.Opts = .{ .against_flow_south = ct.flags & c.CarTask.flag_against_flow != 0, .facing = facing };
                    const goal = route.nearestRoad(sim.grid, gx, gy, l, TF.route_goal_radius) orelse route.Node{ .x = gx, .y = gy, .l = l };
                    const here: route.Node = .{ .x = bx, .y = by, .l = l };
                    var st = route.plan(sim.grid, here, goal.x, goal.y, opts);
                    if (st == null) {
                        // No way forward without turning round: plan freely.
                        opts.facing = null;
                        st = route.plan(sim.grid, here, goal.x, goal.y, opts);
                    }
                    const dirs: [3]u8 = if (st) |x| x.dirs else .{ route.no_dir, route.no_dir, route.no_dir };
                    ct.route_dir = dirs[0];
                    ct.next_dir = dirs[1];
                    ct.third_dir = dirs[2];
                    ct.route_from = from;
                    ct.route_to = to;
                    ct.timer = TF.route_replan_ticks;
                }
            }.f);
        }

        /// Is block (bx, by) within `offscreen_blocks` of any player?
        pub fn seenByPlayer(self: *Self, bx: i32, by: i32) bool {
            const w = &self.state.world;
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                const pt = w.get(row.car, c.Transform) orelse w.get(row.ped, c.Transform) orelse continue;
                if (@max(@abs(fx.toInt(pt.x) - bx), @abs(fx.toInt(pt.y) - by)) <= TF.offscreen_blocks) return true;
            }
            return false;
        }

        /// Put a car on road cell `n`, facing along its arrow, at rest.
        pub fn snapTo(self: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, n: route.Node) void {
            _ = id;
            const cell = map.cellAt(self.grid, n.x, n.y, n.l);
            const arrows = map.arrowsOf(cell);
            const x = fx.fromInt(n.x) + fx.half;
            const y = fx.fromInt(n.y) + fx.half;
            const z = map.floorAt(self.grid, x, y, fx.fromInt(n.l + 1), T.car_step);
            t.* = .{ .x = x, .y = y, .z = z, .heading = Self.headingFromArrows(arrows, @as(u32, t.heading) >> 14) };
            vel.* = std.mem.zeroes(c.Velocity);
        }
    };
}
