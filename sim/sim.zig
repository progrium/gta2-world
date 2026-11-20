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
//! and with each other. Pistols, damage, deaths and respawns carry over
//! from S2 in simple form.

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
const salt_ai_timer: u32 = 0x300;
const salt_ai_turn: u32 = 0x301;
const salt_car_model: u32 = 0x400;

const max_intents = 64;

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
        pub const Pickup = ecs.Kind(.pickup, cfg.pickup_capacity, &.{c.Transform});
        pub const MapObject = ecs.Kind(.map_object, cfg.map_object_capacity, &.{c.Transform});
        pub const World = ecs.World(&.{ Car, Ped, Shot, Pickup, MapObject });

        /// Components replicated per kind (for I3 codecs, workstream C), in
        /// ascending component id. `Predicted` is never replicated.
        pub const replicated = .{
            .{ abi.Kind.car, .{ c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Vehicle, c.Appearance } },
            .{ abi.Kind.ped, .{ c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Pedestrian, c.Riding, c.Weapon, c.Appearance } },
            .{ abi.Kind.projectile, .{ c.Transform, c.Velocity, c.Projectile } },
            .{ abi.Kind.pickup, .{c.Transform} },
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
                while (i < cfg.ambient_cars) : (i += 1) _ = self.spawnParkedCar(i);
                i = 0;
                while (i < cfg.ambient_peds) : (i += 1) _ = self.spawnPed(c.Controller.no_player, 0);
                s.world.applyPending();
            }
        }

        pub fn step(self: *Self, frames: []const Frame, cmds: []const abi.Command) void {
            self.scratch.intent_len = 0;
            if (!self.predicting()) {
                for (cmds) |cmd| self.applyCommand(cmd);
            }
            self.sysInput(frames);
            self.sysPedAi();
            self.sysPedControl();
            self.sysCarControl();
            self.sysWeapons();
            self.sysMoveCars();
            self.sysMovePeds();
            self.sysMoveProjectiles();
            self.buildBroadphase();
            self.sysContacts();
            self.sysProjectileHits();
            self.sysRiders();
            self.sysHealth();
            self.sysRespawn();
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

        /// Standing height on the highest floor of column (cx, cy), if that
        /// floor is a full block with headroom above it.
        fn columnFloor(self: *const Self, cx: i32, cy: i32) ?struct { z: i32, cell: map.Cell } {
            var z: i32 = map.size_z - 2;
            while (z >= 0) : (z -= 1) {
                const cell = map.cellAt(self.grid, cx, cy, z);
                const sh = map.shapeOf(cell);
                if (sh == map.Shape.air or sh == map.Shape.water) continue;
                if (sh != map.Shape.solid or map.codeOf(cell) != 0) return null;
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

        fn headingFromArrows(arrows: u4, fallback: u32) u16 {
            if (arrows & map.Arrow.pos_x != 0) return 0;
            if (arrows & map.Arrow.pos_y != 0) return 16384;
            if (arrows & map.Arrow.neg_x != 0) return 32768;
            if (arrows & map.Arrow.neg_y != 0) return 49152;
            return @truncate(fallback *% 16384);
        }

        fn spawnParkedCar(self: *Self, n: u32) ?EntityId {
            const w = &self.state.world;
            const id = w.spawn(Car) orelse return null;
            const spot = self.findSpot(id, map.Ground.road, T.carModel(0).radius) orelse {
                w.despawn(id);
                return null;
            };
            const model: u8 = @truncate(self.randBelow(id, salt_car_model, T.car_models.len));
            _ = n;
            self.initCar(id, spot, model);
            return id;
        }

        fn initCar(self: *Self, id: EntityId, spot: Spot, model: u8) void {
            const w = &self.state.world;
            const m = T.carModel(model);
            w.get(id, c.Transform).?.* = .{ .x = spot.x, .y = spot.y, .z = spot.z, .heading = spot.heading };
            w.get(id, c.Collider).?.flags = c.Collider.flag_grounded;
            w.get(id, c.Health).?.* = .{ .hp = m.hp, .last_hit_by = .none };
            w.get(id, c.Controller).?.* = .{ .player = c.Controller.no_player, .prev_buttons = 0, .in = Frame.neutral(0) };
            w.get(id, c.Vehicle).?.* = .{ .driver = .none, .model = model, .pedal = 0, .steer = 0, .flags = 0 };
            w.get(id, c.Appearance).?.* = .{ .sprite = model, .remap = c.Appearance.no_remap };
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
            w.get(id, c.Pedestrian).?.* = .{ .ai_timer = 0, .ai_heading = sp.heading, .jump_cooldown = 0, .anim = 0 };
            const is_player = player != c.Controller.no_player;
            w.get(id, c.Weapon).?.* = .{ .cooldown = 0, .kind = 0, .ammo = if (is_player) T.player_ammo else 0 };
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

        /// Latch each player's frame into the entity they control, and act on
        /// the enter/exit edge.
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
                    if (pressed & Button.enter_exit != 0) {
                        if (!ride.vehicle.isNone()) sim.tryExit(id) else sim.tryEnter(id);
                    }
                    const w = &sim.state.world;
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

        fn tryEnter(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const t = w.get(ped, c.Transform).?;
            const Best = struct { id: EntityId = .none, d: Fx = T.enter_reach };
            var best: Best = .{};
            const Ctx = struct { best: *Best, t: *const c.Transform };
            w.each(.{ c.Vehicle, c.Transform, c.Velocity }, Ctx{ .best = &best, .t = t }, struct {
                fn f(ctx: Ctx, id: EntityId, v: *c.Vehicle, ct: *c.Transform, vel: *c.Velocity) void {
                    if (!v.driver.isNone()) return;
                    if (fx.abs(ct.z - ctx.t.z) > fx.half) return;
                    if (speedOf(vel) > T.enter_max_speed) return;
                    const d = fx.length(ct.x - ctx.t.x, ct.y - ctx.t.y);
                    if (d < ctx.best.d) ctx.best.* = .{ .id = id, .d = d };
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
            w.get(ped, c.Pedestrian).?.anim = c.Pedestrian.anim_stand;
            w.get(car, c.Vehicle).?.driver = ped;
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
        /// stay in.
        fn tryExit(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const car = w.get(ped, c.Riding).?.vehicle;
            const ct = (w.get(car, c.Transform) orelse return).*;
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

        /// On-foot control: tank (steer turns, throttle walks) or direct
        /// (turn toward aim, move along it). Jump on handbrake_jump.
        fn sysPedControl(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Riding, c.Controller, c.Transform, c.Velocity, c.Collider }, self.predicting(), {}, struct {
                fn f(_: void, _: EntityId, ped: *c.Pedestrian, ride: *c.Riding, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    if (ped.jump_cooldown > 0) ped.jump_cooldown -= 1;
                    if (!ride.vehicle.isNone()) return;
                    const in = ctl.in;
                    const run = in.buttons & Button.run != 0;
                    var speed: Fx = 0;
                    var dir: u16 = t.heading;
                    if (in.buttons & Button.direct != 0) {
                        const diff: i16 = @bitCast(in.aim -% t.heading);
                        const turn = std.math.clamp(@as(i32, diff), -T.ped_direct_turn, T.ped_direct_turn);
                        t.heading +%= @as(u16, @truncate(@as(u32, @bitCast(turn))));
                        if (in.throttle > 0) {
                            speed = fx.mulAxis(if (run) T.ped_run else T.ped_walk, in.throttle);
                            dir = in.aim;
                        }
                    } else {
                        const turn = @divTrunc(@as(i32, in.steer) * T.ped_tank_turn, 127);
                        t.heading +%= @as(u16, @truncate(@as(u32, @bitCast(turn))));
                        dir = t.heading;
                        if (in.throttle > 0) {
                            speed = fx.mulAxis(if (run) T.ped_run else T.ped_walk, in.throttle);
                        } else if (in.throttle < 0) {
                            speed = fx.mulAxis(T.ped_back, -in.throttle);
                            dir = t.heading +% 32768;
                        }
                    }
                    const grounded = col.flags & c.Collider.flag_grounded != 0;
                    if (grounded) {
                        vel.vx = fx.mul(fx.cos(dir), speed);
                        vel.vy = fx.mul(fx.sin(dir), speed);
                        if (in.buttons & Button.handbrake_jump != 0 and ped.jump_cooldown == 0) {
                            vel.vz = T.ped_jump_vz;
                            col.flags &= ~c.Collider.flag_grounded;
                            ped.jump_cooldown = T.ped_jump_cooldown;
                        }
                    }
                    ped.anim = if (!grounded or vel.vz > 0) c.Pedestrian.anim_jump else if (speed == 0) c.Pedestrian.anim_stand else if (run) c.Pedestrian.anim_run else c.Pedestrian.anim_walk;
                }
            }.f);
        }

        /// Placeholder handling. Velocity is split into forward and lateral
        /// parts. The pedal accelerates or brakes the forward part; the tyres
        /// remove at most `grip` of lateral speed per tick, so a fast turn or
        /// the handbrake makes the car slide; yaw follows the front wheels and
        /// forward speed.
        fn sysCarControl(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Vehicle, c.Controller, c.Transform, c.Velocity, c.Collider }, self.predicting(), {}, struct {
                fn f(_: void, _: EntityId, v: *c.Vehicle, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    const m = T.carModel(v.model);
                    const in = if (v.driver.isNone()) Frame.neutral(0) else ctl.in;
                    v.pedal = approach(v.pedal, in.throttle, m.pedal_rate);
                    v.steer = approach(v.steer, in.steer, m.steer_rate);
                    const handbrake = in.buttons & Button.handbrake_jump != 0;
                    v.flags = (if (handbrake) c.Vehicle.flag_handbrake else 0) | (if (in.buttons & Button.special != 0) c.Vehicle.flag_horn else 0);
                    if (col.flags & c.Collider.flag_grounded == 0) {
                        // Airborne: no traction, keep going.
                        vel.spin = 0;
                        return;
                    }

                    const fwd_x = fx.cos(t.heading);
                    const fwd_y = fx.sin(t.heading);
                    var vf = fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y);
                    var vl = fx.mul(vel.vx, -fwd_y) + fx.mul(vel.vy, fwd_x);

                    // Longitudinal.
                    const pedal: i32 = v.pedal;
                    if (pedal > 0) {
                        if (vf < 0) {
                            vf = towardZero(vf, fx.mulAxis(m.brake, v.pedal));
                        } else {
                            // Acceleration tapers linearly to zero at top speed.
                            const room = fx.one - fx.clamp(fx.div(vf, m.max_speed), 0, fx.one);
                            vf += fx.mul(fx.mulAxis(m.accel, v.pedal), room);
                        }
                    } else if (pedal < 0) {
                        if (vf > 0) {
                            vf = towardZero(vf, fx.mulAxis(m.brake, -v.pedal));
                        } else if (vf > -m.max_reverse) {
                            vf -= fx.mulAxis(m.accel >> 1, -v.pedal);
                            if (vf < -m.max_reverse) vf = -m.max_reverse;
                        }
                    } else {
                        vf = towardZero(vf, m.coast);
                    }
                    if (handbrake) vf = towardZero(vf, m.brake >> 2);
                    vf -= vf >> m.drag_shift;

                    // Lateral grip: the drift model.
                    const grip = if (handbrake) m.handbrake_grip else m.grip;
                    vl = towardZero(vl, grip);

                    // Yaw from the front wheels, scaled by forward speed.
                    var yaw: i32 = @intCast(@divTrunc(@as(i64, v.steer) * m.steer_gain * vf, 127 << fx.frac_bits));
                    var cap = m.max_yaw;
                    if (handbrake) {
                        yaw = @divTrunc(yaw * m.handbrake_yaw_8ths, 8);
                        cap = @divTrunc(cap * m.handbrake_yaw_8ths, 8);
                    }
                    yaw = std.math.clamp(yaw, -cap, cap);
                    vel.spin = yaw;

                    vel.vx = fx.mul(vf, fwd_x) - fx.mul(vl, fwd_y);
                    vel.vy = fx.mul(vf, fwd_y) + fx.mul(vl, fwd_x);
                }
            }.f);
        }

        fn approach(cur: i8, target: i8, rate: i32) i8 {
            const a: i32 = cur;
            const b: i32 = target;
            // Return to centre twice as fast as moving away from it.
            const r = if (b == 0 or (a != 0 and (a > 0) != (b > 0))) rate * 2 else rate;
            const next = if (a < b) @min(a + r, b) else @max(a - r, b);
            return @intCast(next);
        }

        fn towardZero(v: Fx, amount: Fx) Fx {
            if (v > 0) return @max(v - amount, 0);
            if (v < 0) return @min(v + amount, 0);
            return 0;
        }

        fn sysWeapons(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Weapon, c.Controller, c.Transform, c.Velocity, c.Riding }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, wpn: *c.Weapon, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, ride: *c.Riding) void {
                    if (wpn.cooldown > 0) wpn.cooldown -= 1;
                    if (!ride.vehicle.isNone()) return;
                    if (ctl.in.buttons & Button.fire == 0 or wpn.cooldown != 0 or wpn.ammo == 0) return;
                    wpn.cooldown = T.pistol_cooldown;
                    wpn.ammo -= 1;
                    sim.scratch.stats.shots += 1;
                    const dx = fx.cos(t.heading);
                    const dy = fx.sin(t.heading);
                    const off = T.ped_radius + fx.ratio(2, 10);
                    const st: c.Transform = .{ .x = t.x + fx.mul(dx, off), .y = t.y + fx.mul(dy, off), .z = t.z + fx.ratio(1, 2), .heading = t.heading };
                    if (sim.predicting()) {
                        sim.pushIntent(.spawn, .projectile, id, st);
                        return;
                    }
                    const w = &sim.state.world;
                    const sid = w.spawn(Shot) orelse return;
                    w.get(sid, c.Transform).?.* = st;
                    w.get(sid, c.Velocity).?.* = .{ .vx = vel.vx + fx.mul(dx, T.projectile_speed), .vy = vel.vy + fx.mul(dy, T.projectile_speed), .vz = 0, .spin = 0 };
                    w.get(sid, c.Projectile).?.* = .{ .owner = id, .ttl = T.projectile_ttl, .damage = T.pistol_damage };
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
            return false;
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
            return false;
        }

        fn substeps(vel: *const c.Velocity) i32 {
            const m = @max(fx.abs(vel.vx), fx.abs(vel.vy));
            return @max(1, @divTrunc(m + T.max_substep - 1, T.max_substep));
        }

        /// Gravity, floor following and landing for any body.
        fn settle(self: *const Self, t: *c.Transform, vel: *c.Velocity, col: *c.Collider, step_h: Fx) void {
            const floor = map.floorAt(self.grid, t.x, t.y, t.z, step_h);
            const grounded = col.flags & c.Collider.flag_grounded != 0;
            if (grounded and vel.vz <= 0 and floor >= t.z - T.snap_down) {
                t.z = floor;
                vel.vz = 0;
                return;
            }
            vel.vz = @max(vel.vz - T.gravity, -T.max_fall);
            // Rising into a ceiling stops the rise.
            if (vel.vz > 0 and map.blocks(self.grid, t.x, t.y, t.z + vel.vz, step_h)) vel.vz = 0;
            t.z += vel.vz;
            if (t.z <= floor) {
                t.z = floor;
                vel.vz = 0;
                col.flags |= c.Collider.flag_grounded;
            } else col.flags &= ~c.Collider.flag_grounded;
        }

        fn sysMovePeds(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Transform, c.Velocity, c.Collider }, self.predicting(), self, struct {
                fn f(sim: *Self, _: EntityId, _: *c.Pedestrian, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    const n = substeps(vel);
                    const sx = @divTrunc(vel.vx, n);
                    const sy = @divTrunc(vel.vy, n);
                    var i: i32 = 0;
                    while (i < n) : (i += 1) {
                        if (sx != 0 and !sim.circleBlocked(t.x + sx, t.y, t.z, T.ped_radius, T.ped_step)) t.x += sx;
                        if (sy != 0 and !sim.circleBlocked(t.x, t.y + sy, t.z, T.ped_radius, T.ped_step)) t.y += sy;
                    }
                    sim.settle(t, vel, col, T.ped_step);
                }
            }.f);
        }

        fn sysMoveCars(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Vehicle, c.Transform, c.Velocity, c.Collider }, self.predicting(), self, struct {
                fn f(sim: *Self, _: EntityId, v: *c.Vehicle, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    const m = T.carModel(v.model);
                    // Rotate first; a turn that would put a corner in a wall
                    // does not happen.
                    if (vel.spin != 0) {
                        const h = t.heading +% @as(u16, @truncate(@as(u32, @bitCast(vel.spin))));
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
                                sim.wallHit(vel, true, m);
                            } else t.x += sx;
                        }
                        if (sy != 0) {
                            if (sim.boxBlocked(t.x, t.y + sy, t.z, t.heading, m)) {
                                sim.wallHit(vel, false, m);
                            } else t.y += sy;
                        }
                    }
                    sim.settle(t, vel, col, T.car_step);
                }
            }.f);
        }

        /// Bounce off a wall along one axis and scrub some speed along the
        /// other.
        fn wallHit(self: *Self, vel: *c.Velocity, x_axis: bool, m: *const T.CarModel) void {
            self.scratch.stats.wall_hits += 1;
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
                    if (p.ttl == 0) return sim.kill(id);
                    p.ttl -= 1;
                    t.x += vel.vx;
                    t.y += vel.vy;
                    if (map.blocks(sim.grid, t.x, t.y, t.z - fx.half, 0)) sim.kill(id);
                }
            }.f);
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
            const ma: i64 = if (a.movable) a.mass else 1 << 20;
            const mb: i64 = if (b.movable) b.mass else 1 << 20;
            const total = ma + mb;
            const push_a: Fx = @intCast(@divTrunc(@as(i64, pen) * mb, total));
            const push_b = pen - push_a;
            // Do not push a body into a wall.
            const ma_step: Fx = if (w.get(a.id, c.Vehicle) != null) T.car_step else T.ped_step;
            const mb_step: Fx = if (w.get(b.id, c.Vehicle) != null) T.car_step else T.ped_step;
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
            // Exchange normal momentum (inelastic).
            const rel = fx.mul(vb.vx - va.vx, nx) + fx.mul(vb.vy - va.vy, ny);
            if (rel < 0) {
                const imp_a: Fx = @intCast(@divTrunc(@as(i64, rel) * mb, total));
                const imp_b = rel - imp_a;
                if (a.movable) {
                    va.vx += fx.mul(nx, imp_a);
                    va.vy += fx.mul(ny, imp_a);
                }
                if (b.movable) {
                    vb.vx -= fx.mul(nx, imp_b);
                    vb.vy -= fx.mul(ny, imp_b);
                }
                // Damage scales with closing speed; peds hit by cars hurt most.
                const speed = -rel;
                if (speed > T.impact_threshold) {
                    self.scratch.stats.impacts += 1;
                    const dmg: i32 = fx.toInt(fx.mul(speed, fx.fromInt(T.impact_damage)));
                    self.hurt(b.id, if (a.mass > b.mass) dmg * 4 else dmg, a.id);
                    self.hurt(a.id, if (b.mass > a.mass) dmg * 4 else dmg, b.id);
                }
            }
            a.x = ta.x;
            a.y = ta.y;
            b.x = tb.x;
            b.y = tb.y;
        }

        fn hurt(self: *Self, id: EntityId, dmg: i32, by: EntityId) void {
            if (!self.writable(id)) return;
            if (self.state.world.get(id, c.Health)) |h| {
                h.hp -= dmg;
                h.last_hit_by = by;
            }
        }

        fn sysProjectileHits(self: *Self) void {
            if (self.predicting()) return;
            self.state.world.each(.{ c.Transform, c.Velocity, c.Projectile }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile) void {
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
                                if (fx.abs(e.z + fx.half - t.z) > fx.one) continue;
                                const fxv: i64 = e.x - x0;
                                const fyv: i64 = e.y - y0;
                                var tq: i64 = if (dd == 0) 0 else @divTrunc((fxv * vel.vx + fyv * vel.vy) << 16, dd);
                                tq = std.math.clamp(tq, 0, 1 << 16);
                                const px: i64 = x0 + ((vel.vx * tq) >> 16);
                                const py: i64 = y0 + ((vel.vy * tq) >> 16);
                                const ex = e.x - px;
                                const ey = e.y - py;
                                if (ex * ex + ey * ey < @as(i64, e.r) * e.r and tq < best_t) {
                                    best_t = tq;
                                    best = j;
                                }
                            }
                        }
                    }
                    if (best != nil) {
                        sc.stats.shot_hits += 1;
                        sim.hurt(sc.entries[best].id, p.damage, p.owner);
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
            // Cars: wreck, ejecting the driver.
            self.state.world.eachFiltered(.{ c.Vehicle, c.Health, c.Transform }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, h: *c.Health, _: *c.Transform) void {
                    if (h.hp > 0) return;
                    if (sim.predicting()) {
                        sim.kill(id);
                        return;
                    }
                    const w = &sim.state.world;
                    const driver = v.driver;
                    if (!driver.isNone() and w.get(driver, c.Riding) != null) {
                        sim.tryExit(driver);
                        // Nowhere to get out: the driver goes down with it.
                        if (w.get(driver, c.Riding)) |r| {
                            if (!r.vehicle.isNone()) {
                                r.vehicle = .none;
                                w.get(driver, c.Collider).?.flags = c.Collider.flag_grounded;
                            }
                        }
                        sim.hurt(driver, T.wreck_driver_damage, h.last_hit_by);
                    }
                    sim.scratch.stats.car_wrecks += 1;
                    sim.releaseCar(id);
                    w.despawn(id);
                    if (cfg.ambient_cars > 0) _ = sim.spawnParkedCar(0);
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
                    sim.creditKill(h.last_hit_by);
                    if (ctl.player != c.Controller.no_player) {
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

        fn creditKill(self: *Self, by: EntityId) void {
            const w = &self.state.world;
            var shooter = by;
            // A kill by a car counts for its driver.
            if (w.get(by, c.Vehicle)) |v| shooter = v.driver;
            if (w.get(shooter, c.Controller)) |ctl| {
                if (ctl.player != c.Controller.no_player and w.get(shooter, c.Pedestrian) != null) {
                    self.state.players[ctl.player].kills += 1;
                    self.state.players[ctl.player].score += 1;
                }
            }
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
