//! Keeping ambient cars and peds near the players.
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

        /// Ambient cars and peds far from every player are moved near one.
        pub fn sysAmbient(self: *Self) void {
            if (self.predicting()) return;
            const w = &self.state.world;
            var pos: [cfg.max_players][2]i32 = undefined;
            var n: u32 = 0;
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                const t = w.get(row.car, c.Transform) orelse w.get(row.ped, c.Transform) orelse continue;
                pos[n] = .{ fx.toInt(t.x), fx.toInt(t.y) };
                n += 1;
            }
            if (n == 0) return;
            const Ctx = struct { sim: *Self, pos: []const [2]i32, moved: u32 = 0 };
            var ctx = Ctx{ .sim = self, .pos = pos[0..n] };
            // One in eight entities is looked at each tick, by index.
            w.each(.{ c.Vehicle, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, v: *c.Vehicle, t: *c.Transform) void {
                    if (cx.moved >= T.ambient_moves_per_tick) return;
                    if ((id.index() ^ cx.sim.state.tick) & 7 != 0) return;
                    if (!v.driver.isNone() or v.flags & c.Vehicle.flag_wrecked != 0) return;
                    // Script and task cars stay where they are.
                    if (v.ai_flags & c.Vehicle.ai_script != 0) return;
                    if (cx.sim.state.world.get(id, c.CarTask)) |ct| if (ct.task != 0) return;
                    if (cx.sim.state.world.get(id, c.ScriptTag)) |tag| if (tag.handle != 0) return;
                    if (!farFromAll(cx.pos, t)) return;
                    const sim = cx.sim;
                    // Single player: a car with a passenger but no driver
                    // (a police crew's) stays.
                    if (comptime Self.single_player) if (Self.spawn.hasRider(sim, id)) return;
                    const o = sim.randomPlayerBlock(id) orelse return;
                    const driving = v.flags & c.Vehicle.flag_ai != 0;
                    if (sim.spawnAmbientCar(driving, .{ .x = o.x, .y = o.y }) == null) return;
                    sim.state.world.despawn(id);
                    sim.scratch.stats.ambient_moved += 1;
                    cx.moved += 1;
                }
            }.f);
            w.each(.{ c.Pedestrian, c.Controller, c.Transform, c.Riding }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, _: *c.Pedestrian, ctl: *c.Controller, t: *c.Transform, r: *c.Riding) void {
                    if (cx.moved >= T.ambient_moves_per_tick) return;
                    if ((id.index() ^ cx.sim.state.tick) & 7 != 0) return;
                    if (ctl.player != c.Controller.no_player or !r.vehicle.isNone()) return;
                    // Script peds stay where they are.
                    if (cx.sim.state.world.get(id, c.ScriptTag)) |tag| if (tag.handle != 0) return;
                    if (!farFromAll(cx.pos, t)) return;
                    const sim = cx.sim;
                    const o = sim.randomPlayerBlock(id) orelse return;
                    const spot = sim.findSpotNear(id, map.Ground.pavement, T.ped_radius, o.x, o.y, T.ambient_near_radius, T.ambient_near_min) orelse return;
                    t.* = .{ .x = spot.x, .y = spot.y, .z = spot.z, .heading = spot.heading };
                    const w2 = &sim.state.world;
                    w2.get(id, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
                    w2.get(id, c.Pedestrian).?.ai_heading = spot.heading;
                    sim.scratch.stats.ambient_moved += 1;
                    cx.moved += 1;
                }
            }.f);
        }

        pub fn farFromAll(pos: []const [2]i32, t: *const c.Transform) bool {
            const x = fx.toInt(t.x);
            const y = fx.toInt(t.y);
            for (pos) |p| {
                if (@max(@abs(p[0] - x), @abs(p[1] - y)) < T.ambient_far) return false;
            }
            return true;
        }
    };
}
