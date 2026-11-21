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

const ids = @import("../ids.zig");
const TF = @import("../tuning/traffic.zig");

// Salts from workstream F's range (ids.salts.traffic).
const salt_zone_car_kind: u32 = 0x1600;
const salt_zone_ped_kind: u32 = 0x1601;
const salt_zone_driving: u32 = 0x1602;
const salt_zone_pick: u32 = 0x1603;
const salt_zone_reskin: u32 = 0x1604;
const route_mod = @import("../ai/route.zig");

/// One zone's spawn settings, from the script's map-zone declaration
/// (script-declarations.md 2.5, type 102).
pub const ZoneDensity = extern struct {
    /// Overall car density, per mille of the configuration's ambient car
    /// count (ours: the note gives no unit).
    car_density: u16 = 0,
    /// Car mix weights: ordinary, "bad", police, gang.
    car_ratio: [4]u16 = .{ 0, 0, 0, 0 },
    /// Overall ped density, per mille of the ambient ped count (ours).
    ped_density: u16 = 0,
    /// Ped mix, per mille of the zone's peds (the rest are civilians; ours):
    /// mugger, car thief, Elvis, gang member.
    ped_ratio: [4]u16 = .{ 0, 0, 0, 0 },
};

/// A zone with settings: `zone` is the index in `Level.zones` plus one.
pub const ZoneSetting = extern struct {
    zone: u16 = 0,
    density: ZoneDensity = .{},
    _pad: u16 = 0,
};

pub const max_zone_settings = 64;

/// Workstream F's part of the SP state block (`state.sp.traffic`).
pub const State = extern struct {
    zones: [max_zone_settings]ZoneSetting = @splat(.{}),
    count: u16 = 0,
    _pad: u16 = 0,
};

/// What a zone's car mix picked (`ZoneDensity.car_ratio` order).
pub const CarKind = enum(u8) { ordinary, bad, police, gang };

pub fn Sys(comptime Self: type) type {
    return struct {
        const Api = @This();
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
            const dir: u2 = @truncate(spot.heading >> 14);
            // Off-screen traffic near a player at three stars or more may
            // become a roadblock instead (E's hook; police-ai.md 3.4).
            if (comptime Self.single_player and @hasDecl(Self.police, "tryRoadblock")) {
                if (driving and near != null) {
                    const l = route_mod.levelUnder(self.grid, spot.x, spot.y, spot.z, T.car_step);
                    if (Self.police.tryRoadblock(self, fx.toInt(spot.x), fx.toInt(spot.y), l, dir)) {
                        w.despawn(id);
                        return null;
                    }
                }
            }
            var model = self.pickAmbientModel(id);
            var reskin = false;
            if (comptime Self.single_player) {
                if (driving and near != null) if (Api.reskinModel(self, id)) |m| {
                    model = m;
                    reskin = true;
                };
            }
            self.initCar(id, spot, model);
            if (driving) {
                const v = w.get(id, c.Vehicle).?;
                v.flags = c.Vehicle.flag_ai;
                v.ai_dir = dir;
                if (reskin) v.ai_flags |= c.Vehicle.ai_emergency;
            }
            return id;
        }

        /// During an FBI or army pursuit, 1 in `reskin_odds` new traffic
        /// cars near the player is one of their units (police-ai.md 3.6;
        /// the rate is ours): its model, or null.
        fn reskinModel(self: *Self, id: EntityId) ?u8 {
            if (comptime !(Self.single_player and @hasDecl(Self.police, "crew"))) return null;
            const kind = Api.reskinKind(self) orelse return null;
            if (self.randBelow(id, salt_zone_reskin, TF.reskin_odds) != 0) return null;
            return Self.police.crew.modelFor(kind);
        }

        /// The highest crew kind (FBI or army) of any player's pursuit, if
        /// E's wanted state records one.
        fn reskinKind(self: *Self) ?u8 {
            if (comptime !(Self.single_player and @hasField(@TypeOf(self.state.sp.wanted[0]), "top_kind"))) return null;
            var best: ?u8 = null;
            for (self.state.sp.wanted) |wst| {
                const k = wst.top_kind;
                if (k == @intFromEnum(ids.Occupation.fbi) or k == @intFromEnum(ids.Occupation.army)) {
                    if (best == null or k > best.?) best = k;
                }
            }
            return best;
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
            // Single-player components start at their declared defaults
            // (`ecs.spawn` zeroes them, and a zero EntityId is not `.none`).
            inline for (.{ c.Objective, c.Group, c.ScriptTag }) |C| {
                if (comptime Ped.has(C)) w.get(id, C).?.* = .{};
            }
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

        // ------------------------------------------------------------------
        // Spawning by zone (script-declarations.md 2.5; owner F). The
        // spawning note is not written: the units, the mix and the pace
        // are ours (tuning/traffic.zig).

        /// Set the spawn settings of the map zone called `name` (the first
        /// zone of that name in the level). False if there is no level, no
        /// such zone, or no room. A zone set twice keeps the last settings.
        pub fn setZoneDensity(self: *Self, name: []const u8, d: ZoneDensity) bool {
            if (comptime !Self.single_player) return false;
            const l = self.level orelse return false;
            for (l.zones, 0..) |z, i| {
                if (std.mem.eql(u8, z.name, name)) return Api.setZoneDensityIndex(self, @intCast(i), d);
            }
            return false;
        }

        /// As `setZoneDensity`, by index into `Level.zones`.
        pub fn setZoneDensityIndex(self: *Self, zone: u16, d: ZoneDensity) bool {
            if (comptime !Self.single_player) return false;
            const st = &self.state.sp.traffic;
            for (st.zones[0..st.count]) |*e| {
                if (e.zone == zone + 1) {
                    e.density = d;
                    return true;
                }
            }
            if (st.count >= max_zone_settings) return false;
            st.zones[st.count] = .{ .zone = zone + 1, .density = d };
            st.count += 1;
            return true;
        }

        /// The settings of the first configured zone (in declaration order)
        /// containing block (bx, by), if any.
        pub fn zoneDensityAt(self: *const Self, bx: i32, by: i32) ?ZoneDensity {
            if (comptime !Self.single_player) return null;
            const l = self.level orelse return null;
            const st = &self.state.sp.traffic;
            for (st.zones[0..st.count]) |e| {
                const i = e.zone - 1;
                if (i < l.zones.len and l.zones[i].contains(bx, by)) return e.density;
            }
            return null;
        }

        /// Weighted pick among four weights (0 when they are all zero).
        pub fn pickWeighted(self: *Self, key: EntityId, salt: u32, w: [4]u16) u8 {
            var total: u32 = 0;
            for (w) |x| total += x;
            if (total == 0) return 0;
            var k = self.randBelow(key, salt, total);
            for (w, 0..) |x, i| {
                if (k < x) return @intCast(i);
                k -= x;
            }
            return 0;
        }

        /// Keep the population near the player at the density of the zone
        /// the player is in: every `zone_spawn_period` ticks, spawn one car
        /// and one ped off screen near the player if below the zone's
        /// target, or remove one out of sight if well above it. Zones with
        /// no settings, and levels with none, leave the population to the
        /// ambient system as before. Single player only.
        pub fn sysZoneSpawn(self: *Self) void {
            if (comptime !Self.single_player) return;
            if (self.predicting()) return;
            if (self.state.sp.traffic.count == 0) return;
            if (self.state.tick % TF.zone_spawn_period != 0) return;
            const w = &self.state.world;
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                const pt = w.get(row.car, c.Transform) orelse w.get(row.ped, c.Transform) orelse continue;
                const bx = fx.toInt(pt.x);
                const by = fx.toInt(pt.y);
                const d = Api.zoneDensityAt(self, bx, by) orelse continue;
                Api.zoneCars(self, bx, by, d);
                Api.zonePeds(self, bx, by, d);
            }
        }

        fn zoneCars(self: *Self, bx: i32, by: i32, d: ZoneDensity) void {
            const w = &self.state.world;
            const target: u32 = @min(@as(u32, Self.config.ambient_cars) * d.car_density / 1000, @as(u32, Car.capacity) * 3 / 4);
            const Ctx = struct { sim: *Self, bx: i32, by: i32, n: u32 = 0, spare: EntityId = .none };
            var ctx = Ctx{ .sim = self, .bx = bx, .by = by };
            w.each(.{ c.Vehicle, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, v: *c.Vehicle, t: *c.Transform) void {
                    if (!Api.ambientCar(cx.sim, id, v)) return;
                    const dist = @max(@abs(fx.toInt(t.x) - cx.bx), @abs(fx.toInt(t.y) - cx.by));
                    if (dist >= T.ambient_far) return;
                    cx.n += 1;
                    if (dist > TF.offscreen_blocks and cx.spare.isNone()) cx.spare = id;
                }
            }.f);
            if (ctx.n < target) {
                const key = EntityId.none;
                const driving = self.randBelow(key, salt_zone_driving, 8) < T.traffic_8ths;
                const id = Api.spawnAmbientCar(self, driving, .{ .x = bx, .y = by }) orelse return;
                const kind: CarKind = @enumFromInt(Api.pickWeighted(self, id, salt_zone_car_kind, d.car_ratio));
                Api.dressCar(self, id, kind);
                self.scratch.stats.ambient_moved += 1;
            } else if (ctx.n > target + TF.zone_slack and !ctx.spare.isNone()) {
                w.despawn(ctx.spare);
            }
        }

        fn zonePeds(self: *Self, bx: i32, by: i32, d: ZoneDensity) void {
            const w = &self.state.world;
            const target: u32 = @min(@as(u32, Self.config.ambient_peds) * d.ped_density / 1000, @as(u32, Ped.capacity) * 3 / 4);
            const Ctx = struct { sim: *Self, bx: i32, by: i32, n: u32 = 0, spare: EntityId = .none };
            var ctx = Ctx{ .sim = self, .bx = bx, .by = by };
            w.each(.{ c.Pedestrian, c.Controller, c.Transform, c.Riding }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, _: *c.Pedestrian, ctl: *c.Controller, t: *c.Transform, r: *c.Riding) void {
                    if (ctl.player != c.Controller.no_player or !r.vehicle.isNone()) return;
                    if (cx.sim.state.world.get(id, c.ScriptTag)) |tag| if (!Api.untagged(tag)) return;
                    const dist = @max(@abs(fx.toInt(t.x) - cx.bx), @abs(fx.toInt(t.y) - cx.by));
                    if (dist >= T.ambient_far) return;
                    cx.n += 1;
                    if (dist > TF.offscreen_blocks and cx.spare.isNone()) cx.spare = id;
                }
            }.f);
            if (ctx.n < target) {
                const id = Api.spawnPedNear(self, bx, by) orelse return;
                // Ped mix: per mille of the zone's peds, the rest civilians.
                var k = self.randBelow(id, salt_zone_ped_kind, @max(1000, sum4(d.ped_ratio)));
                const occs = [4]ids.Occupation{ .mugger, .car_thief, .elvis, .gang_member };
                for (d.ped_ratio, 0..) |x, i| {
                    if (k < x) {
                        Self.objectives.setOccupation(self, id, occs[i]);
                        if (occs[i] == .gang_member) {
                            if (w.get(id, c.Group)) |g| g.gang = Self.gangs.gangOfArea(self, bx, by);
                        }
                        break;
                    }
                    k -= x;
                }
                self.scratch.stats.ambient_moved += 1;
            } else if (ctx.n > target + TF.zone_slack and !ctx.spare.isNone()) {
                w.despawn(ctx.spare);
            }
        }

        fn sum4(a: [4]u16) u32 {
            return @as(u32, a[0]) + a[1] + a[2] + a[3];
        }

        /// Is this car part of the ambient population (not a player's, a
        /// script's, a task's or a wreck)?
        pub fn ambientCar(self: *Self, id: EntityId, v: *const c.Vehicle) bool {
            if (!v.driver.isNone() or v.flags & c.Vehicle.flag_wrecked != 0) return false;
            if (v.ai_flags & c.Vehicle.ai_script != 0) return false;
            const w = &self.state.world;
            if (w.get(id, c.CarTask)) |ct| if (ct.task != 0) return false;
            if (w.get(id, c.ScriptTag)) |tag| if (!Api.untagged(tag)) return false;
            return true;
        }

        fn untagged(tag: *const c.ScriptTag) bool {
            return tag.handle == 0;
        }

        /// The zone's car kinds (ours until E and D2 give police and gang
        /// models): every kind spawns an ordinary model; police cars are
        /// marked emergency (they always honk).
        fn dressCar(self: *Self, id: EntityId, kind: CarKind) void {
            const v = self.state.world.get(id, c.Vehicle) orelse return;
            if (kind == .police) v.ai_flags |= c.Vehicle.ai_emergency;
        }

        /// An ambient ped on the pavement near block (bx, by), off screen.
        pub fn spawnPedNear(self: *Self, bx: i32, by: i32) ?EntityId {
            const w = &self.state.world;
            const id = Api.spawnPed(self, c.Controller.no_player, 0) orelse return null;
            const spot = Api.findSpotNear(self, id, map.Ground.pavement, T.ped_radius, bx, by, T.ambient_near_radius, T.ambient_near_min) orelse {
                w.despawn(id);
                return null;
            };
            w.get(id, c.Transform).?.* = .{ .x = spot.x, .y = spot.y, .z = spot.z, .heading = spot.heading };
            w.get(id, c.Pedestrian).?.ai_heading = spot.heading;
            return id;
        }
    };
}
