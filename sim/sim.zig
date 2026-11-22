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
/// Car model roles and the career numbers (`setStandardRoles` for hosts).
pub const tuning_career = @import("tuning/career.zig");
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

/// Single player (W0 of docs/plan-notes.md): one player, room for a
/// scripted city, and the single-player components and state block. The
/// three cities place 760 to 900 map objects (traffic lights' markers and
/// lamps, phones, doors, generators, the scripts' objects): 1536 leaves
/// room for the missions' own (tools/level --sp reports the count).
/// `dm16` keeps its layout.
/// Deathmatch with police: the first-release room with the living city
/// (`isCity`), for a host who turns police on. `dm16` stays as it is.
pub const config_16_police: Config = .{
    .name = "dmp16",
    .max_players = config_16.max_players,
    .car_capacity = config_16.car_capacity,
    .ped_capacity = config_16.ped_capacity,
    .projectile_capacity = config_16.projectile_capacity,
    .pickup_capacity = config_16.pickup_capacity,
    .map_object_capacity = config_16.map_object_capacity,
    .ambient_cars = config_16.ambient_cars,
    .ambient_peds = config_16.ambient_peds,
};

pub const config_sp: Config = .{
    .name = "sp",
    .max_players = 1,
    .car_capacity = 256,
    .ped_capacity = 512,
    .projectile_capacity = 128,
    .pickup_capacity = 64,
    .map_object_capacity = 1536,
    .ambient_cars = 48,
    .ambient_peds = 160,
};

/// Is `cfg` a single-player configuration (its name starts with "sp")?
/// Those carry the SP components and state block and run the SP systems;
/// shared mechanics run in every configuration.
pub fn isSinglePlayer(comptime cfg: Config) bool {
    return std.mem.startsWith(u8, cfg.name, "sp");
}

/// Is `cfg` a living-city configuration: single player, or deathmatch with
/// police (name starting with "dmp")? Those carry the SP components and
/// state block and run the city systems.
pub fn isCity(comptime cfg: Config) bool {
    return isSinglePlayer(cfg) or std.mem.startsWith(u8, cfg.name, "dmp");
}

pub const ids = @import("ids.zig");
pub const anim = @import("anim.zig");
pub const level = ifaces.level;
pub const Level = level.Level;
pub const sp_state = @import("sp/state.zig");

/// Spawn hint in `Command.arg` for `join`: 0 lets the sim choose; otherwise
/// bits 0-7 are the block x and bits 8-15 the block y, and the ped is placed
/// on the highest floor in that column.
pub fn spawnHint(x: u8, y: u8) u32 {
    return @as(u32, x) | (@as(u32, y) << 8) | (1 << 31);
}

const prelude = @import("prelude.zig");
const shops_sys = @import("sys/shops.zig");
const max_intents = prelude.max_intents;
const max_events = prelude.max_events;

pub fn Sim(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        pub const config: abi.Config = cfg;
        /// Single-player configuration: SP components, state block and
        /// systems (`isSinglePlayer`).
        pub const single_player = isSinglePlayer(cfg);
        /// The living city: the SP components, state block and city systems
        /// (traffic and ped AI, gangs, wanted level and police, objects).
        /// True for single player and for deathmatch with police
        /// (`isCity`); the single-player rules (lives, scripts, career
        /// scoring) stay behind `single_player`.
        pub const city = isCity(cfg);

        pub const Car = ecs.Kind(.car, cfg.car_capacity, &(.{
            c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Vehicle, c.Predicted, c.Appearance,
        } ++ if (city) .{ c.CarTask, c.ScriptTag } else .{}));
        pub const Ped = ecs.Kind(.ped, cfg.ped_capacity, &(.{
            c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Pedestrian, c.Riding, c.Weapon, c.Predicted, c.Appearance,
        } ++ if (city) .{ c.Objective, c.Group, c.ScriptTag } else .{}));
        pub const Shot = ecs.Kind(.projectile, cfg.projectile_capacity, &.{
            c.Transform, c.Velocity, c.Projectile,
        });
        pub const Pickup = ecs.Kind(.pickup, cfg.pickup_capacity, &.{ c.Transform, c.Weapon, c.Appearance });
        /// Every configuration carries `Object` (deathmatch drops oil and
        /// mines from cars); only the city tags objects for scripts.
        pub const MapObject = ecs.Kind(.map_object, cfg.map_object_capacity, if (city) &.{ c.Transform, c.Object, c.ScriptTag } else &.{ c.Transform, c.Object });
        pub const World = ecs.World(&.{ Car, Ped, Shot, Pickup, MapObject });

        /// Components replicated per kind (for I3 codecs, workstream C), in
        /// ascending component id. `Predicted` is never replicated.
        pub const replicated = .{
            .{ abi.Kind.car, .{ c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Vehicle, c.Appearance } },
            .{ abi.Kind.ped, .{ c.Transform, c.Velocity, c.Collider, c.Health, c.Controller, c.Pedestrian, c.Riding, c.Weapon, c.Appearance } },
            .{ abi.Kind.projectile, .{ c.Transform, c.Velocity, c.Projectile } },
            .{ abi.Kind.pickup, .{ c.Transform, c.Weapon, c.Appearance } },
            .{ abi.Kind.map_object, .{ c.Transform, c.Object } },
        };

        pub const SpState = sp_state.SpState(cfg.max_players);

        pub const State = if (city) extern struct {
            tick: u32,
            seed_lo: u32,
            seed_hi: u32,
            _pad: u32 = 0,
            players: [cfg.max_players]abi.PlayerRow,
            world: World,
            /// The single-player block (`sp/state.zig`).
            sp: SpState,
        } else extern struct {
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

        pub const Entry = struct {
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
        pub const max_entries = @as(u32, cfg.car_capacity) + cfg.ped_capacity;
        pub const nil: u32 = 0xFFFF_FFFF;
        pub const cell_shift = 17; // broadphase cell = 2 blocks
        pub const cells_x = map.size_x >> 1;
        pub const cells_y = map.size_y >> 1;

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
                // 7-18: single player, reserved by W0; the meanings are in
                // `wire.EventKind`.
                message = 7,
                brief = 8,
                wanted = 9,
                wasted = 10,
                busted = 11,
                mission_start = 12,
                mission_pass = 13,
                mission_fail = 14,
                phone_ring = 15,
                siren = 16,
                game_over = 17,
                level_complete = 18,
                /// a = 0 shout, 1 radio; b = pursued slot (`wire.EventKind`).
                police_voice = 19,
                /// A player's car repainted at a spray shop: x, y, z of the
                /// shop, a = slot, b = the remap, c = 0 no stars, 1 wanted
                /// level cleared, 2 could not pay (`wire.EventKind`).
                respray = 20,
                /// A car alarm went off: x, y, z of the car
                /// (`sys/car_flags.zig`, `wire.EventKind`).
                car_alarm = 21,
                /// A vehicle weapon fitted or used: x, y, z of the car or
                /// shop; a = slot, b = the `CarWeapon`, c = what happened
                /// (`car_weapons.Fitted`: 0 fitted, 1 could not pay, 2
                /// already full, 3 car bomb armed, 4 mine or oil dropped)
                /// (`wire.EventKind`).
                car_weapon = 22,
            };
            pub const no_slot: u8 = 0xFF;
            pub const weapon_car: u8 = 0x80;
            pub const weapon_fire: u8 = 0x81;
        };

        state: State,
        scratch: Scratch,
        grid: *const abi.Grid,
        /// Static level data (script, zones, map objects), or null: see
        /// `attachLevel`. Like the grid, not part of the state.
        level: ?*const Level,
        /// The level's car shops (`sys/shops.zig`), read from its script by
        /// `attachLevel`. Static, like the level.
        shop_list: [shops_sys.max_shops]shops_sys.Shop,
        shop_count: u8,
        /// A property of the host, not of the state: a client that loads a
        /// server state stays in predict mode.
        mode: abi.Mode,

        comptime {
            abi.checkSim(Self);
        }

        // ==================================================================
        // Systems and helpers, one file per system in sys/ (see sys/README.md).

        const sys_spawn = @import("sys/spawn.zig").Sys(Self);
        const sys_input = @import("sys/input.zig").Sys(Self);
        const sys_enter_exit = @import("sys/enter_exit.zig").Sys(Self);
        const sys_ped_ai = @import("sys/ped_ai.zig").Sys(Self);
        const sys_ped_control = @import("sys/ped_control.zig").Sys(Self);
        const sys_car_control = @import("sys/car_control.zig").Sys(Self);
        const sys_weapons = @import("sys/weapons.zig").Sys(Self);
        const sys_explosions = @import("sys/explosions.zig").Sys(Self);
        const sys_terrain = @import("sys/terrain.zig").Sys(Self);
        const sys_move_peds = @import("sys/move_peds.zig").Sys(Self);
        const sys_move_cars = @import("sys/move_cars.zig").Sys(Self);
        const sys_surfaces = @import("sys/surfaces.zig").Sys(Self);
        const sys_projectiles = @import("sys/projectiles.zig").Sys(Self);
        const sys_contacts = @import("sys/contacts.zig").Sys(Self);
        const sys_health = @import("sys/health.zig").Sys(Self);
        const sys_projectile_hits = @import("sys/projectile_hits.zig").Sys(Self);
        const sys_scoring = @import("sys/scoring.zig").Sys(Self);
        const sys_pickups = @import("sys/pickups.zig").Sys(Self);
        const sys_ambient = @import("sys/ambient.zig").Sys(Self);
        const sys_traffic = @import("sys/traffic.zig").Sys(Self);
        const sys_respawn = @import("sys/respawn.zig").Sys(Self);

        pub const columnFloor = sys_spawn.columnFloor;
        pub const findSpot = sys_spawn.findSpot;
        pub const findSpotNear = sys_spawn.findSpotNear;
        pub const otherPlayerBlock = sys_spawn.otherPlayerBlock;
        pub const headingFromArrows = sys_spawn.headingFromArrows;
        pub const spawnAmbientCar = sys_spawn.spawnAmbientCar;
        pub const pickAmbientModel = sys_spawn.pickAmbientModel;
        pub const initCar = sys_spawn.initCar;
        pub const spawnPed = sys_spawn.spawnPed;
        pub const spawnPlayer = sys_spawn.spawnPlayer;
        pub const randomPlayerBlock = sys_spawn.randomPlayerBlock;
        pub const applyCommand = sys_input.applyCommand;
        pub const sysInput = sys_input.sysInput;
        pub const tryEnter = sys_enter_exit.tryEnter;
        pub const board = sys_enter_exit.board;
        pub const enterable = sys_enter_exit.enterable;
        pub const tryExit = sys_enter_exit.tryExit;
        pub const releaseCar = sys_enter_exit.releaseCar;
        pub const sysRiders = sys_enter_exit.sysRiders;
        pub const startEnter = sys_enter_exit.startEnter;
        pub const cancelEnter = sys_enter_exit.cancelEnter;
        pub const enterPhase = sys_enter_exit.enterPhase;
        pub const sysEnterExit = sys_enter_exit.sysEnterExit;
        pub const EnterPhase = @import("sys/enter_exit.zig").Phase;
        pub const doorPos = sys_enter_exit.doorPos;
        pub const firstUsableDoor = sys_enter_exit.firstUsableDoor;
        pub const sysPedAi = sys_ped_ai.sysPedAi;
        pub const sysPedControl = sys_ped_control.sysPedControl;
        pub const sysCarControl = sys_car_control.sysCarControl;
        pub const damp = sys_car_control.damp;
        pub const frac = sys_car_control.frac;
        pub const radToAngle = sys_car_control.radToAngle;
        pub const cycleWeapon = sys_weapons.cycleWeapon;
        pub const sysWeapons = sys_weapons.sysWeapons;
        pub const fire = sys_weapons.fire;
        pub const throwStep = sys_weapons.throwStep;
        pub const electro = sys_weapons.electro;
        pub const electroHop = sys_weapons.electroHop;
        pub const spark = sys_weapons.spark;
        pub const startFire = sys_explosions.startFire;
        pub const ignite = sys_explosions.ignite;
        pub const explodeAt = sys_explosions.explodeAt;
        pub const burnAround = sys_explosions.burnAround;
        pub const isExplosion = sys_explosions.isExplosion;
        pub const sysExplosions = sys_explosions.sysExplosions;
        pub const circleBlocked = sys_terrain.circleBlocked;
        pub const pushOutCircle = sys_terrain.pushOutCircle;
        pub const boxBlocked = sys_terrain.boxBlocked;
        pub const substeps = sys_terrain.substeps;
        pub const settle = sys_terrain.settle;
        pub const carSettle = sys_terrain.carSettle;
        pub const sysMovePeds = sys_move_peds.sysMovePeds;
        pub const pedBlocked = sys_move_peds.pedBlocked;
        pub const moveThrown = sys_move_peds.moveThrown;
        pub const knock = sys_move_peds.knock;
        pub const killPed = sys_move_peds.killPed;
        pub const sysMoveCars = sys_move_cars.sysMoveCars;
        pub const wallHit = sys_move_cars.wallHit;
        pub const carWater = sys_surfaces.carWater;
        pub const sinkCar = sys_surfaces.sinkCar;
        pub const sysMoveProjectiles = sys_projectiles.sysMoveProjectiles;
        pub const moveThrownShot = sys_projectiles.moveThrownShot;
        pub const burstMolotov = sys_projectiles.burstMolotov;
        pub const cellOf = sys_contacts.cellOf;
        pub const addEntry = sys_contacts.addEntry;
        pub const buildBroadphase = sys_contacts.buildBroadphase;
        pub const sysContacts = sys_contacts.sysContacts;
        pub const carCorners = sys_contacts.carCorners;
        pub const inRect = sys_contacts.inRect;
        pub const rectOverlap = sys_contacts.rectOverlap;
        pub const carCar = sys_contacts.carCar;
        pub const applyImpulse = sys_contacts.applyImpulse;
        pub const resolvePair = sys_contacts.resolvePair;
        pub const carPed = sys_contacts.carPed;
        pub const carHitPed = sys_contacts.carHitPed;
        pub const hurt = sys_health.hurt;
        pub const damageCar = sys_health.damageCar;
        pub const damageCarAt = sys_health.damageCarAt;
        pub const dentAt = sys_health.dentAt;
        pub const sysPedStatus = sys_health.sysPedStatus;
        pub const sysHealth = sys_health.sysHealth;
        pub const sysProjectileHits = sys_projectile_hits.sysProjectileHits;
        pub const countPlayerHit = sys_projectile_hits.countPlayerHit;
        pub const creditKill = sys_scoring.creditKill;
        pub const addPoints = sys_scoring.addPoints;
        pub const creditSlot = sys_scoring.creditSlot;
        pub const nextCombo = sys_scoring.nextCombo;
        pub const scoreKill = sys_scoring.scoreKill;
        pub const scoreWreck = sys_scoring.scoreWreck;
        pub const scoreHijack = sys_scoring.scoreHijack;
        pub const deathCause = sys_health.deathCause;
        pub const sysPickups = sys_pickups.sysPickups;
        pub const initPickup = sys_pickups.initPickup;
        pub const givePickup = sys_pickups.givePickup;
        pub const giveCarPickup = sys_pickups.giveCarPickup;
        pub const sysAmbient = sys_ambient.sysAmbient;
        pub const farFromAll = sys_ambient.farFromAll;
        pub const dir_heading = sys_traffic.dir_heading;
        pub const dir_arrow = sys_traffic.dir_arrow;
        pub const arrowCount = sys_traffic.arrowCount;
        pub const sysTrafficAi = sys_traffic.sysTrafficAi;
        pub const turnPick = sys_traffic.turnPick;
        pub const roadAhead = sys_traffic.roadAhead;
        pub const bodyAhead = sys_traffic.bodyAhead;
        pub const sysRespawn = sys_respawn.sysRespawn;

        // ==================================================================
        // Cross-workstream APIs (plan-notes.md 5), one namespace per owner.
        // Call as `Self.objectives.setObjective(self, ...)`. W0 wrote them as
        // stubs with their final signatures; owners fill them in, callers
        // never edit them. Single-player ones are safe to call in any
        // configuration (they do nothing outside `sp`).

        pub const objectives = @import("ai/objectives.zig").Sys(Self); // D1
        pub const car_tasks = @import("ai/car_tasks.zig").Sys(Self); // F
        pub const route = @import("ai/route.zig").Sys(Self); // F
        pub const career = @import("sp/career.zig").Sys(Self); // G
        pub const wanted = @import("sp/wanted.zig").Sys(Self); // E
        pub const police = @import("sp/police.zig").Sys(Self); // E
        pub const gangs = @import("sp/gangs.zig").Sys(Self); // D2
        pub const groups = @import("ai/groups.zig").Sys(Self); // D2
        pub const objects = @import("sys/objects.zig").Sys(Self); // B
        pub const lights = @import("sys/lights.zig").Sys(Self); // B
        pub const hooks = @import("script/hooks.zig").Sys(Self); // A1
        pub const hud = @import("sp/hud.zig").Sys(Self); // A1
        pub const script = @import("script/vm.zig").Sys(Self); // A1
        pub const shops = shops_sys.Sys(Self); // B
        pub const death = @import("sys/death.zig").Sys(Self); // G
        pub const car_weapons = @import("sys/car_weapons.zig").Sys(Self); // G
        pub const car_flags = @import("sys/car_flags.zig").Sys(Self); // vehicles
        pub const CarHitCause = @import("sys/car_flags.zig").Cause;
        pub const trailers = @import("sys/trailers.zig").Sys(Self); // vehicles
        pub const cranes = @import("sys/cranes.zig").Sys(Self); // vehicles
        pub const trains = @import("sys/trains.zig").Sys(Self); // vehicles
        pub const spawn = sys_spawn; // F
        pub const surfaces = sys_surfaces; // C

        // ==================================================================
        // I1

        pub fn init(self: *Self, grid: *const abi.Grid, p: abi.InitParams) void {
            @memset(std.mem.asBytes(&self.state), 0);
            @memset(std.mem.asBytes(&self.scratch), 0);
            self.grid = grid;
            self.level = null;
            self.shop_count = 0;
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
            // The fixed order (plan-notes.md 3.7). Stubs from W0 are marked
            // with their owner; single-player systems run only in `sp`.
            self.sysInput(frames);
            if (comptime single_player) script.sysScript(self); // A1
            if (comptime city) {
                gangs.sysGangs(self); // D2
                wanted.sysWanted(self); // E
                police.sysPolice(self); // E
                objectives.sysObjectives(self); // D1
            }
            self.sysPedAi();
            self.sysTrafficAi();
            car_tasks.sysCarTasks(self); // F
            spawn.sysZoneSpawn(self); // F
            self.sysPedControl();
            self.sysEnterExit(); // D2: after on-foot control, before movement
            self.sysCarControl();
            car_weapons.sysCarWeapons(self); // G
            self.sysWeapons();
            self.sysExplosions();
            self.sysMoveCars();
            trailers.sysTrailers(self); // vehicles: pairs follow their cabs
            if (comptime city) trains.sysTrains(self); // vehicles: trains run on their rails
            self.sysMovePeds();
            self.sysMoveProjectiles();
            self.buildBroadphase();
            self.sysContacts();
            self.sysProjectileHits();
            objects.sysObjects(self); // B
            if (comptime city) cranes.sysCranes(self); // vehicles
            shops.sysShops(self); // B
            self.sysPickups();
            surfaces.sysSurfaces(self); // C
            self.sysPedStatus();
            self.sysRiders();
            self.sysHealth();
            car_flags.sysCarFlags(self); // vehicles
            if (comptime single_player) death.sysDeath(self); // G
            self.sysRespawn();
            self.sysAmbient();
            if (comptime city) lights.sysLights(self); // B
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
                if (id.kind() == @backingInt(K.kind)) {
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
                if (id.kind() == @backingInt(K.kind)) {
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
            v[1] = .{ .kind = @backingInt(abi.Kind.player_row), .component = abi.ColumnDesc.Special.player_rows, .offset = @offsetOf(State, "players"), .stride = @sizeOf(abi.PlayerRow), .count = cfg.max_players };
            var i: usize = 2;
            const world_off = @offsetOf(State, "world") + @offsetOf(World, "tables");
            for (World.Kinds) |K| {
                const TT = ecs.Table(K);
                const base = world_off + @offsetOf(@FieldType(World, "tables"), K.name);
                const k: u8 = @backingInt(K.kind);
                v[i] = .{ .kind = k, .component = abi.ColumnDesc.Special.len, .offset = base + @offsetOf(TT, "len"), .stride = 4, .count = 1 };
                v[i + 1] = .{ .kind = k, .component = abi.ColumnDesc.Special.generation, .offset = base + @offsetOf(TT, "gen"), .stride = 2, .count = K.capacity };
                v[i + 2] = .{ .kind = k, .component = abi.ColumnDesc.Special.slot, .offset = base + @offsetOf(TT, "slot"), .stride = 1, .count = K.capacity };
                i += 3;
                const cols_off = base + @offsetOf(TT, "cols");
                for (K.components) |C| {
                    v[i] = .{
                        .kind = k,
                        .component = @backingInt(C.id),
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

        pub fn emptyRow() abi.PlayerRow {
            return .{ .ped = .none, .car = .none, .kills = 0, .deaths = 0, .score = 0, .respawn_timer = 0, .flags = 0 };
        }

        pub inline fn predicting(self: *const Self) bool {
            return self.mode == .predict;
        }

        pub fn seed(self: *const Self) u64 {
            return (@as(u64, self.state.seed_hi) << 32) | self.state.seed_lo;
        }

        /// The only randomness: a keyed hash (I1 rule 4).
        pub fn rand(self: *const Self, entity: EntityId, salt: u32) u32 {
            return abi.rand(self.seed(), self.state.tick, entity, salt);
        }

        pub fn randBelow(self: *const Self, entity: EntityId, salt: u32, n: u32) u32 {
            return @truncate((@as(u64, self.rand(entity, salt)) * n) >> 32);
        }

        /// May this step write to entity `id`? Always in authoritative mode;
        /// only predicted entities in predict mode.
        pub fn writable(self: *Self, id: EntityId) bool {
            if (!self.predicting()) return true;
            const w = &self.state.world;
            if (w.get(id, c.Predicted)) |p| return p.on != 0;
            return false;
        }

        pub fn pushEvent(self: *Self, e: Event) void {
            if (self.predicting()) return;
            const sc = &self.scratch;
            if (sc.event_len >= max_events) return;
            sc.event_buf[sc.event_len] = e;
            sc.event_len += 1;
        }

        pub fn pushIntent(self: *Self, op: abi.Intent.Op, kind: abi.Kind, source: EntityId, t: c.Transform) void {
            const sc = &self.scratch;
            if (sc.intent_len >= max_intents) {
                sc.stats.intents_dropped += 1;
                return;
            }
            sc.intent_buf[sc.intent_len] = .{ .op = op, .kind = @backingInt(kind), .source = source, .x = t.x, .y = t.y, .z = t.z, .heading = t.heading };
            sc.intent_len += 1;
        }

        /// Despawn, or in predict mode report it as an intent.
        pub fn kill(self: *Self, id: EntityId) void {
            const w = &self.state.world;
            if (self.predicting()) {
                const t = (w.get(id, c.Transform) orelse return).*;
                self.pushIntent(.despawn, @fromBackingInt(@intCast(id.kind())), id, t);
                return;
            }
            w.despawn(id);
        }

        pub fn speedOf(v: *const c.Velocity) Fx {
            return fx.length(v.vx, v.vy);
        }

        // ==================================================================
        // Spawning (authoritative only; spawn sites report intents instead)

        pub const Spot = struct { x: Fx, y: Fx, z: Fx, heading: u16 };
        pub const Block = struct { x: i32, y: i32 };

        // ==================================================================
        // Commands

        // ==================================================================
        // Systems, in tick order

        // ------------------------------------------------------------------
        // Movement against the map

        // ------------------------------------------------------------------
        // Contacts between bodies

        // ------------------------------------------------------------------
        // Traffic

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

        /// Attach the level's static data (not part of I1, like
        /// `spawnCarAt`). Call after `init`, which detaches it; with no level
        /// the sim runs as before. `level` must outlive the sim, and every
        /// host in a session must attach the same one.
        pub fn attachLevel(self: *Self, l: *const Level) void {
            self.level = l;
            shops.collect(self, l);
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
/// Deathmatch with police (`config_16_police`).
pub const Sim16Police = Sim(config_16_police);

comptime {
    abi.checkSim(Sim16);
    abi.checkSim(Sim16Police);
}
