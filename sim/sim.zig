//! Sim core, implementing I1 (interfaces/I1-sim-abi.md): init(grid, params),
//! step(frames, commands), save, load, hash, views, intents, replicas.
//! No I/O, no clock, no floats, no allocation.
//!
//! The saved state is `State`: one extern struct, copied with memcpy.
//! Derived per-tick data (the broadphase, intents, stats) lives in
//! `Scratch`, outside it.
//!
//! M1 gameplay: peds walk with tank or direct control and jump, cars drive
//! with a placeholder handling model (`tuning.zig`), peds get in and out of
//! cars through `Riding`, everything collides with the map grid (`map.zig`)
//! and with each other.
//!
//! M3 gameplay: four weapons with ammo, weapon pickups and health near the
//! players, rockets and explosions, cars that catch fire and burn out,
//! traffic that drives the lanes, ambient cars and peds kept near the
//! players, kill credit and a frag limit. Game events (kills, explosions,
//! pickups, round ends) are reported through `events()` for the hosts.

const std = @import("std");
const ifaces = @import("interfaces");
pub const abi = ifaces.abi;
pub const input = ifaces.input;
pub const fx = @import("fixed.zig");
pub const ecs = @import("ecs.zig");
pub const map = @import("map.zig");
pub const c = @import("components.zig");
pub const tuning = @import("tuning.zig");
pub const testmap = @import("testmap.zig");

const Fx = fx.Fx;
const EntityId = abi.EntityId;
const Frame = input.Frame;
const Button = input.Button;
const T = tuning;
const eql = ecs.eql;

pub const Config = abi.Config;

/// The first-release configuration (I1).
pub const config_16 = abi.config_16;

/// "200 players' worth" for native load runs, as S2 measured.
pub const config_200: Config = .{
    .name = "dm200",
    .max_players = 200,
    .car_capacity = 512,
    .ped_capacity = 2048,
    .projectile_capacity = 1024,
    .ambient_cars = 200,
    .ambient_peds = 1250,
};

/// Spawn hint in `Command.arg` for `join`: 0 lets the sim choose; otherwise
/// bits 0-7 are the block x and bits 8-15 the block y, and the ped is placed
/// on the highest floor in that column.
pub fn spawnHint(x: u8, y: u8) u32 {
    return @as(u32, x) | (@as(u32, y) << 8) | (1 << 31);
}

// Salts for abi.rand, one per call site.
const salt_spawn_x: u32 = 0x100;
const salt_spawn_y: u32 = 0x200;
const salt_near_x: u32 = 0x500;
const salt_near_y: u32 = 0x580;
const salt_ai_timer: u32 = 0x300;
const salt_ai_turn: u32 = 0x301;
const salt_car_model: u32 = 0x400;
const salt_jitter: u32 = 0x600;
const salt_pickup_kind: u32 = 0x700;
const salt_pickup_player: u32 = 0x701;
const salt_ai_plan: u32 = 0x800;
const salt_ambient_player: u32 = 0x900;

const max_intents = 64;
const max_events = 32;

pub fn Sim(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        pub const config: abi.Config = cfg;

        pub const Car = ecs.Kind(.car, cfg.car_capacity, &.{
            c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Vehicle, c.Predicted, c.Appearance,
        });
        pub const Ped = ecs.Kind(.ped, cfg.ped_capacity, &.{
            c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Pedestrian, c.Riding, c.Weapon, c.Predicted, c.Appearance,
        });
        pub const Shot = ecs.Kind(.projectile, cfg.projectile_capacity, &.{
            c.Transform, c.Velocity, c.Projectile,
        });
        pub const Pickup = ecs.Kind(.pickup, cfg.pickup_capacity, &.{ c.Transform, c.Weapon, c.Appearance });
        pub const MapObject = ecs.Kind(.map_object, cfg.map_object_capacity, &.{c.Transform});
        pub const World = ecs.World(&.{ Car, Ped, Shot, Pickup, MapObject });

        /// Components replicated per kind (for I3 codecs, workstream C), in
        /// ascending component id. `Predicted` is never replicated.
        pub const replicated = .{
            .{ abi.Kind.car, .{ c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Vehicle, c.Appearance } },
            .{ abi.Kind.ped, .{ c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Pedestrian, c.Riding, c.Weapon, c.Appearance } },
            .{ abi.Kind.projectile, .{ c.Transform, c.Velocity, c.Projectile } },
            .{ abi.Kind.pickup, .{ c.Transform, c.Weapon, c.Appearance } },
            .{ abi.Kind.map_object, .{c.Transform} },
        };

        pub const State = extern struct {
            tick: u32,
            seed_lo: u32,
            seed_hi: u32,
            _pad: u32 = 0,
            players: [cfg.max_players]abi.PlayerRow,
            world: World,
        };

        comptime {
            // Layout guard: no implicit padding in the top-level state.
            var sum: usize = 0;
            for (@typeInfo(State).@"struct".field_types) |FT| sum += @sizeOf(FT);
            if (sum != @sizeOf(State)) @compileError("State has implicit padding");
        }

        pub const state_size: usize = @sizeOf(State);
        pub const layout_hash: u64 = abi.layoutHash(State);

        const Entry = struct {
            id: EntityId,
            x: Fx,
            y: Fx,
            z: Fx,
            r: Fx,
            mass: i32,
            /// May be moved by contacts (authoritative, or predicted).
            movable: bool,
            next: u32,
        };
        const max_entries = @as(u32, cfg.car_capacity) + cfg.ped_capacity;
        const nil: u32 = 0xFFFF_FFFF;
        const cell_shift = 17; // broadphase cell = 2 blocks
        const cells_x = map.size_x >> 1;
        const cells_y = map.size_y >> 1;

        pub const Scratch = struct {
            cell_head: [cells_y * cells_x]u32,
            cell_stamp: [cells_y * cells_x]u32,
            entries: [max_entries]Entry,
            n: u32,
            stamp: u32,
            intent_buf: [max_intents]abi.Intent,
            intent_len: u32,
            event_buf: [max_events]Event,
            event_len: u32,
            /// Diagnostics only (not saved, not hashed).
            stats: Stats,
        };

        pub const Stats = struct {
            contacts: u64 = 0,
            impacts: u64 = 0,
            wall_hits: u64 = 0,
            shots: u64 = 0,
            shot_hits: u64 = 0,
            ped_deaths: u64 = 0,
            car_wrecks: u64 = 0,
            boardings: u64 = 0,
            exits: u64 = 0,
            intents_dropped: u64 = 0,
            explosions: u64 = 0,
            pickups_taken: u64 = 0,
            ambient_moved: u64 = 0,
            rounds: u64 = 0,
        };

        /// A game event from the last `step` (authoritative mode only), for
        /// the host: the server forwards them as I3 `event` messages, an
        /// offline client plays them. Kinds are the I3 event kinds.
        pub const Event = struct {
            kind: Kind,
            a: u8 = 0,
            b: u8 = 0,
            c: u8 = 0,
            x: Fx = 0,
            y: Fx = 0,
            z: Fx = 0,

            pub const Kind = enum(u8) {
                /// a = killer slot or 0xFF, b = victim slot, c = weapon
                /// (`weapon_car` for run over or rammed, `weapon_fire` for a
                /// burning car or an explosion with no shooter).
                kill = 1,
                /// a = cause (0 rocket, 1 car).
                explosion = 4,
                /// a = winner slot.
                round_end = 5,
                /// a = slot, b = what (weapon index or `tuning.pickup_health`).
                pickup = 6,
            };
            pub const no_slot: u8 = 0xFF;
            pub const weapon_car: u8 = 0x80;
            pub const weapon_fire: u8 = 0x81;
        };

        state: State,
        scratch: Scratch,
        grid: *const abi.Grid,
        /// A property of the host, not of the state: a client that loads a
        /// server state stays in predict mode.
        mode: abi.Mode,

        comptime {
            abi.checkSim(Self);
        }

        // ==================================================================
        // I1

        pub fn init(self: *Self, grid: *const abi.Grid, p: abi.InitParams) void {
            @memset(std.mem.asBytes(&self.state), 0);
            @memset(std.mem.asBytes(&self.scratch), 0);
            self.grid = grid;
            self.mode = p.mode;
            const s = &self.state;
            s.seed_lo = @truncate(p.seed);
            s.seed_hi = @truncate(p.seed >> 32);
            for (&s.players) |*row| row.* = emptyRow();
            if (p.mode == .authoritative) {
                var i: u32 = 0;
                while (i < cfg.ambient_cars) : (i += 1) _ = self.spawnAmbientCar(i % 8 < T.traffic_8ths, null);
                i = 0;
                while (i < cfg.ambient_peds) : (i += 1) _ = self.spawnPed(c.Controller.no_player, 0);
                s.world.applyPending();
            }
        }

        pub fn step(self: *Self, frames: []const Frame, cmds: []const abi.Command) void {
            self.scratch.intent_len = 0;
            self.scratch.event_len = 0;
            if (!self.predicting()) {
                for (cmds) |cmd| self.applyCommand(cmd);
            }
            self.sysInput(frames);
            self.sysPedAi();
            self.sysTrafficAi();
            self.sysPedControl();
            self.sysCarControl();
            self.sysWeapons();
            self.sysExplosions();
            self.sysMoveCars();
            self.sysMovePeds();
            self.sysMoveProjectiles();
            self.buildBroadphase();
            self.sysContacts();
            self.sysProjectileHits();
            self.sysPickups();
            self.sysPedStatus();
            self.sysRiders();
            self.sysHealth();
            self.sysRespawn();
            self.sysAmbient();
            self.state.world.applyPending();
            self.state.tick +%= 1;
        }

        pub fn save(self: *const Self, buf: []u8) usize {
            const bytes = std.mem.asBytes(&self.state);
            @memcpy(buf[0..bytes.len], bytes);
            return bytes.len;
        }

        pub fn load(self: *Self, buf: []const u8) error{BadSize}!void {
            if (buf.len != state_size) return error.BadSize;
            @memcpy(std.mem.asBytes(&self.state), buf);
        }

        pub fn hash(self: *const Self) u64 {
            return abi.stateHash(std.mem.asBytes(&self.state));
        }

        pub fn tick(self: *const Self) abi.Tick {
            return self.state.tick;
        }

        pub fn setTick(self: *Self, t: abi.Tick) void {
            self.state.tick = t;
        }

        pub fn stateBytes(self: *const Self) []const u8 {
            return std.mem.asBytes(&self.state);
        }

        pub fn views() []const abi.ColumnDesc {
            return &view_table;
        }

        pub fn intents(self: *const Self) []const abi.Intent {
            return self.scratch.intent_buf[0..self.scratch.intent_len];
        }

        /// Game events from the last `step` (not part of I1).
        pub fn events(self: *const Self) []const Event {
            return self.scratch.event_buf[0..self.scratch.event_len];
        }

        pub fn playerRow(self: *Self, slot: u32) *abi.PlayerRow {
            return &self.state.players[slot];
        }

        pub fn replicaPut(self: *Self, id: EntityId) bool {
            inline for (World.Kinds) |K| {
                if (id.kind() == @intFromEnum(K.kind)) {
                    const t = self.state.world.table(K);
                    const i = id.index();
                    if (i >= K.capacity) return false;
                    if (t.slot[i] != ecs.Slot.alive or t.gen[i] != id.gen()) {
                        if (t.slot[i] == ecs.Slot.free) {
                            t.live += 1;
                            // Take it off the free stack if it is there.
                            var j: u32 = 0;
                            while (j < t.free_len) : (j += 1) {
                                if (t.free[j] == i) {
                                    t.free_len -= 1;
                                    t.free[j] = t.free[t.free_len];
                                    t.free[t.free_len] = 0;
                                    break;
                                }
                            }
                        }
                        t.gen[i] = id.gen();
                        t.slot[i] = ecs.Slot.alive;
                        inline for (K.components) |C| t.col(C)[i] = std.mem.zeroes(C);
                        if (t.len <= i) t.len = i + 1;
                    }
                    return true;
                }
            }
            return false;
        }

        pub fn replicaRemove(self: *Self, id: EntityId) void {
            inline for (World.Kinds) |K| {
                if (id.kind() == @intFromEnum(K.kind)) {
                    const t = self.state.world.table(K);
                    const i = id.index();
                    if (i >= K.capacity or t.gen[i] != id.gen() or t.slot[i] == ecs.Slot.free) return;
                    t.slot[i] = ecs.Slot.free;
                    t.live -= 1;
                    inline for (K.components) |C| t.col(C)[i] = std.mem.zeroes(C);
                    return;
                }
            }
        }

        // ------------------------------------------------------------------
        // Views: where each column lives in `stateBytes()`.

        const view_table = blk: {
            @setEvalBranchQuota(100_000);
            var n: usize = 2;
            for (World.Kinds) |K| n += 3 + K.components.len;
            var v: [n]abi.ColumnDesc = undefined;
            v[0] = .{ .kind = 0, .component = abi.ColumnDesc.Special.tick, .offset = @offsetOf(State, "tick"), .stride = 4, .count = 1 };
            v[1] = .{ .kind = @intFromEnum(abi.Kind.player_row), .component = abi.ColumnDesc.Special.player_rows, .offset = @offsetOf(State, "players"), .stride = @sizeOf(abi.PlayerRow), .count = cfg.max_players };
            var i: usize = 2;
            const world_off = @offsetOf(State, "world") + @offsetOf(World, "tables");
            for (World.Kinds) |K| {
                const TT = ecs.Table(K);
                const base = world_off + @offsetOf(@FieldType(World, "tables"), K.name);
                const k: u8 = @intFromEnum(K.kind);
                v[i] = .{ .kind = k, .component = abi.ColumnDesc.Special.len, .offset = base + @offsetOf(TT, "len"), .stride = 4, .count = 1 };
                v[i + 1] = .{ .kind = k, .component = abi.ColumnDesc.Special.generation, .offset = base + @offsetOf(TT, "gen"), .stride = 2, .count = K.capacity };
                v[i + 2] = .{ .kind = k, .component = abi.ColumnDesc.Special.slot, .offset = base + @offsetOf(TT, "slot"), .stride = 1, .count = K.capacity };
                i += 3;
                const cols_off = base + @offsetOf(TT, "cols");
                for (K.components) |C| {
                    v[i] = .{
                        .kind = k,
                        .component = @intFromEnum(C.id),
                        .offset = cols_off + @offsetOf(@FieldType(TT, "cols"), ecs.colName(C)),
                        .stride = @sizeOf(C),
                        .count = K.capacity,
                    };
                    i += 1;
                }
            }
            break :blk v;
        };

        // ==================================================================
        // Helpers

        fn emptyRow() abi.PlayerRow {
            return .{ .ped = .none, .car = .none, .kills = 0, .deaths = 0, .score = 0, .respawn_timer = 0, .flags = 0 };
        }

        inline fn predicting(self: *const Self) bool {
            return self.mode == .predict;
        }

        fn seed(self: *const Self) u64 {
            return (@as(u64, self.state.seed_hi) << 32) | self.state.seed_lo;
        }

        /// The only randomness: a keyed hash (I1 rule 4).
        fn rand(self: *const Self, entity: EntityId, salt: u32) u32 {
            return abi.rand(self.seed(), self.state.tick, entity, salt);
        }

        fn randBelow(self: *const Self, entity: EntityId, salt: u32, n: u32) u32 {
            return @truncate((@as(u64, self.rand(entity, salt)) * n) >> 32);
        }

        /// May this step write to entity `id`? Always in authoritative mode;
        /// only predicted entities in predict mode.
        fn writable(self: *Self, id: EntityId) bool {
            if (!self.predicting()) return true;
            const w = &self.state.world;
            if (w.get(id, c.Predicted)) |p| return p.on != 0;
            return false;
        }

        fn pushEvent(self: *Self, e: Event) void {
            if (self.predicting()) return;
            const sc = &self.scratch;
            if (sc.event_len >= max_events) return;
            sc.event_buf[sc.event_len] = e;
            sc.event_len += 1;
        }

        fn pushIntent(self: *Self, op: abi.Intent.Op, kind: abi.Kind, source: EntityId, t: c.Transform) void {
            const sc = &self.scratch;
            if (sc.intent_len >= max_intents) {
                sc.stats.intents_dropped += 1;
                return;
            }
            sc.intent_buf[sc.intent_len] = .{ .op = op, .kind = @intFromEnum(kind), .source = source, .x = t.x, .y = t.y, .z = t.z, .heading = t.heading };
            sc.intent_len += 1;
        }

        /// Despawn, or in predict mode report it as an intent.
        fn kill(self: *Self, id: EntityId) void {
            const w = &self.state.world;
            if (self.predicting()) {
                const t = (w.get(id, c.Transform) orelse return).*;
                self.pushIntent(.despawn, @enumFromInt(id.kind()), id, t);
                return;
            }
            w.despawn(id);
        }

        fn speedOf(v: *const c.Velocity) Fx {
            return fx.length(v.vx, v.vy);
        }

        // ==================================================================
        // Spawning (authoritative only; spawn sites report intents instead)

        const Spot = struct { x: Fx, y: Fx, z: Fx, heading: u16 };
        const Block = struct { x: i32, y: i32 };

        /// Standing height on the highest floor of column (cx, cy), if that
        /// floor is a full block with headroom above it.
        fn columnFloor(self: *const Self, cx: i32, cy: i32) ?struct { z: i32, cell: map.Cell } {
            var z: i32 = map.size_z - 2;
            while (z >= 0) : (z -= 1) {
                const cell = map.cellAt(self.grid, cx, cy, z);
                const sh = map.shapeOf(cell);
                if (sh == map.Shape.air or sh == map.Shape.water) continue;
                if ((sh != map.Shape.solid and sh != map.Shape.slab) or map.codeOf(cell) != 0) return null;
                if (map.shapeOf(map.cellAt(self.grid, cx, cy, z + 1)) != map.Shape.air) return null;
                return .{ .z = z + 1, .cell = cell };
            }
            return null;
        }

        /// A random free spot whose floor has ground type `ground`, keyed on
        /// the entity being spawned.
        fn findSpot(self: *Self, key: EntityId, ground: u2, clearance: Fx) ?Spot {
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
        fn findSpotNear(self: *Self, key: EntityId, ground: u2, clearance: Fx, ox: i32, oy: i32, radius: i32, min_dist: i32) ?Spot {
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
        fn otherPlayerBlock(self: *Self, slot: u32) ?Block {
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

        fn headingFromArrows(arrows: u4, fallback: u32) u16 {
            if (arrows & map.Arrow.pos_x != 0) return 0;
            if (arrows & map.Arrow.pos_y != 0) return 16384;
            if (arrows & map.Arrow.neg_x != 0) return 32768;
            if (arrows & map.Arrow.neg_y != 0) return 49152;
            return @truncate(fallback *% 16384);
        }

        /// An ambient car on a road: traffic if `driving`, else parked. With
        /// `near`, within reach of that block (off screen), else anywhere.
        fn spawnAmbientCar(self: *Self, driving: bool, near: ?Block) ?EntityId {
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
        fn pickAmbientModel(self: *Self, id: EntityId) u8 {
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

        fn initCar(self: *Self, id: EntityId, spot: Spot, model: u8) void {
            const w = &self.state.world;
            w.get(id, c.Transform).?.* = .{ .x = spot.x, .y = spot.y, .z = spot.z, .heading = spot.heading };
            w.get(id, c.Collider).?.flags = c.Collider.flag_grounded;
            w.get(id, c.Health).?.* = .{ .hp = T.car_damage_max, .last_hit_by = .none };
            w.get(id, c.Controller).?.* = .{ .player = c.Controller.no_player, .prev_buttons = 0, .in = Frame.neutral(0) };
            w.get(id, c.Vehicle).?.* = .{ .driver = .none, .model = model, .pedal = 0, .steer = 0, .flags = 0, .timer = 0, .ai_dir = 0, .ai_plan = 0, .halt = 0, .ai_speed = 0, .brake = 0, .handbrake_n = 0, .drive = 0 };
            w.get(id, c.Appearance).?.* = .{ .sprite = @intCast(T.carModel(model).sprite), .remap = c.Appearance.no_remap };
        }

        /// Spawn a ped for `player` (or an ambient ped for no_player).
        fn spawnPed(self: *Self, player: u32, hint: u32) ?EntityId {
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

        fn spawnPlayer(self: *Self, slot: u32, hint: u32) void {
            const row = &self.state.players[slot];
            row.ped = self.spawnPed(slot, hint) orelse .none;
            row.car = .none;
        }

        // ==================================================================
        // Commands

        fn applyCommand(self: *Self, cmd: abi.Command) void {
            if (cmd.slot >= cfg.max_players) return;
            const row = &self.state.players[cmd.slot];
            switch (cmd.op) {
                .join => {
                    if (row.flags & abi.PlayerRow.flag_active != 0) return;
                    row.* = emptyRow();
                    row.flags = abi.PlayerRow.flag_active | abi.PlayerRow.flag_connected;
                    self.spawnPlayer(cmd.slot, cmd.arg);
                },
                .leave => {
                    if (row.flags & abi.PlayerRow.flag_active == 0) return;
                    const w = &self.state.world;
                    if (w.get(row.ped, c.Riding)) |r| {
                        if (!r.vehicle.isNone()) self.releaseCar(r.vehicle);
                    }
                    if (!row.ped.isNone()) w.despawn(row.ped);
                    row.* = emptyRow();
                },
                else => {},
            }
        }

        // ==================================================================
        // Systems, in tick order

        fn sysInput(self: *Self, frames: []const Frame) void {
            const Ctx = struct { sim: *Self, frames: []const Frame };
            self.state.world.eachFiltered(.{ c.Controller, c.Riding, c.Transform }, self.predicting(), Ctx{ .sim = self, .frames = frames }, struct {
                fn f(ctx: Ctx, id: EntityId, ctl: *c.Controller, ride: *c.Riding, t: *c.Transform) void {
                    _ = t;
                    if (ctl.player == c.Controller.no_player) return;
                    const sim = ctx.sim;
                    const in = if (ctl.player < ctx.frames.len) ctx.frames[ctl.player].sanitize() else Frame.neutral(0);
                    const pressed = in.buttons & ~@as(u16, @truncate(ctl.prev_buttons));
                    ctl.prev_buttons = in.buttons;
                    ctl.in = in;
                    const w = &sim.state.world;
                    const ped = w.get(id, c.Pedestrian);
                    const up = if (ped) |p| p.state == c.Pedestrian.state_up else true;
                    if (pressed & Button.enter_exit != 0) {
                        if (!ride.vehicle.isNone()) sim.tryExit(id) else if (up) sim.tryEnter(id);
                    }
                    if (ride.vehicle.isNone() and pressed & Button.handbrake_jump != 0) {
                        if (ped) |p| p.flags |= c.Pedestrian.flag_jump_pressed;
                    }
                    if (pressed & (Button.weapon_next | Button.weapon_prev) != 0) {
                        if (w.get(id, c.Weapon)) |wpn| cycleWeapon(wpn, pressed & Button.weapon_next != 0);
                    }
                    if (!ride.vehicle.isNone()) {
                        if (w.get(ride.vehicle, c.Controller)) |cc| {
                            if (sim.writable(ride.vehicle)) {
                                cc.prev_buttons = cc.in.buttons;
                                cc.in = in;
                            }
                        }
                    }
                }
            }.f);
        }


        /// Get into the nearest free car, searching from half a block in
        /// front of the ped; the car must be nearly still.
        fn tryEnter(self: *Self, ped: EntityId) void {
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

        fn board(self: *Self, ped: EntityId, car: EntityId) void {
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
        fn tryExit(self: *Self, ped: EntityId) void {
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
        fn releaseCar(self: *Self, car: EntityId) void {
            const w = &self.state.world;
            if (w.get(car, c.Vehicle)) |v| v.driver = .none;
            if (w.get(car, c.Controller)) |cc| cc.* = .{ .player = c.Controller.no_player, .prev_buttons = 0, .in = Frame.neutral(0) };
        }

        /// Ambient peds wander on pavements: walk a heading for a while, turn
        /// now and then, and turn away from roads and walls.
        fn sysPedAi(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Controller, c.Transform }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, ped: *c.Pedestrian, ctl: *c.Controller, t: *c.Transform) void {
                    if (ctl.player != c.Controller.no_player) return;
                    // Look one step ahead: road or no floor means turn round.
                    const ax = t.x + fx.mul(fx.cos(ped.ai_heading), fx.ratio(6, 10));
                    const ay = t.y + fx.mul(fx.sin(ped.ai_heading), fx.ratio(6, 10));
                    const ahead = map.floorCell(sim.grid, ax, ay, t.z, T.ped_step);
                    const bad = map.groundOf(ahead) != map.Ground.pavement or
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

        /// On-foot control (ped-movement.md 3.1-3.6): tank turning that
        /// builds up while held, one running pace forward and back, and a
        /// jump on a fresh press that carries the ped forward without
        /// leaving the ground. Direct mode (sticks) turns toward the aim.
        /// Knocked-over peds and falling peds take no control.
        fn sysPedControl(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Riding, c.Controller, c.Transform, c.Velocity, c.Collider }, self.predicting(), {}, struct {
                fn f(_: void, _: EntityId, ped: *c.Pedestrian, ride: *c.Riding, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    const jump_pressed = ped.flags & c.Pedestrian.flag_jump_pressed != 0;
                    ped.flags &= ~c.Pedestrian.flag_jump_pressed;
                    if (!ride.vehicle.isNone()) {
                        ped.turn = 0;
                        ped.jump = 0;
                        return;
                    }
                    if (ped.state != c.Pedestrian.state_up) return;
                    const grounded = col.flags & c.Collider.flag_grounded != 0;
                    const jumping = ped.jump > 0;
                    // Falling: keeps its motion (3.5).
                    if (!grounded and !jumping) {
                        ped.anim = c.Pedestrian.anim_jump;
                        return;
                    }
                    const in = ctl.in;
                    const run = in.buttons & Button.run != 0;
                    var speed: Fx = 0;
                    var dir: u16 = t.heading;
                    if (in.buttons & Button.direct != 0) {
                        ped.turn = 0;
                        const diff: i16 = @bitCast(in.aim -% t.heading);
                        const lim: i32 = if (jumping) T.ped_turn_jump_max else T.ped_direct_turn;
                        const turn = std.math.clamp(@as(i32, diff), -lim, lim);
                        t.heading +%= @as(u16, @truncate(@as(u32, @bitCast(turn))));
                        if (in.throttle > 0) {
                            speed = fx.mulAxis(if (run) T.ped_run else T.ped_walk, in.throttle);
                            dir = in.aim;
                        }
                    } else {
                        if (in.steer == 0) {
                            ped.turn = 0;
                        } else {
                            // The turn speed steps toward the held side, up
                            // to a cap (a stick's deflection scales the cap).
                            const aiming = in.buttons & Button.fire != 0 and in.throttle <= 0;
                            const rate: i32 = if (jumping) T.ped_turn_jump else if (aiming) T.ped_turn_aim else T.ped_tank_turn;
                            const max: i32 = if (jumping) T.ped_turn_jump_max else T.ped_turn_max;
                            const cap = @divTrunc(max * @as(i32, @abs(in.steer)), 127);
                            const sign: i32 = if (in.steer > 0) 1 else -1;
                            ped.turn = @intCast(std.math.clamp(@as(i32, ped.turn) + sign * rate, -cap, cap));
                        }
                        t.heading +%= @as(u16, @bitCast(ped.turn));
                        dir = t.heading;
                        if (in.throttle > 0) {
                            speed = fx.mulAxis(if (run) T.ped_run else T.ped_walk, in.throttle);
                        } else if (in.throttle < 0) {
                            speed = fx.mulAxis(T.ped_back, -in.throttle);
                            dir = t.heading +% 32768;
                        }
                    }
                    if (jumping) {
                        ped.jump -= 1;
                    } else if (jump_pressed) {
                        ped.jump = T.ped_jump_ticks;
                    }
                    // A jump always carries him forward at the run pace.
                    if (ped.jump > 0 and speed == 0) {
                        speed = T.ped_run;
                        dir = t.heading;
                    }
                    vel.vx = fx.mul(fx.cos(dir), speed);
                    vel.vy = fx.mul(fx.sin(dir), speed);
                    vel.vz = 0;
                    ped.anim = if (ped.jump > 0) c.Pedestrian.anim_jump else if (speed == 0) c.Pedestrian.anim_stand else if (run) c.Pedestrian.anim_run else c.Pedestrian.anim_walk;
                }
            }.f);
        }

        /// Car handling (docs/behaviour/car-handling.md, steps 1-13): up and
        /// down mean throttle, foot brake or reverse by the direction of
        /// travel; a gas pedal 0-5 and three gears make the engine force; each
        /// axle's tyre pushes against its sideways slip and rolling drag, the
        /// rear one steering slightly against the front at low speed, scaled
        /// by rear end stability, with the handbrake cutting its grip; then
        /// damping, the speed cap and the lane-arrow snap. Spin is in radians
        /// a tick (fixed point). Cars in the air only damp.
        fn sysCarControl(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Vehicle, c.Controller, c.Transform, c.Velocity, c.Collider, c.Health }, self.predicting(), self, struct {
                fn f(sim: *Self, _: EntityId, v: *c.Vehicle, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, col: *c.Collider, hp: *c.Health) void {
                    const m = T.carModel(v.model);
                    const ai = v.flags & c.Vehicle.flag_ai != 0;
                    const driven = (!v.driver.isNone() or ai) and v.flags & c.Vehicle.flag_wrecked == 0;
                    const in = if (driven) ctl.in else Frame.neutral(0);
                    const player = !v.driver.isNone() and ctl.player != c.Controller.no_player;
                    const handbrake = in.buttons & Button.handbrake_jump != 0;
                    const keep = v.flags & (c.Vehicle.flag_ai | c.Vehicle.flag_burning | c.Vehicle.flag_wrecked);
                    v.flags = keep | (if (handbrake) c.Vehicle.flag_handbrake else 0) | (if (in.buttons & Button.special != 0) c.Vehicle.flag_horn else 0);
                    v.steer = in.steer;

                    const fwd_x = fx.cos(t.heading);
                    const fwd_y = fx.sin(t.heading);
                    const vf0 = fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y);
                    const speed = fx.length(vel.vx, vel.vy);
                    const stopped = vel.vx == 0 and vel.vy == 0;
                    const forwards = vf0 >= 0;

                    // 1. Input: up and down by the direction of travel; a
                    // change of direction costs a tick with nothing held.
                    const up = in.throttle > 0;
                    const down = in.throttle < 0;
                    var thr = false;
                    var rev = false;
                    var brake = false;
                    if (stopped) {
                        thr = up;
                        rev = down;
                    } else if (forwards) {
                        if (v.drive != c.Vehicle.drive_reverse) {
                            thr = up;
                            brake = down;
                        }
                    } else if (v.drive != c.Vehicle.drive_forward) {
                        rev = down;
                        brake = up;
                    }
                    v.drive = if (thr) c.Vehicle.drive_forward else if (rev) c.Vehicle.drive_reverse else c.Vehicle.drive_none;

                    // 2-4. Pedal (a stick's deflection caps it), brake
                    // pressure, handbrake ramp, turbo, damage factor.
                    const amount: i32 = @intCast(@abs(@as(i32, in.throttle)));
                    const cap: i32 = @max(1, @divTrunc(amount * T.pedal_quarters_max + 126, 127));
                    var pedal: i32 = v.pedal;
                    pedal = if (thr or rev) @min(pedal + 1, cap) else @max(pedal - 1, 0);
                    v.pedal = @intCast(pedal);
                    v.brake = if (brake) @min(v.brake + 1, T.brake_quarters_max) else 0;
                    v.handbrake_n = if (handbrake) @min(v.handbrake_n +| 1, T.handbrake_ramp) else 0;
                    const turbo = m.turbo != 0 and pedal >= T.turbo_quarters;
                    const damage = T.car_damage_max - hp.hp;
                    const dmg_factor: Fx = if (damage < T.car_fire_damage) fx.one else frac(T.car_damage_max + 1 - damage, T.car_fire_damage);

                    if (col.flags & c.Collider.flag_grounded == 0) {
                        damp(vel, t.heading, T.damp_lateral_air, T.damp_long_air, T.damp_spin_air);
                        return;
                    }

                    // 5. Engine force.
                    var engine: Fx = 0;
                    if (driven and (thr or rev)) {
                        const base = m.thrust >> 1;
                        var pterm = fx.mul(frac(pedal, 4), @divTrunc(m.thrust, 5));
                        if (turbo) pterm *= 2;
                        if (player) {
                            if (rev) {
                                engine = -fx.mul(base + pterm, m.gear1);
                            } else if (!(handbrake and stopped)) {
                                const gear: Fx = if (speed > m.gear3_speed) m.gear3 else if (speed > m.gear2_speed) m.gear2 else m.gear1;
                                const p2 = if (speed > m.gear2_speed) fx.mul(pterm, dmg_factor) else pterm;
                                engine = fx.mul(base + p2, gear);
                            }
                        } else {
                            const e = base + fx.mul(pterm, dmg_factor);
                            engine = if (rev) -e else e;
                        }
                    }
                    const brake_force = fx.mul(frac(v.brake, 4), m.brake_friction);

                    // 7. Steering angle (radians).
                    const dir = frac(in.steer, 127);
                    var angle = fx.mul(dir, m.turn_ratio);
                    if (player) angle = fx.div(fx.mul(angle, @max(T.steer_speed_min, T.steer_speed_ref - speed)), T.steer_div);
                    const steering = in.steer != 0;

                    // 8. Tyre forces at each axle.
                    var mass = m.mass;
                    if (player) mass = fx.mul(mass, T.player_mass);
                    var force = [2]Fx{ 0, 0 };
                    var torque: Fx = 0;
                    const ra = fx.div(fx.mul(angle, T.steer_speed_ref - speed), T.rear_steer_div);
                    inline for (.{ true, false }) |front| {
                        const d = if (front) m.front_axle else m.rear_axle;
                        const a_rad = if (front) angle else -ra;
                        const a = t.heading +% radToAngle(a_rad);
                        const ax = fx.cos(a);
                        const ay = fx.sin(a);
                        // Velocity of the axle point, with the spin.
                        const rx = fx.mul(d, fwd_x);
                        const ry = fx.mul(d, fwd_y);
                        const px = vel.vx - fx.mul(vel.spin, ry);
                        const py = vel.vy + fx.mul(vel.spin, rx);
                        const v_long = fx.mul(px, ax) + fx.mul(py, ay);
                        const v_lat = fx.mul(px, -ay) + fx.mul(py, ax);
                        var grip: Fx = fx.one;
                        if (steering) grip = if (front) fx.one + m.turn_in else fx.one - m.turn_in;
                        if (!front and handbrake) grip = fx.mul(grip, m.handbrake_slide);
                        var drag = T.rolling_drag + fx.mul(brake_force, if (front) T.front_brake_share else T.rear_brake_share);
                        if (!front) drag += fx.mul(m.brake_friction, frac(v.handbrake_n, T.handbrake_ramp));
                        const share = if (front) fx.mul(engine, m.front_drive_bias) else engine - fx.mul(engine, m.front_drive_bias);
                        const f_lat = -fx.mul(v_lat, grip);
                        const f_long = -fx.mul(v_long, drag) + share;
                        var fwx = fx.mul(f_long, ax) - fx.mul(f_lat, ay);
                        var fwy = fx.mul(f_long, ay) + fx.mul(f_lat, ax);
                        if (!front) {
                            fwx = fx.mul(fwx, m.rear_end_stability);
                            fwy = fx.mul(fwy, m.rear_end_stability);
                        }
                        force[0] += fwx;
                        force[1] += fwy;
                        torque += fx.mul(rx, fwy) - fx.mul(ry, fwx);
                    }

                    // 10. Integrate, with dead zones.
                    vel.vx += fx.div(force[0], mass);
                    vel.vy += fx.div(force[1], mass);
                    vel.spin += fx.div(torque, m.inertia);
                    if (fx.abs(vel.vx) + fx.abs(vel.vy) < T.dead_zone) {
                        vel.vx = 0;
                        vel.vy = 0;
                    }
                    if (fx.abs(vel.spin) < T.dead_zone) vel.spin = 0;

                    // 11. Damping.
                    damp(vel, t.heading, T.damp_lateral, T.damp_long, T.damp_spin);

                    // 12. Speed cap: max speed forwards, gear 2 speed back.
                    const sp = fx.length(vel.vx, vel.vy);
                    const back = fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y) < 0;
                    const cap_v = if (back) m.gear2_speed else m.max_speed;
                    if (sp > cap_v and sp > 0) {
                        vel.vx = fx.mul(vel.vx, fx.div(cap_v, sp));
                        vel.vy = fx.mul(vel.vy, fx.div(cap_v, sp));
                    }

                    // 13. Arrow snap: no steering, moving forwards on a road
                    // with one-axis arrows, within 25 degrees of the lane:
                    // a nudge of the heading toward it.
                    if (driven and !steering and !back and sp > 0 and (!player or pedal >= 8)) {
                        const cell = map.floorCell(sim.grid, t.x, t.y, t.z, T.car_step);
                        const arrows = map.arrowsOf(cell);
                        if (map.groundOf(cell) == map.Ground.road and arrows != 0) {
                            const along_x = arrows & (map.Arrow.pos_x | map.Arrow.neg_x) != 0;
                            const along_y = arrows & (map.Arrow.pos_y | map.Arrow.neg_y) != 0;
                            if (along_x != along_y) {
                                const base_h: u16 = if (along_x) 0 else 16384;
                                var err: i16 = @bitCast(base_h -% t.heading);
                                if (@abs(@as(i32, err)) > 16384) err = @bitCast(@as(u16, @bitCast(err)) +% 32768);
                                if (@abs(@as(i32, err)) <= T.snap_window) {
                                    const rate = if (m.long != 0) T.snap_rate >> 1 else T.snap_rate;
                                    const lim: i32 = radToAngle(fx.mul(rate, sp));
                                    t.heading +%= @as(u16, @bitCast(@as(i16, @intCast(std.math.clamp(@as(i32, err), -lim, lim)))));
                                }
                            }
                        }
                    }
                }
            }.f);
        }

        /// Damp velocity in the car's frame (lateral, longitudinal) and spin.
        /// When both world components are already tiny, the whole velocity
        /// takes the lateral factor and spin is left alone.
        fn damp(vel: *c.Velocity, heading: u16, lat: Fx, long: Fx, spin: Fx) void {
            if (fx.abs(vel.vx) <= T.slow_zone and fx.abs(vel.vy) <= T.slow_zone) {
                vel.vx = fx.mul(vel.vx, lat);
                vel.vy = fx.mul(vel.vy, lat);
                return;
            }
            const fwd_x = fx.cos(heading);
            const fwd_y = fx.sin(heading);
            const vf = fx.mul(fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y), long);
            const vl = fx.mul(fx.mul(vel.vx, -fwd_y) + fx.mul(vel.vy, fwd_x), lat);
            vel.vx = fx.mul(vf, fwd_x) - fx.mul(vl, fwd_y);
            vel.vy = fx.mul(vf, fwd_y) + fx.mul(vl, fwd_x);
            vel.spin = fx.mul(vel.spin, spin);
        }

        /// a / b in fixed point, for runtime integers.
        fn frac(a: i32, b: i32) Fx {
            return @intCast(@divTrunc(@as(i64, a) << fx.frac_bits, b));
        }

        /// Radians (fixed point) to angle units, rounded.
        fn radToAngle(r: Fx) u16 {
            const a: i64 = (@as(i64, r) * T.rad_to_angle + (1 << 15)) >> 16;
            return @truncate(@as(u64, @bitCast(a)));
        }

        /// Next (or previous) weapon that has rounds.
        fn cycleWeapon(wpn: *c.Weapon, forward: bool) void {
            var k: u8 = wpn.kind;
            var n: u8 = 0;
            while (n < T.weapon_count) : (n += 1) {
                k = if (forward) (k + 1) % T.weapon_count else (k + T.weapon_count - 1) % T.weapon_count;
                if (wpn.rounds()[k] != 0) {
                    wpn.kind = k;
                    return;
                }
            }
        }

        /// Fire held: one pull every `cooldown` ticks while there is ammo
        /// (weapons.md). Ammo is in tenths; a pull spends `tenths_per_pull`.
        /// The muzzle is a quarter block ahead, and the point halfway there
        /// must be clear of walls, or nothing is fired and nothing spent.
        fn sysWeapons(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Weapon, c.Controller, c.Transform, c.Velocity, c.Riding }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, wpn: *c.Weapon, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, ride: *c.Riding) void {
                    if (wpn.cooldown > 0) wpn.cooldown -= 1;
                    const ped = sim.state.world.get(id, c.Pedestrian);
                    if (!ride.vehicle.isNone() or (ped != null and ped.?.state != c.Pedestrian.state_up)) {
                        if (ped) |p| p.charge = 0;
                        return;
                    }
                    if (wpn.kind >= T.weapon_count) wpn.kind = T.weapon_pistol;
                    if (wpn.rounds()[wpn.kind] == 0 and (ped == null or ped.?.charge == 0)) cycleWeapon(wpn, false);
                    const k = wpn.kind;
                    const def = T.weapons[k];
                    const have = wpn.rounds()[k];
                    // Fast reload halves the wait after each shot.
                    const fast = ped != null and ped.?.fast_reload > 0;
                    if (def.shot == T.shot_grenade or def.shot == T.shot_molotov) {
                        if (ped) |p| sim.throwStep(id, wpn, p, ctl, t, vel, k, fast);
                        return;
                    }
                    if (ctl.in.buttons & Button.fire == 0 or wpn.cooldown != 0 or have == 0) return;
                    const hx = t.x + fx.mul(fx.cos(t.heading), T.muzzle_ahead >> 1);
                    const hy = t.y + fx.mul(fx.sin(t.heading), T.muzzle_ahead >> 1);
                    if (map.blocks(sim.grid, hx, hy, t.z, T.shot_height)) return;
                    if (map.moveHitsWall(sim.grid, t.x, t.y, hx, hy, t.z + T.shot_height, map.bullet)) return;
                    wpn.cooldown = if (fast) @max(1, def.cooldown >> 1) else def.cooldown;
                    if (have != T.infinite_ammo) wpn.rounds()[k] = have -| def.tenths_per_pull;
                    sim.scratch.stats.shots += 1;
                    if (def.shot == T.shot_electro) return sim.electro(id, t);
                    // Pellets fan out `spread` apart, centred on the aim.
                    const first = t.heading -% @as(u16, @truncate(@as(u32, def.spread) * (def.pellets - 1) / 2));
                    var p: u8 = 0;
                    while (p < def.pellets) : (p += 1) {
                        sim.fire(id, t, vel, first +% @as(u16, @truncate(@as(u32, def.spread) * p)), k, def);
                    }
                }
            }.f);
        }


        fn fire(self: *Self, shooter: EntityId, t: *const c.Transform, vel: *const c.Velocity, heading: u16, weapon: u8, def: T.WeaponDef) void {
            const dx = fx.cos(heading);
            const dy = fx.sin(heading);
            const st: c.Transform = .{ .x = t.x + fx.mul(dx, T.muzzle_ahead), .y = t.y + fx.mul(dy, T.muzzle_ahead), .z = t.z + T.shot_height, .heading = heading };
            if (self.predicting()) {
                self.pushIntent(.spawn, .projectile, shooter, st);
                return;
            }
            const w = &self.state.world;
            const sid = w.spawn(Shot) orelse return;
            w.get(sid, c.Transform).?.* = st;
            // Shots carry the shooter's own velocity (projectiles.md 3.1).
            w.get(sid, c.Velocity).?.* = .{ .vx = vel.vx + fx.mul(dx, def.speed), .vy = vel.vy + fx.mul(dy, def.speed), .vz = 0, .spin = 0 };
            w.get(sid, c.Projectile).?.* = .{ .owner = shooter, .ttl = def.ttl, .damage = 0, .weapon = weapon };
        }


        /// Grenades and molotovs (weapons.md 3.4): holding fire winds up a
        /// charge; letting go throws at strength min(charge, 60). A grenade
        /// held to a charge of 96 goes off in the hand.
        fn throwStep(self: *Self, id: EntityId, wpn: *c.Weapon, ped: *c.Pedestrian, ctl: *const c.Controller, t: *const c.Transform, vel: *const c.Velocity, k: u8, fast: bool) void {
            if (wpn.cooldown != 0) return;
            const have = wpn.rounds()[k];
            const spend = struct {
                fn f(wp: *c.Weapon, kk: u8, h: u16) void {
                    if (h != T.infinite_ammo) wp.rounds()[kk] = h -| T.weapons[kk].tenths_per_pull;
                }
            }.f;
            if (ctl.in.buttons & Button.fire != 0 and have > 0) {
                if (ped.charge < T.charge_max) ped.charge += 1;
                if (k == T.weapon_grenade and ped.charge >= T.grenade_in_hand) {
                    ped.charge = 0;
                    spend(wpn, k, have);
                    wpn.cooldown = if (fast) 2 else T.weapons[k].cooldown;
                    self.explodeAt(t.x, t.y, t.z, id, 0);
                }
                return;
            }
            if (ped.charge == 0) return;
            const charge = ped.charge;
            ped.charge = 0;
            if (have == 0) return;
            const strength: i32 = @min(charge, T.throw_strength_max);
            const base, const span = if (k == T.weapon_grenade) .{ T.grenade_speed_base, T.grenade_speed_span } else .{ T.molotov_speed_base, T.molotov_speed_span };
            const speed = base + @divTrunc(span * strength, T.throw_strength_max);
            const dx = fx.cos(t.heading);
            const dy = fx.sin(t.heading);
            var vx = fx.mul(dx, speed);
            var vy = fx.mul(dy, speed);
            // Moving forwards adds your own speed and a little more.
            if (fx.mul(vel.vx, dx) + fx.mul(vel.vy, dy) > 0) {
                vx += vel.vx + fx.mul(dx, T.throw_moving_bonus);
                vy += vel.vy + fx.mul(dy, T.throw_moving_bonus);
            }
            const st: c.Transform = .{ .x = t.x, .y = t.y, .z = t.z + T.throw_height, .heading = t.heading };
            if (map.blocks(self.grid, st.x, st.y, st.z, 0)) return;
            spend(wpn, k, have);
            wpn.cooldown = if (fast) 2 else T.weapons[k].cooldown;
            self.scratch.stats.shots += 1;
            if (self.predicting()) {
                self.pushIntent(.spawn, .projectile, id, st);
                return;
            }
            const w = &self.state.world;
            const sid = w.spawn(Shot) orelse return;
            w.get(sid, c.Transform).?.* = st;
            w.get(sid, c.Velocity).?.* = .{ .vx = vx, .vy = vy, .vz = T.throw_rise, .spin = 0 };
            const life: u16 = if (k == T.weapon_grenade) T.grenadeFuse(charge) else 600;
            w.get(sid, c.Projectile).?.* = .{ .owner = id, .ttl = life, .damage = 0, .weapon = k };
        }

        /// Electro gun, one tick (weapons.md 3.5): every ped or car in a
        /// 4 x 4 square around the shooter, within 45 degrees of his facing,
        /// a level up or down and in sight, takes a shock; then the same
        /// from each of them in a 2 x 2 square, aimed along the shooter's
        /// line to it. Two hops at most; nobody twice.
        fn electro(self: *Self, shooter: EntityId, t: *const c.Transform) void {
            if (self.predicting()) return;
            var hit: [12]EntityId = undefined;
            var n: usize = 0;
            hit[0] = shooter;
            n = 1;
            const first = self.electroHop(shooter, t.x, t.y, t.z, t.heading, T.electro_reach, &hit, &n);
            const end_first = n;
            var i: usize = first;
            while (i < end_first) : (i += 1) {
                const tt = self.state.world.get(hit[i], c.Transform) orelse continue;
                const dir = fx.atan2(tt.y - t.y, tt.x - t.x);
                _ = self.electroHop(shooter, tt.x, tt.y, tt.z, dir, T.electro_chain_reach, &hit, &n);
            }
        }

        /// One electro search from (x, y, z) along `dir`; hits go on the end
        /// of `hit`. Returns where this hop's hits start.
        fn electroHop(self: *Self, shooter: EntityId, x: Fx, y: Fx, z: Fx, dir: u16, reach: Fx, hit: *[12]EntityId, n: *usize) usize {
            const start = n.*;
            const Ctx = struct { sim: *Self, shooter: EntityId, x: Fx, y: Fx, z: Fx, dir: u16, reach: Fx, hit: *[12]EntityId, n: *usize };
            const ctx = Ctx{ .sim = self, .shooter = shooter, .x = x, .y = y, .z = z, .dir = dir, .reach = reach, .hit = hit, .n = n };
            const visit = struct {
                fn f(cx: Ctx, id: EntityId, tt: *c.Transform, col: *c.Collider) void {
                    if (cx.n.* >= cx.hit.len) return;
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    for (cx.hit[0..cx.n.*]) |h| if (eql(h, id)) return;
                    const dx = tt.x - cx.x;
                    const dy = tt.y - cx.y;
                    if (@max(fx.abs(dx), fx.abs(dy)) > cx.reach or fx.abs(tt.z - cx.z) > T.electro_reach_z) return;
                    if (dx != 0 or dy != 0) {
                        const off: i16 = @bitCast(fx.atan2(dy, dx) -% cx.dir);
                        if (@abs(off) > T.electro_cone) return;
                    }
                    const sim = cx.sim;
                    if (map.moveHitsWall(sim.grid, cx.x, cx.y, tt.x, tt.y, cx.z + T.shot_height, map.bullet)) return;
                    cx.hit[cx.n.*] = id;
                    cx.n.* += 1;
                    const w = &sim.state.world;
                    if (w.get(id, c.Vehicle) != null) {
                        sim.damageCar(id, @as(i64, T.weapons[T.weapon_electro].damage_car) << fx.frac_bits, cx.shooter);
                    } else if (w.get(id, c.Pedestrian)) |p| {
                        if (p.invulnerable == 0) p.shock +|= T.shock_gun;
                        w.get(id, c.Health).?.last_hit_by = cx.shooter;
                    }
                    sim.spark(tt.x, tt.y, tt.z, cx.shooter);
                }
            }.f;
            self.state.world.each(.{ c.Vehicle, c.Transform, c.Collider }, ctx, struct {
                fn f(cx: Ctx, id: EntityId, _: *c.Vehicle, tt: *c.Transform, col: *c.Collider) void {
                    visit(cx, id, tt, col);
                }
            }.f);
            self.state.world.each(.{ c.Pedestrian, c.Transform, c.Collider }, ctx, struct {
                fn f(cx: Ctx, id: EntityId, _: *c.Pedestrian, tt: *c.Transform, col: *c.Collider) void {
                    visit(cx, id, tt, col);
                }
            }.f);
            return start;
        }

        /// A projectile that only shows (an electric arc on a target): it
        /// stays put for two ticks and touches nothing.
        fn spark(self: *Self, x: Fx, y: Fx, z: Fx, by: EntityId) void {
            const w = &self.state.world;
            const id = w.spawn(Shot) orelse return;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = z + T.shot_height, .heading = 0 };
            w.get(id, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            w.get(id, c.Projectile).?.* = .{ .owner = by, .ttl = 2, .damage = c.Projectile.visual, .weapon = T.weapon_electro };
        }

        /// A fire on the ground (a molotov's): an explosion entity of kind
        /// `explosion_fire` that burns for `fire_ticks`. No event: clients
        /// draw it from the entity.
        fn startFire(self: *Self, x: Fx, y: Fx, z: Fx, by: EntityId) void {
            if (self.predicting()) return;
            const w = &self.state.world;
            const id = w.spawn(Shot) orelse return;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = z, .heading = 0 };
            w.get(id, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            w.get(id, c.Projectile).?.* = .{ .owner = by, .ttl = T.fire_ticks, .damage = 0, .weapon = c.Projectile.explosion_bit | T.explosion_fire };
        }

        /// Set ped `id` on fire, credited to `by`.
        fn ignite(self: *Self, id: EntityId, by: EntityId) void {
            if (!self.writable(id)) return;
            const w = &self.state.world;
            const p = w.get(id, c.Pedestrian) orelse return;
            if (p.invulnerable > 0 or !w.get(id, c.Riding).?.vehicle.isNone()) return;
            p.burn = T.burn_ticks;
            if (!by.isNone()) w.get(id, c.Health).?.last_hit_by = by;
        }

        /// Start an explosion (explosions-and-damage.md): an entity that
        /// stays put for 99 ticks and acts from the next tick. `kind` 0 is
        /// small (rockets), 1 a car. `by` is credited.
        fn explodeAt(self: *Self, x: Fx, y: Fx, z: Fx, by: EntityId, kind: u8) void {
            if (self.predicting()) return;
            self.scratch.stats.explosions += 1;
            self.pushEvent(.{ .kind = .explosion, .a = kind, .x = x, .y = y, .z = z });
            const w = &self.state.world;
            const id = w.spawn(Shot) orelse return;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = z, .heading = 0 };
            w.get(id, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
            w.get(id, c.Projectile).?.* = .{ .owner = by, .ttl = T.explosion_ticks, .damage = 0, .weapon = c.Projectile.explosion_bit | kind };
        }

        /// A fire on the ground, one tick: anyone standing in it catches
        /// fire; cars in it take fire damage every 8 ticks.
        fn burnAround(self: *Self, t: *const c.Transform, timer: u16, by: EntityId) void {
            const Ctx = struct { sim: *Self, t: c.Transform, timer: u16, by: EntityId };
            const ctx = Ctx{ .sim = self, .t = t.*, .timer = timer, .by = by };
            self.state.world.each(.{ c.Pedestrian, c.Transform }, ctx, struct {
                fn g(cx: Ctx, pid: EntityId, ped: *c.Pedestrian, pt: *c.Transform) void {
                    if (ped.burn > 0) return;
                    if (fx.abs(pt.z - cx.t.z) > T.explosion_reach_z) return;
                    if (@max(fx.abs(pt.x - cx.t.x), fx.abs(pt.y - cx.t.y)) > T.fire_radius) return;
                    cx.sim.ignite(pid, cx.by);
                }
            }.g);
            if (timer & 7 != 0) return;
            self.state.world.each(.{ c.Vehicle, c.Transform }, ctx, struct {
                fn g(cx: Ctx, cid: EntityId, _: *c.Vehicle, ct: *c.Transform) void {
                    if (fx.abs(ct.z - cx.t.z) > T.explosion_reach_z) return;
                    if (@max(fx.abs(ct.x - cx.t.x), fx.abs(ct.y - cx.t.y)) > T.fire_radius) return;
                    cx.sim.damageCar(cid, @as(i64, T.fire_car_damage) << fx.frac_bits, cx.by);
                }
            }.g);
        }

        fn isExplosion(p: *const c.Projectile) bool {
            return p.weapon & c.Projectile.explosion_bit != 0;
        }

        /// Every explosion, every tick: on its first tick it pushes cars
        /// outward; while its timer is above 50 it throws peds and, in two
        /// windows, wrecks cars in its radius. Distances are square
        /// (Chebyshev), with a vertical reach of 0.2.
        fn sysExplosions(self: *Self) void {
            if (self.predicting()) return;
            self.state.world.each(.{ c.Transform, c.Projectile }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, p: *c.Projectile) void {
                    if (!isExplosion(p)) return;
                    if (p.ttl == 0) return sim.kill(id);
                    const timer = p.ttl;
                    p.ttl -= 1;
                    if (p.weapon & 3 == T.explosion_fire) return sim.burnAround(t, timer, p.owner);
                    const r = if (p.weapon & 3 == 1) T.explosion_car else T.explosion_small;
                    const Ctx = struct { sim: *Self, x: Fx, y: Fx, z: Fx, r: Fx, timer: u16, by: EntityId };
                    const ctx = Ctx{ .sim = sim, .x = t.x, .y = t.y, .z = t.z, .r = r, .timer = timer, .by = p.owner };
                    const car_window = (timer >= 81 and timer <= 89) or (timer >= 51 and timer <= 59);
                    if (timer == T.explosion_ticks or car_window) {
                        sim.state.world.each(.{ c.Vehicle, c.Transform, c.Velocity }, ctx, struct {
                            fn g(cx: Ctx, cid: EntityId, v: *c.Vehicle, ct: *c.Transform, vel: *c.Velocity) void {
                                if (v.flags & c.Vehicle.flag_wrecked != 0) return;
                                if (fx.abs(ct.z - cx.z) > T.explosion_reach_z) return;
                                const dx = ct.x - cx.x;
                                const dy = ct.y - cx.y;
                                if (@max(fx.abs(dx), fx.abs(dy)) > cx.r) return;
                                if (cx.timer == T.explosion_ticks) {
                                    // Outward push of 1 / (4 x distance), by mass.
                                    const d = @max(fx.length(dx, dy), fx.ratio(1, 4));
                                    const imp = fx.div(fx.one, d * 4);
                                    const dv = fx.div(imp, T.carModel(v.model).mass);
                                    vel.vx += fx.mul(fx.div(dx, d), dv);
                                    vel.vy += fx.mul(fx.div(dy, d), dv);
                                } else {
                                    cx.sim.damageCar(cid, @as(i64, T.blast_car_damage) << fx.frac_bits, cx.by);
                                }
                            }
                        }.g);
                    }
                    if (timer <= T.explosion_active_above) return;
                    sim.state.world.each(.{ c.Pedestrian, c.Transform, c.Riding, c.Controller }, ctx, struct {
                        fn g(cx: Ctx, pid: EntityId, ped: *c.Pedestrian, pt: *c.Transform, ride: *c.Riding, ctl: *c.Controller) void {
                            if (ped.state != c.Pedestrian.state_up or !ride.vehicle.isNone()) return;
                            if (fx.abs(pt.z - cx.z) > T.explosion_reach_z) return;
                            const dx = pt.x - cx.x;
                            const dy = pt.y - cx.y;
                            const d = @max(fx.abs(dx), fx.abs(dy));
                            if (d > 2 * cx.r) return;
                            const len = fx.length(dx, dy);
                            const nx = if (len == 0) fx.one else fx.div(dx, len);
                            const ny = if (len == 0) 0 else fx.div(dy, len);
                            const S = c.Pedestrian;
                            if (d <= cx.r >> 1) {
                                cx.sim.knock(pid, S.state_fatal, nx, ny, T.blast_throw, T.blast_lift_close, cx.by);
                            } else if (d <= cx.r) {
                                const player = ctl.player != c.Controller.no_player;
                                cx.sim.knock(pid, if (player) S.state_down else S.state_fatal, nx, ny, T.blast_throw, T.blast_lift, cx.by);
                            } else if (cx.timer > T.explosion_knock_above) {
                                cx.sim.knock(pid, S.state_over, nx, ny, T.blast_knock, 0, cx.by);
                            }
                        }
                    }.g);
                }
            }.f);
        }

        // ------------------------------------------------------------------
        // Movement against the map

        /// Sample points of a circle body: centre, four axis points, four
        /// diagonals. A void under the centre also blocks.
        fn circleBlocked(self: *const Self, x: Fx, y: Fx, z: Fx, r: Fx, step_h: Fx) bool {
            const d = fx.mul(r, fx.ratio(70711, 100000));
            const pts = [_][2]Fx{
                .{ 0, 0 }, .{ r, 0 }, .{ -r, 0 }, .{ 0, r }, .{ 0, -r },
                .{ d, d }, .{ d, -d }, .{ -d, d }, .{ -d, -d },
            };
            if (map.isVoid(self.grid, x, y, z + step_h)) return true;
            for (pts) |p| {
                if (map.blocks(self.grid, x + p[0], y + p[1], z, step_h)) return true;
            }
            // Wall faces, against the body's square (a ped is a small
            // square: shape-and-map-collision.md 2).
            return map.rectHitsWall(self.grid, map.Rect.square(x, y, r), z, step_h);
        }

        /// Sample points of a car's box: corners, side midpoints and the
        /// middle of the front and back.
        fn boxBlocked(self: *const Self, x: Fx, y: Fx, z: Fx, heading: u16, m: *const T.CarModel) bool {
            const cx = fx.cos(heading);
            const sy = fx.sin(heading);
            const pts = [_][2]Fx{
                .{ m.half_len, m.half_wid },  .{ m.half_len, -m.half_wid }, .{ -m.half_len, m.half_wid }, .{ -m.half_len, -m.half_wid },
                .{ 0, m.half_wid },           .{ 0, -m.half_wid },          .{ m.half_len, 0 },           .{ -m.half_len, 0 },
            };
            for (pts, 0..) |p, i| {
                const px = x + fx.mul(p[0], cx) - fx.mul(p[1], sy);
                const py = y + fx.mul(p[0], sy) + fx.mul(p[1], cx);
                if (map.blocks(self.grid, px, py, z, T.car_step)) return true;
                // Voids: checked at the middle of the front and the back.
                if (i >= 6 and map.isVoid(self.grid, px, py, z + T.car_step)) return true;
            }
            return map.rectHitsWall(self.grid, .{ .x = x, .y = y, .cos = cx, .sin = sy, .a = m.half_len, .b = m.half_wid }, z, T.car_step);
        }

        fn substeps(vel: *const c.Velocity) i32 {
            const m = @max(fx.abs(vel.vx), fx.abs(vel.vy));
            return @max(1, @divTrunc(m + T.max_substep - 1, T.max_substep));
        }

        /// Gravity, floor following and landing for any body.
        fn settle(self: *const Self, t: *c.Transform, vel: *c.Velocity, col: *c.Collider, step_h: Fx, grav: Fx, max_fall: Fx) void {
            const floor = map.floorAt(self.grid, t.x, t.y, t.z, step_h);
            const grounded = col.flags & c.Collider.flag_grounded != 0;
            if (grounded and vel.vz <= 0 and floor >= t.z - T.snap_down) {
                t.z = floor;
                vel.vz = 0;
                return;
            }
            vel.vz = @max(vel.vz - grav, -max_fall);
            // Rising into a ceiling stops the rise.
            if (vel.vz > 0 and map.blocks(self.grid, t.x, t.y, t.z + vel.vz, step_h)) vel.vz = 0;
            t.z += vel.vz;
            if (t.z <= floor) {
                t.z = floor;
                vel.vz = 0;
                col.flags |= c.Collider.flag_grounded;
            } else col.flags &= ~c.Collider.flag_grounded;
        }


        /// A car's height (car-height.md 3.1-3.4): it follows the ground
        /// down by up to half a block; further, it is tipped over the edge
        /// while a corner is still on the ground, then leaves the ground at
        /// the rate it was climbing or descending, falling with gravity 1/64.
        fn carSettle(self: *const Self, t: *c.Transform, vel: *c.Velocity, col: *c.Collider, m: *const T.CarModel) void {
            const floor = map.floorAt(self.grid, t.x, t.y, t.z, T.car_step);
            if (col.flags & c.Collider.flag_grounded != 0 and vel.vz <= 0) {
                if (floor >= t.z - T.car_drop) {
                    t.z = floor;
                    vel.vz = 0;
                    return;
                }
                // Off the edge while climbing (a ramp top): leave the
                // ground at the rate of the last step, a ramp jump.
                const b1 = map.floorAt(self.grid, t.x - vel.vx, t.y - vel.vy, t.z, T.car_step);
                const b2 = map.floorAt(self.grid, t.x - 2 * vel.vx, t.y - 2 * vel.vy, t.z, T.car_step);
                const rate = b1 - b2;
                if (rate > 0 and rate < T.car_drop) {
                    vel.vz = rate;
                } else {
                    // Centre over a drop: corners still on the ground tip
                    // it over the edge, and it stays up until none are.
                    const cs = fx.cos(t.heading);
                    const sn = fx.sin(t.heading);
                    const corners = [_][2]Fx{ .{ m.half_len, m.half_wid }, .{ m.half_len, -m.half_wid }, .{ -m.half_len, m.half_wid }, .{ -m.half_len, -m.half_wid } };
                    var supported = false;
                    var push: [2]Fx = .{ 0, 0 };
                    for (corners) |cn| {
                        const o = [2]Fx{ fx.mul(cn[0], cs) - fx.mul(cn[1], sn), fx.mul(cn[0], sn) + fx.mul(cn[1], cs) };
                        const f = map.floorAt(self.grid, t.x + o[0], t.y + o[1], t.z, T.car_step);
                        if (f >= t.z - T.car_drop) {
                            supported = true;
                        } else {
                            push[0] += @divTrunc(o[0], T.car_tip_div);
                            push[1] += @divTrunc(o[1], T.car_tip_div);
                        }
                    }
                    if (supported) {
                        // Moved straight away (ours), so the parked-car
                        // damping does not cancel the push.
                        if (!self.boxBlocked(t.x + push[0], t.y + push[1], t.z, t.heading, m)) {
                            t.x += push[0];
                            t.y += push[1];
                        }
                        return;
                    }
                    vel.vz = if (rate < 0 and rate > -T.car_drop) rate else 0;
                }
                col.flags &= ~c.Collider.flag_grounded;
            }
            vel.vz = @max(vel.vz - T.car_gravity, -T.car_max_fall);
            // Rising into a ceiling stops the rise.
            if (vel.vz > 0 and map.blocks(self.grid, t.x, t.y, t.z + vel.vz, T.car_step)) vel.vz = 0;
            t.z = @min(t.z + vel.vz, T.car_ceiling);
            if (t.z <= floor) {
                t.z = floor;
                vel.vz = 0;
                col.flags |= c.Collider.flag_grounded;
            } else col.flags &= ~c.Collider.flag_grounded;
        }

        /// Peds move a step at a time; a blocked step slides along one map
        /// axis at half speed (ped-movement.md 3.3). Mid-jump a ped never
        /// drops below the height he jumped from (3.6). Knocked bodies are
        /// thrown and slide (`moveThrown`).
        fn sysMovePeds(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Transform, c.Velocity, c.Collider }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, ped: *c.Pedestrian, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    if (ped.state != c.Pedestrian.state_up) return sim.moveThrown(id, ped, t, vel, col);
                    const n = substeps(vel);
                    const sx = @divTrunc(vel.vx, n);
                    const sy = @divTrunc(vel.vy, n);
                    var i: i32 = 0;
                    while (i < n) : (i += 1) {
                        if (!sim.pedBlocked(t.x, t.y, t.x + sx, t.y + sy, t.z)) {
                            t.x += sx;
                            t.y += sy;
                            continue;
                        }
                        const hx = sx >> T.ped_slide_shift;
                        const hy = sy >> T.ped_slide_shift;
                        const x_first = fx.abs(sx) >= fx.abs(sy);
                        if (x_first and hx != 0 and !sim.pedBlocked(t.x, t.y, t.x + hx, t.y, t.z)) {
                            t.x += hx;
                        } else if (hy != 0 and !sim.pedBlocked(t.x, t.y, t.x, t.y + hy, t.z)) {
                            t.y += hy;
                        } else if (!x_first and hx != 0 and !sim.pedBlocked(t.x, t.y, t.x + hx, t.y, t.z)) {
                            t.x += hx;
                        }
                    }
                    if (ped.jump > 0) {
                        // Up a step if the ground rises; never down.
                        const floor = map.floorAt(sim.grid, t.x, t.y, t.z, T.ped_step);
                        if (floor > t.z) t.z = floor;
                        vel.vz = 0;
                        col.flags |= c.Collider.flag_grounded;
                        return;
                    }
                    sim.settle(t, vel, col, T.ped_step, T.ped_gravity, T.ped_max_fall);
                }
            }.f);
        }

        /// Can a ped at (x0, y0) step to (x1, y1)? A step can be longer
        /// than the ped is wide, so a wall face is also looked for halfway.
        fn pedBlocked(self: *const Self, x0: Fx, y0: Fx, x1: Fx, y1: Fx, z: Fx) bool {
            if (self.circleBlocked(x1, y1, z, T.ped_radius, T.ped_step)) return true;
            const mx = x0 + ((x1 - x0) >> 1);
            const my = y0 + ((y1 - y0) >> 1);
            return map.rectHitsWall(self.grid, map.Rect.square(mx, my, T.ped_radius), z, T.ped_step);
        }

        /// A knocked ped (explosions-and-damage.md 3.9): carried at its
        /// speed with gravity 0.02, stopped by walls, sliding to rest on the
        /// ground. At rest: a fatal throw kills; otherwise he lies for
        /// `down` ticks and gets up.
        fn moveThrown(self: *Self, id: EntityId, ped: *c.Pedestrian, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
            ped.anim = c.Pedestrian.anim_down;
            ped.jump = 0;
            ped.turn = 0;
            const n = substeps(vel);
            const sx = @divTrunc(vel.vx, n);
            const sy = @divTrunc(vel.vy, n);
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                if (sx != 0) {
                    if (self.pedBlocked(t.x, t.y, t.x + sx, t.y, t.z)) vel.vx = 0 else t.x += sx;
                }
                if (sy != 0) {
                    if (self.pedBlocked(t.x, t.y, t.x, t.y + sy, t.z)) vel.vy = 0 else t.y += sy;
                }
            }
            const in_air = col.flags & c.Collider.flag_grounded == 0 or vel.vz > 0;
            self.settle(t, vel, col, T.ped_step, T.thrown_gravity, T.max_fall);
            if (in_air) return;
            // Sliding on the ground.
            const sp = fx.length(vel.vx, vel.vy);
            if (sp > T.thrown_friction) {
                const k = fx.div(sp - T.thrown_friction, sp);
                vel.vx = fx.mul(vel.vx, k);
                vel.vy = fx.mul(vel.vy, k);
                return;
            }
            vel.vx = 0;
            vel.vy = 0;
            if (ped.state == c.Pedestrian.state_fatal) {
                if (self.state.world.get(id, c.Health)) |h| h.hp = 0;
                return;
            }
            if (ped.down > 0) {
                ped.down -= 1;
                return;
            }
            ped.state = c.Pedestrian.state_up;
            ped.anim = c.Pedestrian.anim_stand;
        }

        /// Knock ped `id` off his feet: thrown along (nx, ny) at `speed`,
        /// rising at `lift`. `by` is credited if he dies of it.
        fn knock(self: *Self, id: EntityId, state: u8, nx: Fx, ny: Fx, speed: Fx, lift: Fx, by: EntityId) void {
            if (!self.writable(id)) return;
            const w = &self.state.world;
            const ped = w.get(id, c.Pedestrian) orelse return;
            if (!w.get(id, c.Riding).?.vehicle.isNone()) return;
            // Invulnerable: every knock is the mildest kind.
            ped.state = if (ped.invulnerable > 0) c.Pedestrian.state_over else state;
            ped.down = if (state == c.Pedestrian.state_over) T.knock_over_ticks else T.knock_down_ticks;
            ped.jump = 0;
            ped.turn = 0;
            ped.anim = c.Pedestrian.anim_down;
            const vel = w.get(id, c.Velocity).?;
            vel.* = .{ .vx = fx.mul(nx, speed), .vy = fx.mul(ny, speed), .vz = lift, .spin = 0 };
            if (lift > 0) w.get(id, c.Collider).?.flags &= ~c.Collider.flag_grounded;
            if (!by.isNone()) w.get(id, c.Health).?.last_hit_by = by;
        }

        /// A ped is killed where he stands (by a hit that kills outright).
        fn killPed(self: *Self, id: EntityId, by: EntityId) void {
            if (!self.writable(id)) return;
            if (self.state.world.get(id, c.Pedestrian)) |p| {
                // Invulnerable: knocked over, never killed.
                if (p.invulnerable > 0) return self.knock(id, c.Pedestrian.state_over, fx.one, 0, 0, 0, by);
            }
            const h = self.state.world.get(id, c.Health) orelse return;
            h.hp = 0;
            if (!by.isNone()) h.last_hit_by = by;
        }

        fn sysMoveCars(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Vehicle, c.Transform, c.Velocity, c.Collider }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    const m = T.carModel(v.model);
                    // Rotate first; a turn that would put a corner in a wall
                    // does not happen.
                    if (vel.spin != 0) {
                        const h = t.heading +% radToAngle(vel.spin);
                        if (sim.boxBlocked(t.x, t.y, t.z, h, m)) {
                            vel.spin = 0;
                        } else t.heading = h;
                    }
                    const n = substeps(vel);
                    var i: i32 = 0;
                    while (i < n) : (i += 1) {
                        const sx = @divTrunc(vel.vx, n);
                        const sy = @divTrunc(vel.vy, n);
                        if (sx != 0) {
                            if (sim.boxBlocked(t.x + sx, t.y, t.z, t.heading, m)) {
                                sim.wallHit(id, vel, true, m);
                            } else t.x += sx;
                        }
                        if (sy != 0) {
                            if (sim.boxBlocked(t.x, t.y + sy, t.z, t.heading, m)) {
                                sim.wallHit(id, vel, false, m);
                            } else t.y += sy;
                        }
                    }
                    sim.carSettle(t, vel, col, m);
                }
            }.f);
        }

        /// Bounce off a wall along one axis (restitution 0.25) and scrub some
        /// speed along the other. The impulse, (1 + e) x speed x mass,
        /// damages the car (car-collision.md 3.5).
        fn wallHit(self: *Self, id: EntityId, vel: *c.Velocity, x_axis: bool, m: *const T.CarModel) void {
            self.scratch.stats.wall_hits += 1;
            const vn = fx.abs(if (x_axis) vel.vx else vel.vy);
            if (vn > T.impact_min_speed) {
                const j: i64 = (@as(i64, vn) * m.mass * (8 + m.restitution_8ths)) >> (fx.frac_bits + 3);
                self.damageCar(id, j * T.impact_damage, .none);
            }
            if (x_axis) {
                vel.vx = -@divTrunc(vel.vx * m.restitution_8ths, 8);
                vel.vy -= vel.vy >> 3;
            } else {
                vel.vy = -@divTrunc(vel.vy * m.restitution_8ths, 8);
                vel.vx -= vel.vx >> 3;
            }
        }

        fn sysMoveProjectiles(self: *Self) void {
            if (self.predicting()) return; // not predicted; replicated only
            self.state.world.each(.{ c.Transform, c.Velocity, c.Projectile }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile) void {
                    if (isExplosion(p)) return;
                    const shot = T.weapons[@min(p.weapon, T.weapon_count - 1)].shot;
                    if (p.damage != c.Projectile.visual and (shot == T.shot_grenade or shot == T.shot_molotov)) return sim.moveThrownShot(id, t, vel, p, shot);
                    // Out of range: gone (a rocket too, without exploding).
                    if (p.ttl == 0) return sim.kill(id);
                    p.ttl -= 1;
                    if (p.damage == c.Projectile.visual) return;
                    const explosive = p.weapon < T.weapon_count and T.weapons[p.weapon].explosive;
                    const base = t.z - T.shot_height;
                    // Four samples along the move, so a fast round cannot
                    // skip the corner of a block.
                    var i: i32 = 1;
                    while (i <= 4) : (i += 1) {
                        const x = t.x + @divTrunc(vel.vx * i, 4);
                        const y = t.y + @divTrunc(vel.vy * i, 4);
                        const px = t.x + @divTrunc(vel.vx * (i - 1), 4);
                        const py = t.y + @divTrunc(vel.vy * (i - 1), 4);
                        if (map.blocks(sim.grid, x, y, base, T.shot_height) or map.moveHitsWall(sim.grid, px, py, x, y, t.z, map.bullet)) {
                            if (explosive) {
                                // Blow up just short of the wall.
                                sim.explodeAt(px, py, base, p.owner, 0);
                            }
                            t.x = x;
                            t.y = y;
                            p.ttl = 0;
                            return sim.kill(id);
                        }
                    }
                    t.x += vel.vx;
                    t.y += vel.vy;
                }
            }.f);
        }

        /// A thrown grenade or molotov (projectiles.md 3.1): falls with
        /// gravity 1/512, bounces off walls and the ground (ours: keeping
        /// half its speed), rolls with friction 0.01 a tick. A grenade goes
        /// off when its fuse (`ttl`) runs out; a molotov bursts into fire on
        /// any contact.
        fn moveThrownShot(self: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile, shot: u8) void {
            const molotov = shot == T.shot_molotov;
            if (p.ttl == 0) {
                if (molotov) self.startFire(t.x, t.y, map.floorAt(self.grid, t.x, t.y, t.z, fx.ratio(1, 8)), p.owner) else self.explodeAt(t.x, t.y, t.z, p.owner, 0);
                return self.kill(id);
            }
            p.ttl -= 1;
            const lift = fx.ratio(1, 8);
            if (vel.vx != 0) {
                const nx = t.x + vel.vx;
                if (map.blocks(self.grid, nx, t.y, t.z, lift) or map.moveHitsWall(self.grid, t.x, t.y, nx, t.y, t.z + lift, 0)) {
                    if (molotov) return self.burstMolotov(id, t, p);
                    vel.vx = -@divTrunc(vel.vx * T.bounce_8ths, 8);
                } else t.x = nx;
            }
            if (vel.vy != 0) {
                const ny = t.y + vel.vy;
                if (map.blocks(self.grid, t.x, ny, t.z, lift) or map.moveHitsWall(self.grid, t.x, t.y, t.x, ny, t.z + lift, 0)) {
                    if (molotov) return self.burstMolotov(id, t, p);
                    vel.vy = -@divTrunc(vel.vy * T.bounce_8ths, 8);
                } else t.y = ny;
            }
            const floor = map.floorAt(self.grid, t.x, t.y, t.z, lift);
            vel.vz -= T.throw_gravity;
            t.z += vel.vz;
            if (t.z <= floor) {
                t.z = floor;
                if (molotov) return self.burstMolotov(id, t, p);
                vel.vz = if (vel.vz < -fx.ratio(2, 100)) -@divTrunc(vel.vz * T.bounce_8ths, 8) else 0;
                // Rolling: friction takes 0.01 a tick off the speed.
                const sp = fx.length(vel.vx, vel.vy);
                if (sp <= T.throw_friction) {
                    vel.vx = 0;
                    vel.vy = 0;
                } else {
                    vel.vx = @intCast(@divTrunc(@as(i64, vel.vx) * (sp - T.throw_friction), sp));
                    vel.vy = @intCast(@divTrunc(@as(i64, vel.vy) * (sp - T.throw_friction), sp));
                }
            }
        }

        fn burstMolotov(self: *Self, id: EntityId, t: *const c.Transform, p: *c.Projectile) void {
            self.startFire(t.x, t.y, map.floorAt(self.grid, t.x, t.y, t.z, fx.ratio(1, 8)), p.owner);
            p.ttl = 0;
            self.kill(id);
        }

        // ------------------------------------------------------------------
        // Contacts between bodies

        fn cellOf(x: Fx, y: Fx) u32 {
            const cx: u32 = @intCast(std.math.clamp(x >> cell_shift, 0, cells_x - 1));
            const cy: u32 = @intCast(std.math.clamp(y >> cell_shift, 0, cells_y - 1));
            return cy * cells_x + cx;
        }

        fn addEntry(self: *Self, id: EntityId, t: *const c.Transform, r: Fx, mass: i32) void {
            const sc = &self.scratch;
            const cell = cellOf(t.x, t.y);
            if (sc.cell_stamp[cell] != sc.stamp) {
                sc.cell_stamp[cell] = sc.stamp;
                sc.cell_head[cell] = nil;
            }
            sc.entries[sc.n] = .{ .id = id, .x = t.x, .y = t.y, .z = t.z, .r = r, .mass = mass, .movable = self.writable(id), .next = sc.cell_head[cell] };
            sc.cell_head[cell] = sc.n;
            sc.n += 1;
        }

        /// Uniform grid of 2x2-block cells, rebuilt every tick from state, so
        /// it never needs saving. In predict mode it holds every body: the
        /// unpredicted ones are fixed obstacles.
        fn buildBroadphase(self: *Self) void {
            const sc = &self.scratch;
            sc.n = 0;
            sc.stamp +%= 1;
            if (sc.stamp == 0) {
                @memset(&sc.cell_stamp, 0);
                sc.stamp = 1;
            }
            self.state.world.each(.{ c.Vehicle, c.Transform, c.Collider }, self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, t: *c.Transform, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    const m = T.carModel(v.model);
                    sim.addEntry(id, t, m.radius, m.mass);
                }
            }.f);
            self.state.world.each(.{ c.Pedestrian, c.Transform, c.Collider }, self, struct {
                fn f(sim: *Self, id: EntityId, _: *c.Pedestrian, t: *c.Transform, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    sim.addEntry(id, t, T.ped_radius, T.ped_mass);
                }
            }.f);
        }

        fn sysContacts(self: *Self) void {
            const sc = &self.scratch;
            var i: u32 = 0;
            while (i < sc.n) : (i += 1) {
                const a = sc.entries[i];
                const ccx: i32 = std.math.clamp(a.x >> cell_shift, 0, cells_x - 1);
                const ccy: i32 = std.math.clamp(a.y >> cell_shift, 0, cells_y - 1);
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
                            if (j <= i) continue; // each pair once, in entry order
                            self.resolvePair(&sc.entries[i], &sc.entries[j]);
                        }
                    }
                }
            }
        }

        fn resolvePair(self: *Self, a: *Entry, b: *Entry) void {
            if (!a.movable and !b.movable) return;
            const a_car = a.id.kind() == @intFromEnum(abi.Kind.car);
            const b_car = b.id.kind() == @intFromEnum(abi.Kind.car);
            if (a_car and !b_car) return self.carPed(a, b);
            if (b_car and !a_car) return self.carPed(b, a);
            const w = &self.state.world;
            const ta = w.get(a.id, c.Transform).?;
            const tb = w.get(b.id, c.Transform).?;
            if (fx.abs(ta.z - tb.z) > fx.half) return;
            const ddx = tb.x - ta.x;
            const ddy = tb.y - ta.y;
            const rr = a.r + b.r;
            if (fx.abs(ddx) >= rr or fx.abs(ddy) >= rr) return;
            const d = fx.length(ddx, ddy);
            if (d >= rr) return;
            self.scratch.stats.contacts += 1;
            const va = w.get(a.id, c.Velocity).?;
            const vb = w.get(b.id, c.Velocity).?;
            // Normal (unit) from a to b; coincident bodies push along +x.
            const nx = if (d == 0) fx.one else fx.div(ddx, d);
            const ny = if (d == 0) 0 else fx.div(ddy, d);
            const pen = rr - d;
            // An immovable side acts as infinitely heavy.
            const ma: i64 = if (a.movable) a.mass else 1 << 40;
            const mb: i64 = if (b.movable) b.mass else 1 << 40;
            const total = ma + mb;
            const push_a: Fx = @intCast(@divTrunc(@as(i64, pen) * mb, total));
            const push_b = pen - push_a;
            // Do not push a body into a wall.
            const ma_step: Fx = if (a_car) T.car_step else T.ped_step;
            const mb_step: Fx = if (b_car) T.car_step else T.ped_step;
            if (a.movable) {
                const x = ta.x - fx.mul(nx, push_a);
                const y = ta.y - fx.mul(ny, push_a);
                if (!self.circleBlocked(x, y, ta.z, fx.ratio(1, 8), ma_step)) {
                    ta.x = x;
                    ta.y = y;
                }
            }
            if (b.movable) {
                const x = tb.x + fx.mul(nx, push_b);
                const y = tb.y + fx.mul(ny, push_b);
                if (!self.circleBlocked(x, y, tb.z, fx.ratio(1, 8), mb_step)) {
                    tb.x = x;
                    tb.y = y;
                }
            }
            // Exchange normal momentum: car against car bounces with
            // restitution 0.5 (car-collision.md); peds just stop.
            const rel = fx.mul(vb.vx - va.vx, nx) + fx.mul(vb.vy - va.vy, ny);
            if (rel < 0) {
                const e8: i64 = if (a_car) 8 + T.car_restitution_8ths else 8;
                const imp_a: Fx = @intCast(@divTrunc(@as(i64, rel) * mb * e8, total * 8));
                const imp_b: Fx = @intCast(@divTrunc(@as(i64, rel) * ma * e8, total * 8));
                if (a.movable) {
                    va.vx += fx.mul(nx, imp_a);
                    va.vy += fx.mul(ny, imp_a);
                }
                if (b.movable) {
                    vb.vx -= fx.mul(nx, imp_b);
                    vb.vy -= fx.mul(ny, imp_b);
                }
                // Damage from the impulse, both cars alike, credited to the
                // other car (its driver).
                if (a_car and -rel > T.impact_min_speed) {
                    self.scratch.stats.impacts += 1;
                    const m_eff: i64 = @intCast(@divTrunc(@as(i128, ma) * mb, total));
                    const j: i64 = @divTrunc(-@as(i64, rel) * m_eff * e8, 8 << fx.frac_bits);
                    self.damageCar(a.id, j * T.impact_damage, b.id);
                    self.damageCar(b.id, j * T.impact_damage, a.id);
                }
            }
            a.x = ta.x;
            a.y = ta.y;
            b.x = tb.x;
            b.y = tb.y;
        }

        /// A car touching a ped (car-collision.md 3.6): the ped is pushed
        /// clear and, if the car was moving into him, handed a knock-back
        /// of 2 x the car's closing speed x mc / (mc + 0.5) (restitution 1,
        /// ped mass 0.5). The car takes nothing.
        fn carPed(self: *Self, car: *Entry, ped: *Entry) void {
            if (!ped.movable) return;
            const w = &self.state.world;
            const tc = w.get(car.id, c.Transform).?;
            const tp = w.get(ped.id, c.Transform).?;
            if (fx.abs(tc.z - tp.z) > fx.half) return;
            const ddx = tp.x - tc.x;
            const ddy = tp.y - tc.y;
            const rr = car.r + ped.r;
            if (fx.abs(ddx) >= rr or fx.abs(ddy) >= rr) return;
            const d = fx.length(ddx, ddy);
            if (d >= rr) return;
            self.scratch.stats.contacts += 1;
            const nx = if (d == 0) fx.one else fx.div(ddx, d);
            const ny = if (d == 0) 0 else fx.div(ddy, d);
            const x = tp.x + fx.mul(nx, rr - d);
            const y = tp.y + fx.mul(ny, rr - d);
            if (!self.circleBlocked(x, y, tp.z, fx.ratio(1, 8), T.ped_step)) {
                tp.x = x;
                tp.y = y;
            }
            ped.x = tp.x;
            ped.y = tp.y;
            const vc = w.get(car.id, c.Velocity).?;
            const closing = fx.mul(vc.vx, nx) + fx.mul(vc.vy, ny);
            if (closing <= T.car_hit_min) return;
            const mc: i64 = car.mass;
            var k: Fx = @intCast(@divTrunc(2 * @as(i64, closing) * mc, mc + T.ped_mass));
            k = @max(k, fx.ratio(1, 16));
            self.carHitPed(car.id, ped.id, nx, ny, k);
        }

        /// What a car hit does to a ped (ped-movement.md 3.8), for a
        /// knock-back of length `k` along (nx, ny).
        fn carHitPed(self: *Self, car: EntityId, ped: EntityId, nx: Fx, ny: Fx, k: Fx) void {
            const w = &self.state.world;
            const pd = w.get(ped, c.Pedestrian) orelse return;
            if (!w.get(ped, c.Riding).?.vehicle.isNone()) return;
            const v = w.get(car, c.Vehicle).?;
            if (v.flags & c.Vehicle.flag_ai != 0 and self.writable(car)) v.halt = T.traffic_hit_stop;
            const player = w.get(ped, c.Controller).?.player != c.Controller.no_player;
            const lying = pd.state != c.Pedestrian.state_up;
            var player_driving = false;
            if (w.get(v.driver, c.Controller)) |dc| player_driving = dc.player != c.Controller.no_player;
            const S = c.Pedestrian;
            if (k < T.knock_light) {
                if (lying) self.killPed(ped, car) else self.knock(ped, S.state_over, nx, ny, k, 0, car);
            } else if (!player or k >= T.knock_hard) {
                self.killPed(ped, car);
            } else if (k < T.knock_mid) {
                self.knock(ped, if (player_driving) S.state_fatal else S.state_down, nx, ny, k >> 1, T.knock_lift_light, car);
            } else if (!player_driving and !lying) {
                self.knock(ped, S.state_down, nx, ny, k >> 1, T.knock_lift_mid, car);
            } else {
                self.killPed(ped, car);
            }
        }


        fn hurt(self: *Self, id: EntityId, dmg: i32, by: EntityId) void {
            if (!self.writable(id)) return;
            if (self.state.world.get(id, c.Pedestrian)) |p| {
                if (p.invulnerable > 0) return;
            }
            if (self.state.world.get(id, c.Health)) |h| {
                h.hp -= dmg;
                h.last_hit_by = by;
            }
        }

        /// Add `raw` damage (fixed point, 16 fraction bits) to a car, scaled
        /// by its model's anti-strength: at least 1 unless that is 0, up to
        /// the 32000 cap; a wreck takes none (car-collision.md 3.5).
        fn damageCar(self: *Self, id: EntityId, raw: i64, by: EntityId) void {
            if (!self.writable(id)) return;
            const w = &self.state.world;
            const v = w.get(id, c.Vehicle) orelse return;
            if (v.flags & c.Vehicle.flag_wrecked != 0) return;
            const anti: i64 = T.carModel(v.model).anti_strength;
            if (anti == 0) return;
            const dmg: i64 = @max(1, (raw * anti) >> (2 * fx.frac_bits));
            const h = w.get(id, c.Health).?;
            h.hp = @intCast(@max(0, h.hp - @min(dmg, T.car_damage_max)));
            if (!by.isNone()) h.last_hit_by = by;
        }

        fn sysProjectileHits(self: *Self) void {
            if (self.predicting()) return;
            self.state.world.each(.{ c.Transform, c.Velocity, c.Projectile }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile) void {
                    if (isExplosion(p) or p.damage == c.Projectile.visual) return;
                    const shot = T.weapons[@min(p.weapon, T.weapon_count - 1)].shot;
                    if (shot == T.shot_grenade) return; // grenades go off by their fuse
                    const sc = &sim.scratch;
                    // Swept test: the segment travelled this tick against each
                    // body's circle; the earliest hit along the segment wins.
                    const x0 = t.x - vel.vx;
                    const y0 = t.y - vel.vy;
                    const dd: i64 = @as(i64, vel.vx) * vel.vx + @as(i64, vel.vy) * vel.vy;
                    const ccx: i32 = std.math.clamp(t.x >> cell_shift, 0, cells_x - 1);
                    const ccy: i32 = std.math.clamp(t.y >> cell_shift, 0, cells_y - 1);
                    var best_t: i64 = std.math.maxInt(i64);
                    var best: u32 = nil;
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
                                if (eql(e.id, p.owner)) continue;
                                if (t.z < e.z or t.z > e.z + fx.half) continue;
                                const fxv: i64 = e.x - x0;
                                const fyv: i64 = e.y - y0;
                                var tq: i64 = if (dd == 0) 0 else @divTrunc((fxv * vel.vx + fyv * vel.vy) << 16, dd);
                                tq = std.math.clamp(tq, 0, 1 << 16);
                                const px: i64 = x0 + ((vel.vx * tq) >> 16);
                                const py: i64 = y0 + ((vel.vy * tq) >> 16);
                                const ex = e.x - px;
                                const ey = e.y - py;
                                const rr: i64 = e.r + T.shot_radius;
                                if (ex * ex + ey * ey < rr * rr and tq < best_t) {
                                    best_t = tq;
                                    best = j;
                                }
                            }
                        }
                    }
                    if (best != nil and p.ttl != 0) {
                        sc.stats.shot_hits += 1;
                        const e = sc.entries[best];
                        const def = T.weapons[@min(p.weapon, T.weapon_count - 1)];
                        const ww = &sim.state.world;
                        // Double damage on the shooter doubles the bullet
                        // and flame figures (projectiles.md 3.2-3.3).
                        var mult: i32 = 1;
                        if (ww.get(p.owner, c.Pedestrian)) |op| {
                            if (op.double_damage > 0) mult = 2;
                        }
                        if (ww.get(e.id, c.Vehicle) != null) {
                            // Cars: raw damage by anti-strength; a rocket
                            // blows up at the hit point.
                            const raw: i64 = if (def.explosive) def.damage_car else @as(i64, def.damage_car) * mult;
                            sim.damageCar(e.id, raw << fx.frac_bits, p.owner);
                            if (def.explosive) sim.explodeAt((t.x + e.x) >> 1, (t.y + e.y) >> 1, e.z, p.owner, 0);
                        } else {
                            const player = ww.get(e.id, c.Controller).?.player != c.Controller.no_player;
                            const ped = ww.get(e.id, c.Pedestrian).?;
                            if (player and ped.armour > 0) {
                                // Armour soaks the whole hit.
                                if (sim.writable(e.id)) ped.armour -= 1;
                            } else sim.hurt(e.id, mult * @as(i32, if (player) def.damage_player else def.damage_other), p.owner);
                            if (shot == T.shot_flame) sim.ignite(e.id, p.owner);
                            if (def.explosive) sim.explodeAt(e.x, e.y, e.z, p.owner, 0);
                        }
                        if (shot == T.shot_molotov) sim.startFire(e.x, e.y, e.z, p.owner);
                        p.ttl = 0;
                        sim.kill(id);
                    }
                }
            }.f);
        }

        /// Riders follow their vehicle.
        fn sysRiders(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Riding, c.Transform }, self.predicting(), &self.state.world, struct {
                fn f(w: *World, _: EntityId, ride: *c.Riding, t: *c.Transform) void {
                    if (ride.vehicle.isNone()) return;
                    if (w.get(ride.vehicle, c.Transform)) |ct| t.* = ct.* else ride.vehicle = .none;
                }
            }.f);
        }

        fn sysHealth(self: *Self) void {
            // Cars (explosions-and-damage.md 3.5-3.6): on fire from 16000
            // damage, burning on by itself from 25000, exploding at 32000;
            // then a wreck for a while.
            self.state.world.eachFiltered(.{ c.Vehicle, c.Health, c.Transform, c.Appearance }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, h: *c.Health, t: *c.Transform, look: *c.Appearance) void {
                    if (sim.predicting()) return; // fire and wrecks come from the server
                    const w = &sim.state.world;
                    if (v.flags & c.Vehicle.flag_wrecked != 0) {
                        if (v.timer > 0) {
                            v.timer -= 1;
                            return;
                        }
                        w.despawn(id);
                        if (cfg.ambient_cars > 0) _ = sim.spawnAmbientCar(true, sim.randomPlayerBlock(id));
                        return;
                    }
                    const damage = T.car_damage_max - h.hp;
                    if (damage >= T.car_fire_damage) v.flags |= c.Vehicle.flag_burning;
                    if (damage >= T.car_fire2_damage) h.hp -= T.car_burn_rate;
                    if (h.hp > 0) return;
                    // Explodes: everyone inside dies, credited to whoever
                    // destroyed it.
                    const driver = v.driver;
                    if (w.get(driver, c.Riding)) |r| {
                        r.vehicle = .none;
                        w.get(driver, c.Collider).?.flags = c.Collider.flag_grounded;
                        w.get(driver, c.Transform).?.* = t.*;
                        if (w.get(driver, c.Controller)) |dc| {
                            if (dc.player != c.Controller.no_player) sim.state.players[dc.player].car = .none;
                        }
                        const dh = w.get(driver, c.Health).?;
                        dh.hp = 0;
                        dh.last_hit_by = h.last_hit_by;
                    }
                    sim.scratch.stats.car_wrecks += 1;
                    sim.releaseCar(id);
                    v.flags = c.Vehicle.flag_wrecked;
                    v.timer = T.wreck_ticks;
                    v.pedal = 0;
                    v.steer = 0;
                    h.hp = 0;
                    look.remap = T.wreck_remap;
                    sim.explodeAt(t.x, t.y, t.z, h.last_hit_by, 1);
                }
            }.f);
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Health, c.Controller, c.Riding }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, _: *c.Pedestrian, h: *c.Health, ctl: *c.Controller, r: *c.Riding) void {
                    if (h.hp > 0) return;
                    if (sim.predicting()) {
                        sim.kill(id);
                        return;
                    }
                    const w = &sim.state.world;
                    if (!r.vehicle.isNone()) sim.releaseCar(r.vehicle);
                    sim.scratch.stats.ped_deaths += 1;
                    w.despawn(id);
                    if (ctl.player != c.Controller.no_player) {
                        sim.creditKill(ctl.player, h.last_hit_by, id);
                        const pl = &sim.state.players[ctl.player];
                        pl.deaths += 1;
                        pl.ped = .none;
                        pl.car = .none;
                        pl.respawn_timer = T.respawn_ticks;
                    } else {
                        _ = sim.spawnPed(c.Controller.no_player, 0);
                    }
                }
            }.f);
        }

        /// Kill credit for player `victim`'s death, hit last by `by`. A kill
        /// by a car counts for its driver; dying by your own hand costs a
        /// point. Reaching the frag limit ends the round.
        fn creditKill(self: *Self, victim: u32, by: EntityId, victim_ped: EntityId) void {
            const w = &self.state.world;
            var killer = by;
            var weapon: u8 = Event.weapon_fire;
            if (w.get(by, c.Vehicle)) |v| {
                killer = v.driver;
                weapon = Event.weapon_car;
            } else if (w.get(by, c.Weapon)) |wp| weapon = wp.kind;
            var killer_slot: u8 = Event.no_slot;
            if (w.get(killer, c.Controller)) |ctl| {
                if (ctl.player != c.Controller.no_player and w.get(killer, c.Pedestrian) != null) killer_slot = @intCast(ctl.player);
            }
            if (eql(killer, victim_ped)) killer_slot = @intCast(victim);
            self.pushEvent(.{ .kind = .kill, .a = killer_slot, .b = @intCast(victim), .c = weapon });
            if (killer_slot == Event.no_slot) return;
            const kp = &self.state.players[killer_slot];
            if (killer_slot == victim) {
                kp.score -= 1;
                return;
            }
            kp.kills += 1;
            kp.score += 1;
            if (kp.score >= T.frag_limit) {
                self.scratch.stats.rounds += 1;
                self.pushEvent(.{ .kind = .round_end, .a = killer_slot });
                for (&self.state.players) |*pl| {
                    pl.kills = 0;
                    pl.deaths = 0;
                    pl.score = 0;
                }
            }
        }

        /// Block of a random active player's body, keyed on `key`.
        fn randomPlayerBlock(self: *Self, key: EntityId) ?Block {
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

        /// Pickups: taken by a player walking or driving over one, expire
        /// after a while, and are topped up near random players.
        fn sysPickups(self: *Self) void {
            if (self.predicting()) return;
            const w = &self.state.world;
            w.each(.{ c.Transform, c.Weapon, c.Appearance }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, give: *c.Weapon, _: *c.Appearance) void {
                    const ww = &sim.state.world;
                    if (ww.get(id, c.Pedestrian) != null) return; // peds carry weapons too
                    if (give.cooldown == 0) return ww.despawn(id);
                    give.cooldown -= 1;
                    for (&sim.state.players, 0..) |*row, slot| {
                        if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                        const ped = row.ped;
                        const pt = ww.get(row.car, c.Transform) orelse ww.get(ped, c.Transform) orelse continue;
                        if (fx.abs(pt.z - t.z) > fx.half) continue;
                        if (fx.abs(pt.x - t.x) > T.pickup_reach or fx.abs(pt.y - t.y) > T.pickup_reach) continue;
                        if (fx.length(pt.x - t.x, pt.y - t.y) > T.pickup_reach) continue;
                        if (!sim.givePickup(ped, give)) continue;
                        sim.scratch.stats.pickups_taken += 1;
                        sim.pushEvent(.{ .kind = .pickup, .a = @intCast(slot), .b = give.kind, .x = t.x, .y = t.y, .z = t.z });
                        give.cooldown = 0;
                        ww.despawn(id);
                        return;
                    }
                }
            }.f);
            // Top up: one new pickup per tick at most. Configurations with
            // fewer than 8 pickup slots (unit tests) place none themselves.
            if (cfg.pickup_capacity < 8) return;
            var active: u32 = 0;
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active != 0) active += 1;
            }
            if (active == 0) return;
            const want = @min(cfg.pickup_capacity, T.pickups_base + T.pickups_per_player * active);
            if (w.count(Pickup) >= want) return;
            const id = w.spawn(Pickup) orelse return;
            const o = self.randomPlayerBlock(id) orelse return w.despawn(id);
            const spot = self.findSpotNear(id, map.Ground.pavement, T.ped_radius, o.x, o.y, T.pickup_near_radius, T.pickup_near_min) orelse return w.despawn(id);
            var roll = self.randBelow(id, salt_pickup_kind, 100);
            var kind: u8 = 1;
            while (kind < T.pickup_kinds - 1 and roll >= T.pickup_odds[kind]) : (kind += 1) roll -= T.pickup_odds[kind];
            self.initPickup(id, spot.x, spot.y, spot.z, kind);
        }

        fn initPickup(self: *Self, id: EntityId, x: Fx, y: Fx, z: Fx, kind: u8) void {
            const w = &self.state.world;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = z, .heading = 0 };
            const amount: u16 = if (kind < T.weapon_count) T.weapons[kind].pickup_rounds * 10 else 0;
            w.get(id, c.Weapon).?.* = .{ .cooldown = T.pickup_life, .kind = kind, .a0 = amount, .a1 = 0, .a2 = 0, .a3 = 0 };
            w.get(id, c.Appearance).?.* = .{ .sprite = kind, .remap = c.Appearance.no_remap };
        }

        /// Apply a pickup to `ped`. False if it does not need it.
        fn givePickup(self: *Self, ped: EntityId, give: *const c.Weapon) bool {
            const w = &self.state.world;
            if (give.kind == T.pickup_health) {
                const h = w.get(ped, c.Health) orelse return false;
                if (h.hp >= T.ped_hp) return false;
                h.hp = T.ped_hp;
                return true;
            }
            if (give.kind > T.pickup_health) {
                const p = w.get(ped, c.Pedestrian) orelse return false;
                // Refused when already full (power-ups-death-and-arrest.md 3.1).
                switch (give.kind) {
                    T.pickup_armour => {
                        if (p.armour >= T.armour_charges) return false;
                        p.armour = T.armour_charges;
                    },
                    T.pickup_invulnerable => {
                        if (p.invulnerable == T.invulnerable_ticks) return false;
                        p.invulnerable = T.invulnerable_ticks;
                    },
                    T.pickup_double_damage => {
                        if (p.double_damage == T.double_damage_ticks) return false;
                        p.double_damage = T.double_damage_ticks;
                    },
                    T.pickup_fast_reload => {
                        if (p.fast_reload == T.fast_reload_ticks) return false;
                        p.fast_reload = T.fast_reload_ticks;
                    },
                    else => return false,
                }
                return true;
            }
            if (give.kind >= T.weapon_count) return false;
            const wpn = w.get(ped, c.Weapon) orelse return false;
            const have = wpn.rounds()[give.kind];
            if (have == T.infinite_ammo or have >= T.max_ammo_tenths) return false;
            wpn.rounds()[give.kind] = @min(T.max_ammo_tenths, have + give.a0);
            // A weapon you did not have goes straight into your hand.
            if (have == 0) wpn.kind = give.kind;
            return true;
        }

        /// Per ped, per tick: power-up timers run down, burning hurts, and
        /// the shock counter decays by 1; a ped on his feet (not mid-jump)
        /// whose shock reaches 100 is electrocuted (ours: killed).
        fn sysPedStatus(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Health, c.Controller }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, p: *c.Pedestrian, h: *c.Health, ctl: *c.Controller) void {
                    if (p.invulnerable > 0) p.invulnerable -= 1;
                    if (p.double_damage > 0) p.double_damage -= 1;
                    if (p.fast_reload > 0) p.fast_reload -= 1;
                    if (sim.predicting()) return; // damage comes from the server
                    if (p.burn > 0) {
                        p.burn -= 1;
                        const player = ctl.player != c.Controller.no_player;
                        sim.hurt(id, if (player) T.burn_damage_player else T.burn_damage_other, h.last_hit_by);
                    }
                    if (p.shock >= T.shock_threshold and p.state == c.Pedestrian.state_up and p.jump == 0) {
                        p.shock = 0;
                        sim.killPed(id, h.last_hit_by);
                    } else if (p.shock > 0) p.shock -= 1;
                }
            }.f);
        }

        /// Ambient cars and peds far from every player are moved near one.
        fn sysAmbient(self: *Self) void {
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
                    if (!farFromAll(cx.pos, t)) return;
                    const sim = cx.sim;
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

        fn farFromAll(pos: []const [2]i32, t: *const c.Transform) bool {
            const x = fx.toInt(t.x);
            const y = fx.toInt(t.y);
            for (pos) |p| {
                if (@max(@abs(p[0] - x), @abs(p[1] - y)) < T.ambient_far) return false;
            }
            return true;
        }

        // ------------------------------------------------------------------
        // Traffic

        const dir_heading = [4]u16{ 0, 16384, 32768, 49152 };
        const dir_arrow = [4]u4{ map.Arrow.pos_x, map.Arrow.pos_y, map.Arrow.neg_x, map.Arrow.neg_y };

        fn arrowCount(a: u4) u32 {
            return @popCount(a);
        }

        /// Traffic (traffic-and-car-ai.md) drives along the lane arrows, goes
        /// straight on at junctions where it can (else a 50/50 left or right
        /// pick, made once), keeps to the middle of its lane, ramps its speed
        /// setting toward 0.1 a tick, brakes for anything 1.75 blocks ahead
        /// (1 while turning), halts for 100 ticks after hitting someone and
        /// backs out when stuck.
        fn sysTrafficAi(self: *Self) void {
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
        fn turnPick(self: *Self, id: EntityId) u8 {
            return 1 + @as(u8, @truncate(self.randBelow(id, salt_ai_plan, 2)));
        }

        /// Is there road running direction `dir` `dist` blocks ahead?
        fn roadAhead(self: *Self, t: *const c.Transform, dir: u8, dist: Fx) bool {
            const h = dir_heading[dir & 3];
            const cell = map.floorCell(self.grid, t.x + fx.mul(fx.cos(h), dist), t.y + fx.mul(fx.sin(h), dist), t.z, T.car_step);
            return map.groundOf(cell) == map.Ground.road and map.arrowsOf(cell) & dir_arrow[dir & 3] != 0;
        }

        /// Is there a body in the box ahead of a car?
        fn bodyAhead(self: *Self, self_id: EntityId, t: *const c.Transform, look: Fx) bool {
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

        fn sysRespawn(self: *Self) void {
            if (self.predicting()) return;
            for (&self.state.players, 0..) |*pl, i| {
                if (pl.flags & abi.PlayerRow.flag_active == 0 or !pl.ped.isNone()) continue;
                if (pl.respawn_timer > 0) {
                    pl.respawn_timer -= 1;
                    continue;
                }
                self.spawnPlayer(@intCast(i), 0);
            }
        }

        // ==================================================================
        // Helpers for hosts, tools and tests (not part of I1).

        /// Place a parked car (authoritative mode only). For tools, tests and
        /// map-object spawning until `.scr` placement lands.
        pub fn spawnCarAt(self: *Self, x: Fx, y: Fx, heading: u16, model: u8) ?EntityId {
            if (self.predicting()) return null;
            const w = &self.state.world;
            const id = w.spawn(Car) orelse return null;
            const z = map.floorAt(self.grid, x, y, fx.fromInt(map.size_z - 1), T.car_step);
            self.initCar(id, .{ .x = x, .y = y, .z = z, .heading = heading }, model);
            w.applyPending();
            return id;
        }

        /// Place a pickup (authoritative mode only), for tests and tools.
        pub fn spawnPickupAt(self: *Self, x: Fx, y: Fx, kind: u8) ?EntityId {
            if (self.predicting()) return null;
            const w = &self.state.world;
            const id = w.spawn(Pickup) orelse return null;
            const z = map.floorAt(self.grid, x, y, fx.fromInt(map.size_z - 1), T.ped_step);
            self.initPickup(id, x, y, z, kind);
            w.applyPending();
            return id;
        }

        pub fn pedOf(self: *Self, slot: u32) ?EntityId {
            const id = self.state.players[slot].ped;
            return if (self.state.world.isAlive(id)) id else null;
        }

        pub fn transformOf(self: *Self, id: EntityId) ?*c.Transform {
            return self.state.world.get(id, c.Transform);
        }
    };
}

pub const Sim16 = Sim(config_16);

comptime {
    abi.checkSim(Sim16);
}
