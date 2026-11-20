//! Traffic: lane following and junctions (traffic-and-car-ai.md).
//! Methods of `Sim(cfg)`, aliased in `sim.zig`; `step()` there calls the
//! systems in their fixed order.

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

pub fn Sys(comptime Self: type) type {
    return struct {
        const nil = Self.nil;
        const cell_shift = Self.cell_shift;
        const cells_x = Self.cells_x;
        const cells_y = Self.cells_y;

        pub const dir_heading = [4]u16{ 0, 16384, 32768, 49152 };

        pub const dir_arrow = [4]u4{ map.Arrow.pos_x, map.Arrow.pos_y, map.Arrow.neg_x, map.Arrow.neg_y };

        pub fn arrowCount(a: u4) u32 {
            return @popCount(a);
        }

        /// Traffic (traffic-and-car-ai.md) drives along the lane arrows, goes
        /// straight on at junctions where it can (else a 50/50 left or right
        /// pick, made once), keeps to the middle of its lane, ramps its speed
        /// setting toward 0.1 a tick, brakes for anything 1.75 blocks ahead
        /// (1 while turning), halts for 100 ticks after hitting someone and
        /// backs out when stuck.
        pub fn sysTrafficAi(self: *Self) void {
            if (self.predicting()) return; // traffic is never predicted
            self.buildBroadphase();
            self.state.world.each(.{ c.Vehicle, c.Controller, c.Transform, c.Velocity }, self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity) void {
                    if (v.flags & c.Vehicle.flag_ai == 0 or !v.driver.isNone()) return;
                    if (v.flags & (c.Vehicle.flag_wrecked | c.Vehicle.flag_burning) != 0) {
                        // A burning car stops; its driver has fled.
                        ctl.in = Frame.neutral(0);
                        return;
                    }
                    const fwd_x = fx.cos(t.heading);
                    const fwd_y = fx.sin(t.heading);
                    const vf = fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y);
                    if (v.halt > 0) {
                        // Forced stop: brake, with the handbrake above 0.05.
                        v.halt -= 1;
                        v.ai_speed = 0;
                        const hb: u16 = if (vf > fx.ratio(5, 100)) Button.handbrake_jump else 0;
                        ctl.in = .{ .steer = 0, .throttle = if (vf > fx.ratio(1, 100)) -127 else 0, .buttons = hb, .aim = 0, .seq = 0 };
                        return;
                    }
                    const cell = map.floorCell(sim.grid, t.x, t.y, t.z, T.car_step);
                    const arrows = map.arrowsOf(cell);
                    const on_road = map.groundOf(cell) == map.Ground.road;
                    const lane = on_road and arrowCount(arrows) == 1;
                    if (lane) {
                        var d: u8 = 0;
                        while (dir_arrow[d] != arrows) : (d += 1) {}
                        v.ai_dir = d;
                        v.ai_plan &= ~c.Vehicle.plan_in_junction;
                    } else if (on_road) {
                        const straight = sim.roadAhead(t, v.ai_dir, T.traffic_junction_probe);
                        if (v.ai_plan & c.Vehicle.plan_in_junction == 0) {
                            // Entering a junction: straight on if the road
                            // goes on, else left or right.
                            v.ai_plan = c.Vehicle.plan_in_junction | (if (straight) 0 else sim.turnPick(id));
                        } else if (v.ai_plan & 3 == 0 and !straight) {
                            v.ai_plan = c.Vehicle.plan_in_junction | sim.turnPick(id);
                        }
                        const plan = v.ai_plan & 3;
                        if (plan != 0) {
                            const nd: u8 = if (plan == 1) (v.ai_dir + 1) & 3 else (v.ai_dir + 3) & 3;
                            if (arrows & dir_arrow[nd] != 0) {
                                v.ai_dir = nd;
                                v.ai_plan = c.Vehicle.plan_in_junction;
                            } else {
                                // Turn when the lane beside us runs the new way.
                                const px = t.x + fx.mul(fx.cos(dir_heading[nd]), fx.one);
                                const py = t.y + fx.mul(fx.sin(dir_heading[nd]), fx.one);
                                const side = map.floorCell(sim.grid, px, py, t.z, T.car_step);
                                if (map.groundOf(side) == map.Ground.road and map.arrowsOf(side) == dir_arrow[nd]) {
                                    v.ai_dir = nd;
                                    v.ai_plan = c.Vehicle.plan_in_junction;
                                }
                            }
                        }
                    }
                    const want = dir_heading[v.ai_dir & 3];
                    // Lane centring: aim at the middle of the cell across the
                    // direction of travel.
                    var target = want;
                    if (lane) {
                        const across = if (v.ai_dir & 1 == 0) t.y else t.x;
                        const off = (across & (fx.one - 1)) - fx.half; // -0.5..0.5
                        // Positive offset is +y (or +x); steer back against it.
                        const sign: i32 = switch (v.ai_dir & 3) {
                            0 => -1,
                            1 => 1,
                            2 => 1,
                            else => -1,
                        };
                        const corr = std.math.clamp(@divTrunc(off * 6000 * sign, fx.one), -3000, 3000);
                        target = want +% @as(u16, @truncate(@as(u32, @bitCast(corr))));
                    }
                    const diff: i16 = @bitCast(target -% t.heading);
                    var steer = std.math.clamp(@divTrunc(@as(i32, diff) * 127, 3500), -127, 127);
                    const turning = @abs(@as(i32, diff)) > 6000;
                    const blocked = sim.bodyAhead(id, t, if (turning) T.traffic_look_turning else T.traffic_look);
                    // The speed setting ramps toward the target: up by 0.01
                    // a tick, down by 0.08.
                    const goal: Fx = if (blocked) 0 else T.traffic_speed;
                    var sp: Fx = v.ai_speed;
                    sp = if (sp < goal) @min(sp + T.traffic_accel, goal) else @max(sp - T.traffic_decel, goal);
                    v.ai_speed = @intCast(sp);
                    var throttle: i32 = if (vf < sp) 100 else if (vf > sp + fx.ratio(2, 100)) -127 else 0;
                    var buttons: u16 = 0;
                    if (blocked) {
                        if (vf > T.traffic_handbrake_speed) buttons = Button.handbrake_jump;
                        if (v.timer < c.Vehicle.reverse_base) v.timer = 0;
                    }
                    // Stuck against a wall: back out with the wheels turned
                    // the other way.
                    if (v.timer >= c.Vehicle.reverse_base) {
                        v.timer -= 1;
                        if (v.timer == c.Vehicle.reverse_base) v.timer = 0;
                        throttle = -110;
                        steer = -steer;
                    } else if (!blocked and fx.abs(vf) < fx.ratio(1, 100)) {
                        v.timer += 1;
                        if (v.timer >= T.traffic_stuck_ticks) v.timer = c.Vehicle.reverse_base + T.traffic_reverse_ticks;
                    } else if (!blocked) v.timer = 0;
                    ctl.in = .{ .steer = @intCast(steer), .throttle = @intCast(throttle), .buttons = buttons, .aim = 0, .seq = 0 };
                }
            }.f);
        }

        /// Left (1) or right (2), 50/50.
        pub fn turnPick(self: *Self, id: EntityId) u8 {
            return 1 + @as(u8, @truncate(self.randBelow(id, salt_ai_plan, 2)));
        }

        /// Is there road running direction `dir` `dist` blocks ahead?
        pub fn roadAhead(self: *Self, t: *const c.Transform, dir: u8, dist: Fx) bool {
            const h = dir_heading[dir & 3];
            const cell = map.floorCell(self.grid, t.x + fx.mul(fx.cos(h), dist), t.y + fx.mul(fx.sin(h), dist), t.z, T.car_step);
            return map.groundOf(cell) == map.Ground.road and map.arrowsOf(cell) & dir_arrow[dir & 3] != 0;
        }

        /// Is there a body in the box ahead of a car?
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
