//! Getting in and out of cars, and keeping riders on their car.
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
        const World = Self.World;
        const speedOf = Self.speedOf;

        /// Get into the nearest free car, searching from half a block in
        /// front of the ped; the car must be nearly still.
        pub fn tryEnter(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const t = w.get(ped, c.Transform).?;
            const Best = struct { id: EntityId = .none, d: Fx = T.enter_reach };
            var best: Best = .{};
            const Ctx = struct { best: *Best, x: Fx, y: Fx, z: Fx };
            const ctx = Ctx{ .best = &best, .x = t.x + fx.mul(fx.cos(t.heading), T.enter_ahead), .y = t.y + fx.mul(fx.sin(t.heading), T.enter_ahead), .z = t.z };
            w.each(.{ c.Vehicle, c.Transform, c.Velocity }, ctx, struct {
                fn f(cx: Ctx, id: EntityId, v: *c.Vehicle, ct: *c.Transform, vel: *c.Velocity) void {
                    if (!v.driver.isNone() or v.flags & c.Vehicle.flag_wrecked != 0) return;
                    if (fx.abs(ct.z - cx.z) > fx.half) return;
                    if (speedOf(vel) >= T.enter_max_speed) return;
                    const d = fx.length(ct.x - cx.x, ct.y - cx.y);
                    if (d < cx.best.d) cx.best.* = .{ .id = id, .d = d };
                }
            }.f);
            if (best.id.isNone() or !self.writable(best.id)) return;
            self.board(ped, best.id);
        }

        pub fn board(self: *Self, ped: EntityId, car: EntityId) void {
            const w = &self.state.world;
            const ctl = w.get(ped, c.Controller).?;
            w.get(ped, c.Riding).?.vehicle = car;
            w.get(ped, c.Collider).?.flags = c.Collider.flag_disabled;
            w.get(ped, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            const pd = w.get(ped, c.Pedestrian).?;
            pd.anim = c.Pedestrian.anim_stand;
            pd.turn = 0;
            pd.jump = 0;
            const veh = w.get(car, c.Vehicle).?;
            // Taking a car from traffic is a hijack: its value in points
            // (scoring.md 3.3).
            if (veh.flags & c.Vehicle.flag_ai != 0 and ctl.player != c.Controller.no_player) self.addPoints(@intCast(ctl.player), T.carModel(veh.model).value);
            veh.driver = ped;
            veh.flags &= ~c.Vehicle.flag_ai;
            veh.timer = 0;
            const cc = w.get(car, c.Controller).?;
            cc.player = ctl.player;
            // The held buttons carry over, so holding enter does not
            // immediately leave again.
            cc.prev_buttons = ctl.prev_buttons;
            w.get(ped, c.Transform).?.* = w.get(car, c.Transform).?.*;
            if (ctl.player != c.Controller.no_player) self.state.players[ctl.player].car = car;
            self.scratch.stats.boardings += 1;
        }

        /// Leave on the driver's side (left of travel), else the right, else
        /// stay in. Only once the car is below 0.3 a tick.
        pub fn tryExit(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const car = w.get(ped, c.Riding).?.vehicle;
            const ct = (w.get(car, c.Transform) orelse return).*;
            if (speedOf(w.get(car, c.Velocity).?) >= T.exit_max_speed) return;
            const m = T.carModel(w.get(car, c.Vehicle).?.model);
            const off = m.half_wid + T.ped_radius + fx.ratio(1, 10);
            const sides = [2]u16{ ct.heading -% 16384, ct.heading +% 16384 };
            for (sides) |side| {
                const x = ct.x + fx.mul(fx.cos(side), off);
                const y = ct.y + fx.mul(fx.sin(side), off);
                const z = map.floorAt(self.grid, x, y, ct.z, T.ped_step);
                if (z < ct.z - T.snap_down) continue;
                if (self.circleBlocked(x, y, z, T.ped_radius, T.ped_step)) continue;
                self.releaseCar(car);
                const t = w.get(ped, c.Transform).?;
                t.* = .{ .x = x, .y = y, .z = z, .heading = ct.heading };
                w.get(ped, c.Riding).?.vehicle = .none;
                w.get(ped, c.Collider).?.flags = c.Collider.flag_grounded;
                w.get(ped, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
                const ctl = w.get(ped, c.Controller).?;
                if (ctl.player != c.Controller.no_player) self.state.players[ctl.player].car = .none;
                self.scratch.stats.exits += 1;
                return;
            }
        }

        /// The car loses its driver and its controls go neutral.
        pub fn releaseCar(self: *Self, car: EntityId) void {
            const w = &self.state.world;
            if (w.get(car, c.Vehicle)) |v| v.driver = .none;
            if (w.get(car, c.Controller)) |cc| cc.* = .{ .player = c.Controller.no_player, .prev_buttons = 0, .in = Frame.neutral(0) };
        }

        /// Riders follow their vehicle.
        pub fn sysRiders(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Riding, c.Transform }, self.predicting(), &self.state.world, struct {
                fn f(w: *World, _: EntityId, ride: *c.Riding, t: *c.Transform) void {
                    if (ride.vehicle.isNone()) return;
                    if (w.get(ride.vehicle, c.Transform)) |ct| t.* = ct.* else ride.vehicle = .none;
                }
            }.f);
        }
    };
}
