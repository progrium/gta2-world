//! Roadblocks (single player, police-ai.md 3.4). Owner: workstream E.
//!
//! The traffic spawner (F) asks `tryRoadblock` before it places a plain
//! car off-screen; at three stars or more, with a free slot and the
//! cooldown run out, the roadblock goes up at that spot instead: the road's
//! width is measured across the lane, every other lane gets a parked
//! vehicle with its lights on, the lanes between get two barriers and,
//! every other time, a guard. Army roadblocks are tanks only, with the last
//! lane left open. A roadblock is torn down once it has been out of sight
//! for a while and the player is well away.

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
const TP = @import("../tuning/police.zig");
const route = @import("route.zig");

/// One roadblock, in `police.State.roadblocks`.
pub const Roadblock = extern struct {
    cars: [TP.roadblock_max_cars]EntityId = @splat(.none),
    guards: [TP.roadblock_max_guards]EntityId = @splat(.none),
    barriers: [TP.roadblock_max_barriers]EntityId = @splat(.none),
    /// Centre block of the roadblock.
    bx: i16 = 0,
    by: i16 = 0,
    /// Ticks since any part of it was in a player's sight.
    unseen: u16 = 0,
    active: u8 = 0,
    /// The pursued player.
    slot: u8 = 0,
};

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;
        const crew = Self.police.crew;

        fn blocks(self: *Self) *[TP.max_roadblocks]Roadblock {
            return &self.state.sp.police.roadblocks;
        }

        /// The highest-tier pursuit at three stars or more, if any.
        fn hotSlot(self: *Self) ?u8 {
            var best: ?u8 = null;
            var tier: u8 = 0;
            for (0..cfg.max_players) |i| {
                const s = &self.state.sp.wanted[i];
                if (s.tier >= TP.roadblock_min_stars and s.tier > tier) {
                    tier = s.tier;
                    best = @intCast(i);
                }
            }
            return best;
        }

        /// The traffic spawner is about to place a plain car at block (bx,
        /// by) on level `l`, along lane direction `dir` (0 +x, 1 +y, 2 -x,
        /// 3 -y). Returns true if a roadblock went up there instead (place
        /// no car then).
        pub fn tryRoadblock(self: *Self, bx: i32, by: i32, l: i32, dir: u2) bool {
            const pol = &self.state.sp.police;
            if (pol.roadblock_cooldown > 0) return false;
            const slot = hotSlot(self) orelse return false;
            const rb = for (blocks(self)) |*r| {
                if (r.active == 0) break r;
            } else return false;
            pol.roadblock_cooldown = TP.roadblock_cooldown;
            // Measure the road across the lane.
            const ax: i32 = route.step_y[dir];
            const ay: i32 = -route.step_x[dir];
            var lo: i32 = 0;
            while (lo > -TP.roadblock_max_lanes and route.roadAt(self.grid, bx + ax * (lo - 1), by + ay * (lo - 1), l)) lo -= 1;
            var hi: i32 = 0;
            while (hi < TP.roadblock_max_lanes and route.roadAt(self.grid, bx + ax * (hi + 1), by + ay * (hi + 1), l)) hi += 1;
            const lanes = hi - lo + 1;
            if (lanes > TP.roadblock_max_lanes) return false;
            if (route.roadAt(self.grid, bx + ax * (lo - 1), by + ay * (lo - 1), l) or route.roadAt(self.grid, bx + ax * (hi + 1), by + ay * (hi + 1), l)) return false;
            build(self, rb, slot, bx, by, l, dir, lo, hi);
            return true;
        }

        fn build(self: *Self, rb: *Roadblock, slot: u8, bx: i32, by: i32, l: i32, dir: u2, lo: i32, hi: i32) void {
            const s = &self.state.sp.wanted[slot];
            const army = s.tier >= 6;
            const fbi = s.tier == 5;
            const kind: u8 = @intFromEnum(if (army) ids.Occupation.army else if (fbi) ids.Occupation.fbi else ids.Occupation.police);
            const model = crew.modelFor(kind);
            rb.* = .{ .bx = @intCast(bx), .by = @intCast(by), .active = 1, .slot = slot };
            const ax: i32 = route.step_y[dir];
            const ay: i32 = -route.step_x[dir];
            // Vehicles stand across the lane.
            const heading: u16 = @as(u16, dir) *% 16384 +% 16384;
            var nc: usize = 0;
            var ng: usize = 0;
            var nb: usize = 0;
            var guard_next = true;
            var lane = lo;
            while (lane <= hi) : (lane += 1) {
                const x = bx + ax * lane;
                const y = by + ay * lane;
                const cx = fx.fromInt(x) + fx.half;
                const cy = fx.fromInt(y) + fx.half;
                const vehicle_lane = @mod(lane - lo, 2) == 0;
                if (vehicle_lane or army) {
                    if (army and lane == hi) continue; // the gap on the last lane
                    if (nc >= TP.roadblock_max_cars) continue;
                    const car = self.spawnCarAt(cx, cy, heading, model) orelse continue;
                    if (comptime Self.Car.has(c.CarTask)) self.state.world.get(car, c.CarTask).?.* = .{};
                    Self.car_tasks.setCarTask(self, car, .stop, .none, 0, 0);
                    self.state.world.get(car, c.Vehicle).?.ai_flags |= c.Vehicle.ai_emergency | c.Vehicle.ai_script;
                    rb.cars[nc] = car;
                    nc += 1;
                    continue;
                }
                // Between vehicles: two barriers and, every other time, a
                // guard (ours for the coin flip: it alternates).
                const along_x = fx.mul(fx.cos(@as(u16, dir) *% 16384), fx.ratio(1, 4));
                const along_y = fx.mul(fx.sin(@as(u16, dir) *% 16384), fx.ratio(1, 4));
                for ([2]i32{ -1, 1 }) |sgn| {
                    if (nb >= TP.roadblock_max_barriers) break;
                    if (Self.objects.spawnObject(self, .barrier, TP.barrier_model, cx + along_x * sgn, cy + along_y * sgn, fx.fromInt(l + 1), heading)) |b| {
                        rb.barriers[nb] = b;
                        nb += 1;
                    }
                }
                if (guard_next and ng < TP.roadblock_max_guards) {
                    const t: c.Transform = .{ .x = cx, .y = cy, .z = fx.fromInt(l + 1), .heading = heading };
                    if (crew.spawnOfficer(self, kind, TP.police_hp, if (fbi) T.weapon_smg else T.weapon_pistol, &t)) |g| {
                        self.state.world.get(g, c.Transform).?.z = map.floorAt(self.grid, cx, cy, t.z, T.ped_step);
                        Self.objectives.setObjective(self, g, .{ .kind = .guard, .x = cx, .y = cy });
                        rb.guards[ng] = g;
                        ng += 1;
                    }
                }
                guard_next = !guard_next;
            }
            for (rb.cars) |car| if (!car.isNone()) crew.siren(self, car, true);
        }

        fn anySeen(self: *Self, rb: *const Roadblock) bool {
            const w = &self.state.world;
            const parts = rb.cars ++ rb.guards ++ rb.barriers;
            for (parts) |id| {
                if (id.isNone() or !w.isAlive(id)) continue;
                const t = w.get(id, c.Transform) orelse continue;
                if (Self.car_tasks.seenByPlayer(self, fx.toInt(t.x), fx.toInt(t.y))) return true;
            }
            return false;
        }

        fn playerFar(self: *Self, rb: *const Roadblock) bool {
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                const t = self.state.world.get(row.car, c.Transform) orelse self.state.world.get(row.ped, c.Transform) orelse continue;
                if (@max(@abs(fx.toInt(t.x) - rb.bx), @abs(fx.toInt(t.y) - rb.by)) < TP.roadblock_far) return false;
            }
            return true;
        }

        /// Take a roadblock down: its cars and guards go, barriers too.
        pub fn tearDown(self: *Self, rb: *Roadblock) void {
            const w = &self.state.world;
            for (rb.cars) |id| if (!id.isNone() and w.isAlive(id)) w.despawn(id);
            for (rb.guards) |id| if (!id.isNone() and w.isAlive(id)) w.despawn(id);
            for (rb.barriers) |id| if (!id.isNone() and w.isAlive(id)) Self.objects.removeObject(self, id);
            rb.* = .{};
        }

        /// Upkeep, once a tick: cooldown, and teardown once unseen and far.
        pub fn upkeep(self: *Self) void {
            const pol = &self.state.sp.police;
            if (pol.roadblock_cooldown > 0) pol.roadblock_cooldown -= 1;
            for (blocks(self)) |*rb| {
                if (rb.active == 0) continue;
                if (anySeen(self, rb)) {
                    rb.unseen = 0;
                    continue;
                }
                rb.unseen +|= 1;
                if (rb.unseen >= TP.roadblock_unseen_ticks and playerFar(self, rb)) tearDown(self, rb);
            }
        }

        /// Is `car` a roadblock vehicle?
        pub fn ownsCar(self: *Self, car: EntityId) bool {
            for (blocks(self)) |*rb| {
                if (rb.active == 0) continue;
                for (rb.cars) |id| if (eql(id, car)) return true;
            }
            return false;
        }
    };
}
