//! Spawning: finding free spots, ambient cars and peds, players.
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
const salt_ambient_player = prelude.salt_ambient_player;
const salt_car_model = prelude.salt_car_model;
const salt_near_x = prelude.salt_near_x;
const salt_near_y = prelude.salt_near_y;
const salt_spawn_x = prelude.salt_spawn_x;
const salt_spawn_y = prelude.salt_spawn_y;

pub fn Sys(comptime Self: type) type {
    return struct {
        const Car = Self.Car;
        const Ped = Self.Ped;
        const Spot = Self.Spot;
        const Block = Self.Block;

        /// Standing height on the highest floor of column (cx, cy), if that
        /// floor is a full block with headroom above it.
        pub fn columnFloor(self: *const Self, cx: i32, cy: i32) ?struct { z: i32, cell: map.Cell } {
            var z: i32 = map.size_z - 2;
            while (z >= 0) : (z -= 1) {
                const cell = map.cellAt(self.grid, cx, cy, z);
                const sh = map.shapeOf(cell);
                if (sh == map.Shape.air) continue;
                if ((sh != map.Shape.solid and sh != map.Shape.slab) or map.codeOf(cell) != 0) return null;
                if (map.shapeOf(map.cellAt(self.grid, cx, cy, z + 1)) != map.Shape.air) return null;
                return .{ .z = z + 1, .cell = cell };
            }
            return null;
        }

        /// A random free spot whose floor has ground type `ground`, keyed on
        /// the entity being spawned.
        pub fn findSpot(self: *Self, key: EntityId, ground: u2, clearance: Fx) ?Spot {
            var attempt: u32 = 0;
            while (attempt < 96) : (attempt += 1) {
                const cx: i32 = @intCast(self.randBelow(key, salt_spawn_x + attempt, map.size_x));
                const cy: i32 = @intCast(self.randBelow(key, salt_spawn_y + attempt, map.size_y));
                const f = self.columnFloor(cx, cy) orelse continue;
                if (map.groundOf(f.cell) != ground) continue;
                const x = fx.fromInt(cx) + fx.half;
                const y = fx.fromInt(cy) + fx.half;
                const z = fx.fromInt(f.z);
                if (self.circleBlocked(x, y, z, clearance, T.ped_step)) continue;
                return .{ .x = x, .y = y, .z = z, .heading = headingFromArrows(map.arrowsOf(f.cell), attempt) };
            }
            return null;
        }

        /// Like `findSpot`, but within `radius` blocks (Chebyshev) of block
        /// (`ox`, `oy`), and at least `min_dist` away from it.
        pub fn findSpotNear(self: *Self, key: EntityId, ground: u2, clearance: Fx, ox: i32, oy: i32, radius: i32, min_dist: i32) ?Spot {
            const span: u32 = @intCast(2 * radius + 1);
            var attempt: u32 = 0;
            while (attempt < 64) : (attempt += 1) {
                const dx = @as(i32, @intCast(self.randBelow(key, salt_near_x + attempt, span))) - radius;
                const dy = @as(i32, @intCast(self.randBelow(key, salt_near_y + attempt, span))) - radius;
                if (@max(@abs(dx), @abs(dy)) < min_dist) continue;
                const cx = ox + dx;
                const cy = oy + dy;
                if (cx < 0 or cy < 0 or cx >= map.size_x or cy >= map.size_y) continue;
                const f = self.columnFloor(cx, cy) orelse continue;
                if (map.groundOf(f.cell) != ground) continue;
                const x = fx.fromInt(cx) + fx.half;
                const y = fx.fromInt(cy) + fx.half;
                const z = fx.fromInt(f.z);
                if (self.circleBlocked(x, y, z, clearance, T.ped_step)) continue;
                return .{ .x = x, .y = y, .z = z, .heading = headingFromArrows(map.arrowsOf(f.cell), attempt) };
            }
            return null;
        }

        /// Block position of the lowest-numbered other active player who has
        /// a body in the world (their car if driving, else their ped).
        pub fn otherPlayerBlock(self: *Self, slot: u32) ?Block {
            const w = &self.state.world;
            for (self.state.players, 0..) |row, i| {
                if (i == slot or row.flags & abi.PlayerRow.flag_active == 0) continue;
                // `get`, not `isAlive`: a ped spawned earlier this tick (players
                // joining together) is not alive until the next applyPending.
                const t = w.get(row.car, c.Transform) orelse w.get(row.ped, c.Transform) orelse continue;
                return .{ .x = fx.toInt(t.x), .y = fx.toInt(t.y) };
            }
            return null;
        }

        pub fn headingFromArrows(arrows: u4, fallback: u32) u16 {
            if (arrows & map.Arrow.pos_x != 0) return 0;
            if (arrows & map.Arrow.pos_y != 0) return 16384;
            if (arrows & map.Arrow.neg_x != 0) return 32768;
            if (arrows & map.Arrow.neg_y != 0) return 49152;
            return @truncate(fallback *% 16384);
        }

        /// An ambient car on a road: traffic if `driving`, else parked. With
        /// `near`, within reach of that block (off screen), else anywhere.
        pub fn spawnAmbientCar(self: *Self, driving: bool, near: ?Block) ?EntityId {
            const w = &self.state.world;
            const id = w.spawn(Car) orelse return null;
            const r = T.carModel(0).radius;
            const found = if (near) |o| self.findSpotNear(id, map.Ground.road, r, o.x, o.y, T.ambient_near_radius, T.ambient_near_min) else self.findSpot(id, map.Ground.road, r);
            const spot = found orelse {
                w.despawn(id);
                return null;
            };
            const model = self.pickAmbientModel(id);
            self.initCar(id, spot, model);
            if (driving) {
                const v = w.get(id, c.Vehicle).?;
                v.flags = c.Vehicle.flag_ai;
                v.ai_dir = @truncate(spot.heading >> 14);
            }
            return id;
        }

        /// A random model allowed as an ambient car (not trains or tanks).
        pub fn pickAmbientModel(self: *Self, id: EntityId) u8 {
            var n: u32 = 0;
            for (T.car_models[0..T.car_model_count]) |m| n += @intCast(m.ambient);
            if (n == 0) return 0;
            var k = self.randBelow(id, salt_car_model, n);
            for (T.car_models[0..T.car_model_count], 0..) |m, i| {
                if (m.ambient == 0) continue;
                if (k == 0) return @intCast(i);
                k -= 1;
            }
            return 0;
        }

        pub fn initCar(self: *Self, id: EntityId, spot: Spot, model: u8) void {
            const w = &self.state.world;
            w.get(id, c.Transform).?.* = .{ .x = spot.x, .y = spot.y, .z = spot.z, .heading = spot.heading };
            w.get(id, c.Collider).?.flags = c.Collider.flag_grounded;
            w.get(id, c.Health).?.* = .{ .hp = T.car_damage_max, .last_hit_by = .none };
            w.get(id, c.Controller).?.* = .{ .player = c.Controller.no_player, .prev_buttons = 0, .in = Frame.neutral(0) };
            w.get(id, c.Vehicle).?.* = .{ .driver = .none, .model = model, .pedal = 0, .steer = 0, .flags = 0, .timer = 0, .ai_dir = 0, .ai_plan = 0, .halt = 0, .ai_speed = 0, .brake = 0, .handbrake_n = 0, .drive = 0 };
            w.get(id, c.Appearance).?.* = .{ .sprite = @intCast(T.carModel(model).sprite), .remap = c.Appearance.no_remap };
            // Single player: the spawn zeroes components, so set the SP
            // ones to their defaults (no target, no route).
            if (comptime Car.has(c.CarTask)) w.get(id, c.CarTask).?.* = .{};
            if (comptime Car.has(c.ScriptTag)) w.get(id, c.ScriptTag).?.* = .{};
        }

        /// Spawn a ped for `player` (or an ambient ped for no_player).
        pub fn spawnPed(self: *Self, player: u32, hint: u32) ?EntityId {
            const w = &self.state.world;
            const id = w.spawn(Ped) orelse return null;
            var spot: ?Spot = null;
            if (hint != 0) {
                const cx: i32 = @intCast(hint & 0xFF);
                const cy: i32 = @intCast((hint >> 8) & 0xFF);
                if (self.columnFloor(cx, cy)) |f| spot = .{ .x = fx.fromInt(cx) + fx.half, .y = fx.fromInt(cy) + fx.half, .z = fx.fromInt(f.z), .heading = 0 };
            }
            // Players spawn near someone already playing (M2: on a full
            // district, random spots are usually out of each other's sight).
            if (spot == null and player != c.Controller.no_player) {
                if (self.otherPlayerBlock(player)) |o| spot = self.findSpotNear(id, map.Ground.pavement, T.ped_radius, o.x, o.y, T.spawn_near_radius, T.spawn_near_min);
            }
            if (spot == null) spot = self.findSpot(id, map.Ground.pavement, T.ped_radius);
            const sp = spot orelse {
                w.despawn(id);
                return null;
            };
            w.get(id, c.Transform).?.* = .{ .x = sp.x, .y = sp.y, .z = sp.z, .heading = sp.heading };
            w.get(id, c.Collider).?.flags = c.Collider.flag_grounded;
            w.get(id, c.Health).?.* = .{ .hp = T.ped_hp, .last_hit_by = .none };
            w.get(id, c.Riding).?.vehicle = .none;
            w.get(id, c.Controller).?.* = .{ .player = player, .prev_buttons = 0, .in = Frame.neutral(0) };
            w.get(id, c.Pedestrian).?.* = .{ .ai_timer = 0, .ai_heading = sp.heading, .turn = 0, .down = 0, .jump = 0, .anim = 0, .state = 0, .flags = 0 };
            const is_player = player != c.Controller.no_player;
            w.get(id, c.Weapon).?.* = .{ .cooldown = 0, .kind = T.weapon_pistol, .a0 = if (is_player) T.infinite_ammo else 0, .a1 = 0, .a2 = 0, .a3 = 0 };
            w.get(id, c.Appearance).?.* = .{ .sprite = 0, .remap = c.Appearance.no_remap };
            return id;
        }

        pub fn spawnPlayer(self: *Self, slot: u32, hint: u32) void {
            const row = &self.state.players[slot];
            row.ped = self.spawnPed(slot, hint) orelse .none;
            row.car = .none;
        }

        /// Block of a random active player's body, keyed on `key`.
        pub fn randomPlayerBlock(self: *Self, key: EntityId) ?Block {
            const w = &self.state.world;
            var n: u32 = 0;
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active != 0 and w.get(row.ped, c.Transform) != null) n += 1;
            }
            if (n == 0) return null;
            var pick = self.randBelow(key, salt_ambient_player, n);
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                const t = w.get(row.car, c.Transform) orelse w.get(row.ped, c.Transform) orelse continue;
                if (pick == 0) return .{ .x = fx.toInt(t.x), .y = fx.toInt(t.y) };
                pick -= 1;
            }
            return null;
        }

        /// Spawning by zone density (script-declarations.md 2.5, 2.13): owner F.
        /// W0 stub.
        pub fn sysZoneSpawn(self: *Self) void {
            _ = self;
        }
    };
}
