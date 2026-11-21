//! Special surfaces: deep water (car-height.md 3.5, ped-movement.md 3.7),
//! electrified floors (ped-movement.md 3.7) and oil slicks (car-handling.md).
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

/// `abi.rand` salt for the oil spin direction (C's range, ids.zig).
const salt_oil_dir: u32 = 0x1200;

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
            // Anyone else riding on it sinks too (car-height.md 3.5).
            const Ctx = struct { sim: *Self, car: EntityId, t: c.Transform };
            w.each(.{ c.Riding, c.Health }, Ctx{ .sim = self, .car = id, .t = t.* }, struct {
                fn f(cx: Ctx, rid: EntityId, r: *c.Riding, rh: *c.Health) void {
                    if (!eql(r.vehicle, cx.car)) return;
                    const ww = &cx.sim.state.world;
                    r.vehicle = .none;
                    if (ww.get(rid, c.Collider)) |col| col.flags = c.Collider.flag_grounded;
                    if (ww.get(rid, c.Transform)) |rt| rt.* = cx.t;
                    if (ww.get(rid, c.Pedestrian)) |p| {
                        p.flags |= c.Pedestrian.flag_drowned;
                        if (p.hit_age > T.drown_credit_ticks) rh.last_hit_by = .none;
                    }
                    rh.hp = 0;
                }
            }.f);
            if (v.flags & c.Vehicle.flag_wrecked == 0) self.scoreWreck(v, by);
            self.scratch.stats.car_wrecks += 1;
            self.releaseCar(id);
            w.despawn(id);
            if (cfg.ambient_cars > 0) _ = self.spawnAmbientCar(true, self.randomPlayerBlock(id));
        }

        /// A car runs onto an oil slick (car-handling.md, Oil slick): unless
        /// it is already spinning, it picks a spin direction and spins for
        /// `oil_ticks`, taking `oil_damage`. For the oil object (B) and the
        /// oil car weapon (G) to call as `Self.surfaces.oilCar(sim, car, by)`.
        /// Trains are exempt (none exist yet).
        pub fn oilCar(self: *Self, id: EntityId, by: EntityId) void {
            if (!self.writable(id)) return;
            const v = self.state.world.get(id, c.Vehicle) orelse return;
            if (v.oil > 0) return;
            v.oil = T.oil_ticks;
            v.oil_dir = @intCast(self.randBelow(id, salt_oil_dir, 2));
            self.damageCar(id, T.oil_damage, by);
        }

        /// Electrified floors (ped-movement.md 3.7): a ped on foot standing
        /// on an electrified lid adds `electric_floor_shock` to his shock
        /// counter each tick, except mid-jump. The counter's decay and the
        /// kill at its threshold are in `sysPedStatus` (explosions-and-
        /// damage.md 3.8), which credits a recent attacker. Deep water is
        /// handled during movement (`carWater`) and in `sysPedStatus`.
        pub fn sysSurfaces(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Riding, c.Transform, c.Collider }, self.predicting(), self, struct {
                fn f(sim: *Self, _: EntityId, p: *c.Pedestrian, r: *c.Riding, t: *c.Transform, col: *c.Collider) void {
                    if (sim.predicting()) return; // damage comes from the server
                    if (!r.vehicle.isNone() or p.jump > 0) return;
                    if (col.flags & c.Collider.flag_grounded == 0 or col.flags & c.Collider.flag_disabled != 0) return;
                    if (map.floorSurface(sim.grid, t.x, t.y, t.z, fx.ratio(1, 16)) & map.Surface.electrified == 0) return;
                    p.shock +|= T.electric_floor_shock;
                }
            }.f);
        }
    };
}
