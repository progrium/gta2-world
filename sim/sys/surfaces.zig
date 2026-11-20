//! Special surfaces: deep water (car-height.md 3.5, ped-movement.md 3.7).
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

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;
        const carCorners = Self.carCorners;

        /// Deep water (car-height.md 3.1, 3.5). Partly over it, each corner
        /// on dry ground pushes the car in by (centre - corner) / 50. Fully
        /// over it, the car has no drive or brakes (`flag_in_water`) and,
        /// once at 0.05 a tick or slower, stops and sinks: it shrinks 2
        /// pixels a tick and when its width is gone it is destroyed with
        /// whoever is inside.
        pub fn carWater(self: *Self, id: EntityId, v: *c.Vehicle, t: *c.Transform, vel: *c.Velocity, col: *const c.Collider, m: *const T.CarModel) void {
            v.flags &= ~c.Vehicle.flag_in_water;
            if (col.flags & c.Collider.flag_grounded == 0 or !map.waterAt(self.grid, t.x, t.y, t.z)) {
                v.sink = 0;
                return;
            }
            var push = [2]Fx{ 0, 0 };
            var dry = false;
            for (carCorners(t, m)) |k| {
                if (map.waterAt(self.grid, t.x + k[0], t.y + k[1], t.z)) continue;
                dry = true;
                push[0] -= @divTrunc(k[0], T.car_tip_div);
                push[1] -= @divTrunc(k[1], T.car_tip_div);
            }
            if (dry) {
                v.sink = 0;
                if (!self.boxBlocked(t.x + push[0], t.y + push[1], t.z, t.heading, m)) {
                    t.x += push[0];
                    t.y += push[1];
                }
                return;
            }
            v.flags |= c.Vehicle.flag_in_water;
            if (fx.length(vel.vx, vel.vy) > T.sink_speed) return;
            vel.* = std.mem.zeroes(c.Velocity);
            if (self.predicting()) return;
            v.sink +|= 1;
            const px: i32 = @divTrunc(@min(m.half_wid, m.half_len), fx.one >> 6);
            if (v.sink < @max(1, @divTrunc(px * 2, T.sink_px_per_tick))) return;
            self.sinkCar(id, v, t);
        }

        /// A car has sunk: whoever is inside drowns, credited to whoever
        /// hurt the driver lately, who also scores the car as destroyed.
        pub fn sinkCar(self: *Self, id: EntityId, v: *c.Vehicle, t: *const c.Transform) void {
            const w = &self.state.world;
            var by: EntityId = .none;
            const driver = v.driver;
            if (w.get(driver, c.Riding)) |r| {
                r.vehicle = .none;
                w.get(driver, c.Collider).?.flags = c.Collider.flag_grounded;
                w.get(driver, c.Transform).?.* = t.*;
                if (w.get(driver, c.Controller)) |dc| {
                    if (dc.player != c.Controller.no_player) self.state.players[dc.player].car = .none;
                }
                const dh = w.get(driver, c.Health).?;
                if (w.get(driver, c.Pedestrian)) |p| {
                    p.flags |= c.Pedestrian.flag_drowned;
                    if (p.hit_age <= T.drown_credit_ticks) by = dh.last_hit_by;
                }
                dh.hp = 0;
                dh.last_hit_by = by;
            }
            if (v.flags & c.Vehicle.flag_wrecked == 0) self.scoreWreck(v, by);
            self.scratch.stats.car_wrecks += 1;
            self.releaseCar(id);
            w.despawn(id);
            if (cfg.ambient_cars > 0) _ = self.spawnAmbientCar(true, self.randomPlayerBlock(id));
        }

        /// Electrified floors and other per-tick surface effects (ped-movement.md
        /// 3.7): owner C. W0 stub; deep water is handled during movement.
        pub fn sysSurfaces(self: *Self) void {
            _ = self;
        }
    };
}
