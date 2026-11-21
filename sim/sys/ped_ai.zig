//! Ambient pedestrians: wandering on pavements.
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
const salt_ai_timer = prelude.salt_ai_timer;
const salt_ai_turn = prelude.salt_ai_turn;

pub fn Sys(comptime Self: type) type {
    return struct {
        /// Ambient peds wander on pavements: walk a heading for a while, turn
        /// now and then, and turn away from roads and walls. In single
        /// player a ped whose objectives steered it this tick
        /// (`ai/objectives.zig`) is left alone.
        pub fn sysPedAi(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Controller, c.Transform }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, ped: *c.Pedestrian, ctl: *c.Controller, t: *c.Transform) void {
                    if (ctl.player != c.Controller.no_player) return;
                    if (comptime Self.Ped.has(c.Objective)) {
                        if (sim.state.world.get(id, c.Objective).?.flags & c.Objective.flag_steered != 0) return;
                    }
                    // Look one step ahead: road or no floor means turn round.
                    const ax = t.x + fx.mul(fx.cos(ped.ai_heading), fx.ratio(6, 10));
                    const ay = t.y + fx.mul(fx.sin(ped.ai_heading), fx.ratio(6, 10));
                    const ahead = map.floorCell(sim.grid, ax, ay, t.z, T.ped_step);
                    const bad = map.groundOf(ahead) != map.Ground.pavement or map.shapeOf(ahead) == map.Shape.water or
                        map.floorAt(sim.grid, ax, ay, t.z, T.ped_step) < t.z - T.snap_down;
                    if (ped.ai_timer == 0 or bad) {
                        ped.ai_timer = @intCast(30 + sim.randBelow(id, salt_ai_timer, 120));
                        const turn: u16 = if (bad) 32768 else @truncate(sim.randBelow(id, salt_ai_turn, 32768));
                        ped.ai_heading = ped.ai_heading +% turn -% @as(u16, if (bad) 0 else 16384);
                    } else ped.ai_timer -= 1;
                    ctl.in = .{ .steer = 0, .throttle = 90, .buttons = Button.direct, .aim = ped.ai_heading, .seq = 0 };
                }
            }.f);
        }
    };
}
