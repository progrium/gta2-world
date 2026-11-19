//! Sim core (I1 ABI shape): init(map, seed), step(inputs), save(buf),
//! load(buf), hash(). No I/O, no clock, no floats, no allocation after init.
//!
//! The saved state is `State`: one extern struct, copied with memcpy.
//! Derived per-tick data (the broadphase) lives in `Scratch`, outside it.

const std = @import("std");
pub const fx = @import("fixed.zig");
pub const ecs = @import("ecs.zig");
pub const map = @import("map.zig");
pub const input = @import("input.zig");
pub const c = @import("components.zig");

const Fx = fx.Fx;
const EntityId = ecs.EntityId;
const Button = input.Button;

/// Capacities are configuration, not constants.
pub const Config = struct {
    max_players: u32,
    car_capacity: u16,
    ped_capacity: u16,
    projectile_capacity: u16,
    ambient_peds: u32,
    ambient_cars: u32 = 0,
    /// Side of the square (in blocks, centred on the map) that spawns use.
    /// Small = crowded, which is the expensive case for contacts.
    spawn_area: u32 = 256,
};

pub const config_16: Config = .{
    .max_players = 16,
    .car_capacity = 32,
    .ped_capacity = 128,
    .projectile_capacity = 128,
    .ambient_peds = 100,
    .spawn_area = 48,
};

/// "200 players' worth": the 16-player mix scaled by 12.5x.
pub const config_200: Config = .{
    .max_players = 200,
    .car_capacity = 256,
    .ped_capacity = 1536,
    .projectile_capacity = 1024,
    .ambient_peds = 1250,
    .spawn_area = 170, // same density as 16 players in 48x48
};

pub const Player = extern struct {
    ped: EntityId,
    car: EntityId,
    kills: u32,
    deaths: u32,
    respawn_timer: u32,
    active: u32,
    input: input.Frame,
};

// Tuning (blocks per tick at 30 Hz).
const car_radius = fx.ratio(1, 2);
const ped_radius = fx.ratio(3, 20);
const ped_speed = fx.ratio(8, 100);
const ped_turn: i32 = 1500; // angle units per tick
const car_turn: i32 = 900;
const gravity = fx.ratio(2, 100);
const projectile_speed = fx.ratio(9, 10);
const projectile_ttl = 45;
const fire_cooldown = 8;
const cell_shift = 17; // broadphase cell = 2 blocks
const cells_x = map.size_x >> 1;
const cells_y = map.size_y >> 1;

pub fn Sim(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        pub const config = cfg;

        pub const Car = ecs.Kind("car", cfg.car_capacity, &.{
            c.Transform, c.Velocity, c.Collider, c.Health, c.Vehicle, c.Controller, c.Weapon, c.Predicted,
        });
        pub const Ped = ecs.Kind("ped", cfg.ped_capacity, &.{
            c.Transform, c.Velocity, c.Collider, c.Health, c.Pedestrian, c.Riding, c.Controller, c.Weapon, c.Predicted,
        });
        pub const Shot = ecs.Kind("projectile", cfg.projectile_capacity, &.{
            c.Transform, c.Velocity, c.Projectile,
        });
        pub const World = ecs.World(&.{ Car, Ped, Shot });

        pub const State = extern struct {
            tick: u32,
            num_players: u32,
            rng_lo: u32,
            rng_hi: u32,
            ambient_target: u32,
            _pad: u32 = 0,
            players: [cfg.max_players]Player,
            world: World,
        };

        comptime {
            // Layout guard: no implicit padding in the top-level state.
            var sum: usize = 0;
            for (@typeInfo(State).@"struct".field_types) |FT| sum += @sizeOf(FT);
            if (sum != @sizeOf(State)) @compileError("State has implicit padding");
        }

        const Entry = struct {
            id: EntityId,
            x: Fx,
            y: Fx,
            r: Fx,
            mass: i32,
            next: u32,
        };
        const max_entries = @as(u32, cfg.car_capacity) + cfg.ped_capacity;
        const nil: u32 = 0xFFFF_FFFF;

        pub const Scratch = struct {
            cell_head: [cells_y * cells_x]u32,
            cell_stamp: [cells_y * cells_x]u32,
            entries: [max_entries]Entry,
            n: u32,
            stamp: u32,
            /// Diagnostics only (not saved, not hashed).
            stats: Stats,
        };

        pub const Stats = struct {
            contacts: u64 = 0,
            impacts: u64 = 0,
            shots: u64 = 0,
            shot_hits: u64 = 0,
            ped_deaths: u64 = 0,
            car_wrecks: u64 = 0,
            boardings: u64 = 0,
            exits: u64 = 0,
        };

        state: State,
        scratch: Scratch,
        grid: *const map.Grid,

        // ------------------------------------------------------------------
        // I1

        pub fn init(self: *Self, grid: *const map.Grid, seed: u64, num_players: u32) void {
            @memset(std.mem.asBytes(&self.state), 0);
            @memset(std.mem.asBytes(&self.scratch), 0);
            self.grid = grid;
            const s = &self.state;
            const mixed = splitmix(seed);
            s.rng_lo = @truncate(mixed);
            s.rng_hi = @truncate(mixed >> 32);
            s.num_players = @min(num_players, cfg.max_players);
            s.ambient_target = cfg.ambient_peds;
            for (s.players[0..s.num_players]) |*p| {
                p.ped = .none;
                p.car = .none;
                p.active = 1;
            }
            for (s.players[s.num_players..]) |*p| {
                p.ped = .none;
                p.car = .none;
            }
            var i: u32 = 0;
            while (i < s.num_players) : (i += 1) self.spawnPlayer(i);
            i = 0;
            while (i < cfg.ambient_peds) : (i += 1) _ = self.spawnAmbientPed();
            i = 0;
            while (i < cfg.ambient_cars) : (i += 1) _ = self.spawnCar();
            s.world.applyPending();
        }

        pub fn step(self: *Self, inputs: []const input.Frame) void {
            const s = &self.state;
            for (s.players[0..s.num_players], 0..) |*p, i| {
                p.input = if (i < inputs.len) inputs[i] else input.Frame.zero;
            }
            self.sysInput();
            self.sysPedAi();
            self.sysVehicles();
            self.sysPedMove();
            self.sysWeapons();
            self.sysMoveBodies();
            self.sysMoveProjectiles();
            self.buildBroadphase();
            self.sysContacts();
            self.sysProjectileHits();
            self.sysRiders();
            self.sysHealth();
            self.sysRespawn();
            s.world.applyPending();
            s.tick +%= 1;
        }

        pub const state_size = @sizeOf(State);

        pub fn save(self: *const Self, buf: []u8) usize {
            const bytes = std.mem.asBytes(&self.state);
            @memcpy(buf[0..bytes.len], bytes);
            return bytes.len;
        }

        pub fn load(self: *Self, buf: []const u8) void {
            const bytes = std.mem.asBytes(&self.state);
            @memcpy(bytes, buf[0..bytes.len]);
        }

        pub fn hash(self: *const Self) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.state));
        }

        // ------------------------------------------------------------------
        // RNG: the only source of randomness. PCG-style LCG + xorshift output.

        fn rand(self: *Self) u32 {
            const s = &self.state;
            var x: u64 = (@as(u64, s.rng_hi) << 32) | s.rng_lo;
            x = x *% 6364136223846793005 +% 1442695040888963407;
            s.rng_lo = @truncate(x);
            s.rng_hi = @truncate(x >> 32);
            const xs: u32 = @truncate(((x >> 18) ^ x) >> 27);
            const rot: u5 = @truncate(x >> 59);
            return std.math.rotr(u32, xs, rot);
        }

        fn randBelow(self: *Self, n: u32) u32 {
            return @truncate((@as(u64, self.rand()) * n) >> 32);
        }

        fn splitmix(seed: u64) u64 {
            var z = seed +% 0x9E3779B97F4A7C15;
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            return z ^ (z >> 31);
        }

        // ------------------------------------------------------------------
        // Spawning

        /// A random open ground cell (air at layer 1 over solid ground).
        fn randomStreetPoint(self: *Self) [2]Fx {
            var tries: u32 = 0;
            while (tries < 64) : (tries += 1) {
                const lo: u32 = (map.size_x - cfg.spawn_area) / 2;
                const cx: i32 = @intCast(lo + self.randBelow(cfg.spawn_area));
                const cy: i32 = @intCast(lo + self.randBelow(cfg.spawn_area));
                if (self.grid.at(cx, cy, 1) == map.Type.air and self.grid.at(cx, cy, 0) == map.Type.solid)
                    return .{ fx.fromInt(cx) + fx.half, fx.fromInt(cy) + fx.half };
            }
            return .{ fx.fromInt(2) + fx.half, fx.fromInt(2) + fx.half };
        }

        fn spawnCar(self: *Self) ?EntityId {
            const w = &self.state.world;
            const id = w.spawn(Car) orelse return null;
            const p = self.randomStreetPoint();
            w.get(id, c.Transform).?.* = .{ .x = p[0], .y = p[1], .z = fx.one, .heading = @truncate(self.rand()) };
            w.get(id, c.Collider).?.* = .{ .radius = car_radius, .mass = 10, .flags = 0 };
            w.get(id, c.Health).?.* = .{ .hp = 400, .last_hit_by = .none };
            w.get(id, c.Vehicle).?.* = .{
                .driver = .none,
                .model = self.randBelow(4),
                .grip = fx.ratio(25, 100),
                .accel = fx.ratio(15, 1000),
                .max_speed = fx.ratio(5, 10),
            };
            w.get(id, c.Controller).?.player = c.Controller.no_player;
            w.get(id, c.Weapon).?.* = .{ .cooldown = 0, .ammo = 0 };
            return id;
        }

        fn spawnPed(self: *Self, player: u32) ?EntityId {
            const w = &self.state.world;
            const id = w.spawn(Ped) orelse return null;
            const p = self.randomStreetPoint();
            w.get(id, c.Transform).?.* = .{ .x = p[0], .y = p[1], .z = fx.one, .heading = @truncate(self.rand()) };
            w.get(id, c.Collider).?.* = .{ .radius = ped_radius, .mass = 1, .flags = 0 };
            w.get(id, c.Health).?.* = .{ .hp = 100, .last_hit_by = .none };
            w.get(id, c.Riding).?.vehicle = .none;
            w.get(id, c.Controller).?.player = player;
            w.get(id, c.Pedestrian).?.ai_timer = self.randBelow(60);
            w.get(id, c.Weapon).?.* = .{ .cooldown = 0, .ammo = if (player == c.Controller.no_player) 0 else 9999 };
            return id;
        }

        fn spawnAmbientPed(self: *Self) ?EntityId {
            return self.spawnPed(c.Controller.no_player);
        }

        fn spawnPlayer(self: *Self, pi: u32) void {
            const w = &self.state.world;
            const pl = &self.state.players[pi];
            const ped = self.spawnPed(pi) orelse return;
            // Hold the car population at one per player plus ambient cars;
            // beyond that a respawning player starts on foot.
            const car_target = self.state.num_players + cfg.ambient_cars;
            const car = (if (self.state.world.count(Car) < car_target) self.spawnCar() else null) orelse {
                pl.ped = ped;
                return;
            };
            w.get(ped, c.Predicted).?.on = 1;
            w.get(car, c.Predicted).?.on = 1;
            w.get(car, c.Weapon).?.ammo = 9999;
            self.board(ped, car);
            pl.ped = ped;
            pl.car = car;
        }

        fn board(self: *Self, ped: EntityId, car: EntityId) void {
            const w = &self.state.world;
            w.get(ped, c.Riding).?.vehicle = car;
            w.get(ped, c.Collider).?.flags |= c.Collider.flag_disabled;
            w.get(car, c.Vehicle).?.driver = ped;
            w.get(ped, c.Transform).?.* = w.get(car, c.Transform).?.*;
        }

        fn alight(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const r = w.get(ped, c.Riding).?;
            if (w.get(r.vehicle, c.Vehicle)) |v| {
                if (v.driver.eql(ped)) v.driver = .none;
                if (w.get(r.vehicle, c.Controller)) |ctl| ctl.in = input.Frame.zero;
                if (w.get(r.vehicle, c.Transform)) |ct| {
                    const t = w.get(ped, c.Transform).?;
                    // Step out to the car's left.
                    const lh = ct.heading +% 16384;
                    t.x = ct.x + fx.mul(fx.cos(lh), fx.ratio(8, 10));
                    t.y = ct.y + fx.mul(fx.sin(lh), fx.ratio(8, 10));
                    t.z = ct.z;
                }
            }
            r.vehicle = .none;
            w.get(ped, c.Collider).?.flags &= ~c.Collider.flag_disabled;
            w.get(ped, c.Velocity).?.* = std.mem.zeroes(c.Velocity);
        }

        // ------------------------------------------------------------------
        // Systems, in tick order

        fn sysInput(self: *Self) void {
            self.state.world.each(.{ c.Controller, c.Riding, c.Transform }, self, struct {
                fn f(sim: *Self, id: EntityId, ctl: *c.Controller, ride: *c.Riding, t: *c.Transform) void {
                    if (ctl.player == c.Controller.no_player) return;
                    const w = &sim.state.world;
                    const in = sim.state.players[ctl.player].input;
                    const pressed = in.buttons & ~@as(u16, @truncate(ctl.prev_buttons));
                    ctl.prev_buttons = in.buttons;
                    ctl.in = in;
                    if (pressed & Button.enter_exit != 0) {
                        if (!ride.vehicle.isNone()) {
                            sim.alight(id);
                            sim.scratch.stats.exits += 1;
                        } else if (sim.nearestFreeCar(t.x, t.y)) |car| {
                            sim.board(id, car);
                            sim.scratch.stats.boardings += 1;
                            sim.state.players[ctl.player].car = car;
                        }
                    }
                    if (w.get(ride.vehicle, c.Controller)) |cc| cc.in = in;
                }
            }.f);
        }

        fn nearestFreeCar(self: *Self, x: Fx, y: Fx) ?EntityId {
            const Best = struct { id: EntityId = .none, d: Fx = fx.ratio(3, 2) };
            var best: Best = .{};
            const Ctx = struct { best: *Best, x: Fx, y: Fx };
            self.state.world.each(.{ c.Vehicle, c.Transform }, Ctx{ .best = &best, .x = x, .y = y }, struct {
                fn f(ctx: Ctx, id: EntityId, v: *c.Vehicle, t: *c.Transform) void {
                    if (!v.driver.isNone()) return;
                    const d = fx.length(t.x - ctx.x, t.y - ctx.y);
                    if (d < ctx.best.d) ctx.best.* = .{ .id = id, .d = d };
                }
            }.f);
            return if (best.id.isNone()) null else best.id;
        }

        fn sysPedAi(self: *Self) void {
            self.state.world.each(.{ c.Pedestrian, c.Controller, c.Transform }, self, struct {
                fn f(sim: *Self, _: EntityId, ped: *c.Pedestrian, ctl: *c.Controller, t: *c.Transform) void {
                    if (ctl.player != c.Controller.no_player) return;
                    if (ped.ai_timer == 0) {
                        ped.ai_timer = 30 + sim.randBelow(90);
                        // Mostly keep walking the same way, sometimes turn.
                        ped.ai_heading = t.heading +% @as(u16, @truncate(sim.randBelow(32768))) -% 16384;
                    } else ped.ai_timer -= 1;
                    ctl.in = .{ .steer = 0, .throttle = 100, .buttons = 0, .aim = ped.ai_heading, .seq = 0 };
                }
            }.f);
        }

        fn sysVehicles(self: *Self) void {
            self.state.world.each(.{ c.Vehicle, c.Controller, c.Transform, c.Velocity }, {}, struct {
                fn f(_: void, _: EntityId, v: *c.Vehicle, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity) void {
                    const in = ctl.in;
                    const fwd_x = fx.cos(t.heading);
                    const fwd_y = fx.sin(t.heading);
                    // Decompose velocity into forward and lateral parts.
                    var vf = fx.mul(vel.vx, fwd_x) + fx.mul(vel.vy, fwd_y);
                    var vl = fx.mul(vel.vx, -fwd_y) + fx.mul(vel.vy, fwd_x);
                    vf += fx.mulAxis(v.accel, in.throttle);
                    vf -= vf >> 6; // rolling drag
                    vf = fx.clamp(vf, -(v.max_speed >> 1), v.max_speed);
                    const grip = if (in.buttons & Button.handbrake != 0) v.grip >> 3 else v.grip;
                    vl -= fx.mul(vl, grip);
                    // Steering authority grows with speed, reverses in reverse.
                    const auth = fx.clamp(fx.div(vf, v.max_speed >> 1), -fx.one, fx.one);
                    vel.spin = fx.mul(@as(i32, @divTrunc(@as(i32, in.steer) * car_turn, 127)) << 0, auth);
                    t.heading +%= @as(u16, @truncate(@as(u32, @bitCast(vel.spin))));
                    vel.vx = fx.mul(vf, fwd_x) - fx.mul(vl, fwd_y);
                    vel.vy = fx.mul(vf, fwd_y) + fx.mul(vl, fwd_x);
                }
            }.f);
        }

        fn sysPedMove(self: *Self) void {
            self.state.world.each(.{ c.Pedestrian, c.Riding, c.Controller, c.Transform, c.Velocity }, {}, struct {
                fn f(_: void, _: EntityId, _: *c.Pedestrian, ride: *c.Riding, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity) void {
                    if (!ride.vehicle.isNone()) return;
                    // Direct mode: turn toward the aim heading, walk at throttle.
                    const diff: i16 = @bitCast(ctl.in.aim -% t.heading);
                    const turn = std.math.clamp(@as(i32, diff), -ped_turn, ped_turn);
                    t.heading +%= @as(u16, @truncate(@as(u32, @bitCast(turn))));
                    const sp = fx.mulAxis(ped_speed, if (ctl.in.throttle < 0) 0 else ctl.in.throttle);
                    vel.vx = fx.mul(fx.cos(t.heading), sp);
                    vel.vy = fx.mul(fx.sin(t.heading), sp);
                }
            }.f);
        }

        fn sysWeapons(self: *Self) void {
            self.state.world.each(.{ c.Weapon, c.Controller, c.Transform, c.Velocity, c.Collider }, self, struct {
                fn f(sim: *Self, id: EntityId, wpn: *c.Weapon, ctl: *c.Controller, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    if (wpn.cooldown > 0) wpn.cooldown -= 1;
                    if (col.flags & c.Collider.flag_disabled != 0) return; // riding
                    if (ctl.in.buttons & Button.fire == 0 or wpn.cooldown != 0 or wpn.ammo == 0) return;
                    const w = &sim.state.world;
                    const sid = w.spawn(Shot) orelse return;
                    sim.scratch.stats.shots += 1;
                    wpn.cooldown = fire_cooldown;
                    wpn.ammo -= 1;
                    const dx = fx.cos(t.heading);
                    const dy = fx.sin(t.heading);
                    const off = col.radius + fx.ratio(3, 10);
                    w.get(sid, c.Transform).?.* = .{ .x = t.x + fx.mul(dx, off), .y = t.y + fx.mul(dy, off), .z = t.z, .heading = t.heading };
                    w.get(sid, c.Velocity).?.* = .{ .vx = vel.vx + fx.mul(dx, projectile_speed), .vy = vel.vy + fx.mul(dy, projectile_speed), .vz = 0, .spin = 0 };
                    w.get(sid, c.Projectile).?.* = .{ .owner = id, .ttl = projectile_ttl, .damage = 25 };
                }
            }.f);
        }

        fn sysMoveBodies(self: *Self) void {
            self.state.world.each(.{ c.Transform, c.Velocity, c.Collider }, self.grid, struct {
                fn f(g: *const map.Grid, _: EntityId, t: *c.Transform, vel: *c.Velocity, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    const r = col.radius;
                    const l = fx.toInt(t.z + fx.ratio(1, 8));
                    const bounce = col.mass > 1;
                    // Axis-separated sweep against walls on the body's layer.
                    const nx = t.x + vel.vx;
                    if (blocked(g, nx, t.y, r, l)) {
                        vel.vx = if (bounce) -(vel.vx >> 2) else 0;
                    } else t.x = nx;
                    const ny = t.y + vel.vy;
                    if (blocked(g, t.x, ny, r, l)) {
                        vel.vy = if (bounce) -(vel.vy >> 2) else 0;
                    } else t.y = ny;
                    // Follow the ground: slopes, steps, falling.
                    if (map.surface(g, t.x, t.y, t.z)) |h| {
                        if (t.z <= h + fx.ratio(1, 4)) {
                            t.z = h;
                            vel.vz = 0;
                            return;
                        }
                    }
                    vel.vz -= gravity;
                    t.z += vel.vz;
                    if (t.z < fx.one) {
                        t.z = fx.one;
                        vel.vz = 0;
                    }
                }
            }.f);
        }

        fn blocked(g: *const map.Grid, x: Fx, y: Fx, r: Fx, l: i32) bool {
            const x0 = fx.toInt(x - r);
            const x1 = fx.toInt(x + r);
            const y0 = fx.toInt(y - r);
            const y1 = fx.toInt(y + r);
            var cy = y0;
            while (cy <= y1) : (cy += 1) {
                var cx = x0;
                while (cx <= x1) : (cx += 1) {
                    if (g.isWall(cx, cy, l)) return true;
                }
            }
            return false;
        }

        fn sysMoveProjectiles(self: *Self) void {
            const Ctx = struct { g: *const map.Grid, w: *World };
            self.state.world.each(.{ c.Transform, c.Velocity, c.Projectile }, Ctx{ .g = self.grid, .w = &self.state.world }, struct {
                fn f(ctx: Ctx, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile) void {
                    if (p.ttl == 0) return ctx.w.despawn(id);
                    p.ttl -= 1;
                    t.x += vel.vx;
                    t.y += vel.vy;
                    if (ctx.g.isWall(fx.toInt(t.x), fx.toInt(t.y), fx.toInt(t.z + fx.ratio(1, 8))))
                        ctx.w.despawn(id);
                }
            }.f);
        }

        fn cellOf(x: Fx, y: Fx) u32 {
            const cx: u32 = @intCast(std.math.clamp(x >> cell_shift, 0, cells_x - 1));
            const cy: u32 = @intCast(std.math.clamp(y >> cell_shift, 0, cells_y - 1));
            return cy * cells_x + cx;
        }

        /// Uniform grid of 2x2-block cells. Rebuilt every tick from state, so
        /// it never needs saving. Stamps avoid clearing the cell array.
        fn buildBroadphase(self: *Self) void {
            const sc = &self.scratch;
            sc.n = 0;
            sc.stamp +%= 1;
            if (sc.stamp == 0) {
                @memset(&sc.cell_stamp, 0);
                sc.stamp = 1;
            }
            self.state.world.each(.{ c.Transform, c.Collider }, sc, struct {
                fn f(s: *Scratch, id: EntityId, t: *c.Transform, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    const cell = cellOf(t.x, t.y);
                    if (s.cell_stamp[cell] != s.stamp) {
                        s.cell_stamp[cell] = s.stamp;
                        s.cell_head[cell] = nil;
                    }
                    s.entries[s.n] = .{ .id = id, .x = t.x, .y = t.y, .r = col.radius, .mass = col.mass, .next = s.cell_head[cell] };
                    s.cell_head[cell] = s.n;
                    s.n += 1;
                }
            }.f);
        }

        fn sysContacts(self: *Self) void {
            const sc = &self.scratch;
            const w = &self.state.world;
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
                            self.resolvePair(w, &sc.entries[i], &sc.entries[j]);
                        }
                    }
                }
            }
        }

        fn resolvePair(self: *Self, w: *World, a: *Entry, b: *Entry) void {
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
            const total = a.mass + b.mass;
            const push_a = @divTrunc(pen * b.mass, total);
            const push_b = pen - push_a;
            ta.x -= fx.mul(nx, push_a);
            ta.y -= fx.mul(ny, push_a);
            tb.x += fx.mul(nx, push_b);
            tb.y += fx.mul(ny, push_b);
            // Exchange normal momentum (inelastic).
            const rel = fx.mul(vb.vx - va.vx, nx) + fx.mul(vb.vy - va.vy, ny);
            if (rel < 0) {
                const imp_a = @divTrunc(rel * b.mass, total);
                const imp_b = rel - imp_a;
                va.vx += fx.mul(nx, imp_a);
                va.vy += fx.mul(ny, imp_a);
                vb.vx -= fx.mul(nx, imp_b);
                vb.vy -= fx.mul(ny, imp_b);
                // Damage scales with closing speed; peds hit by cars hurt most.
                const speed = -rel;
                if (speed > fx.ratio(1, 10)) {
                    self.scratch.stats.impacts += 1;
                    const dmg: i32 = fx.toInt(fx.mul(speed, fx.fromInt(120)));
                    self.hurt(w, b.id, if (a.mass > b.mass) dmg * 4 else dmg, a.id);
                    self.hurt(w, a.id, if (b.mass > a.mass) dmg * 4 else dmg, b.id);
                }
            }
            a.x = ta.x;
            a.y = ta.y;
            b.x = tb.x;
            b.y = tb.y;
        }

        fn hurt(_: *Self, w: *World, id: EntityId, dmg: i32, by: EntityId) void {
            if (w.get(id, c.Health)) |h| {
                h.hp -= dmg;
                h.last_hit_by = by;
            }
        }

        fn sysProjectileHits(self: *Self) void {
            self.state.world.each(.{ c.Transform, c.Velocity, c.Projectile }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, vel: *c.Velocity, p: *c.Projectile) void {
                    const sc = &sim.scratch;
                    const w = &sim.state.world;
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
                                if (e.id.eql(p.owner)) continue;
                                const fxv: i64 = e.x - x0;
                                const fyv: i64 = e.y - y0;
                                // tq = projection parameter in Q16, clamped to [0, 1]
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
                        sim.hurt(w, sc.entries[best].id, p.damage, p.owner);
                        w.despawn(id);
                    }
                }
            }.f);
        }

        /// Riders follow their vehicle.
        fn sysRiders(self: *Self) void {
            self.state.world.each(.{ c.Riding, c.Transform }, &self.state.world, struct {
                fn f(w: *World, _: EntityId, ride: *c.Riding, t: *c.Transform) void {
                    if (ride.vehicle.isNone()) return;
                    if (w.get(ride.vehicle, c.Transform)) |ct| t.* = ct.* else ride.vehicle = .none;
                }
            }.f);
        }

        fn sysHealth(self: *Self) void {
            // Cars: explode, ejecting the driver.
            self.state.world.each(.{ c.Vehicle, c.Health }, self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, h: *c.Health) void {
                    if (h.hp > 0) return;
                    const w = &sim.state.world;
                    if (!v.driver.isNone() and w.get(v.driver, c.Riding) != null) {
                        sim.alight(v.driver);
                        sim.hurt(w, v.driver, 60, h.last_hit_by);
                    }
                    sim.scratch.stats.car_wrecks += 1;
                    w.despawn(id);
                    // Keep the car population steady.
                    _ = sim.spawnCar();
                }
            }.f);
            self.state.world.each(.{ c.Pedestrian, c.Health, c.Controller }, self, struct {
                fn f(sim: *Self, id: EntityId, _: *c.Pedestrian, h: *c.Health, ctl: *c.Controller) void {
                    if (h.hp > 0) return;
                    const w = &sim.state.world;
                    if (w.get(id, c.Riding)) |r| {
                        if (!r.vehicle.isNone()) sim.alight(id);
                    }
                    sim.scratch.stats.ped_deaths += 1;
                    w.despawn(id);
                    sim.creditKill(h.last_hit_by);
                    if (ctl.player != c.Controller.no_player) {
                        const pl = &sim.state.players[ctl.player];
                        pl.deaths += 1;
                        pl.ped = .none;
                        pl.respawn_timer = 90;
                    } else {
                        _ = sim.spawnAmbientPed();
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
                if (ctl.player != c.Controller.no_player and w.get(shooter, c.Pedestrian) != null)
                    self.state.players[ctl.player].kills += 1;
            }
        }

        fn sysRespawn(self: *Self) void {
            const s = &self.state;
            for (s.players[0..s.num_players], 0..) |*pl, i| {
                if (pl.active == 0 or !pl.ped.isNone()) continue;
                if (pl.respawn_timer > 0) {
                    pl.respawn_timer -= 1;
                    continue;
                }
                self.spawnPlayer(@intCast(i));
            }
        }
    };
}

// ---------------------------------------------------------------------------

test "save, step, load, step gives identical hashes" {
    const S = Sim(.{ .max_players = 4, .car_capacity = 8, .ped_capacity = 32, .projectile_capacity = 32, .ambient_peds = 20, .spawn_area = 32 });
    const g = try std.testing.allocator.create(map.Grid);
    defer std.testing.allocator.destroy(g);
    @memset(std.mem.asBytes(g), 0);
    for (0..map.size_y) |y| for (0..map.size_x) |x| g.set(@intCast(x), @intCast(y), 0, map.Type.solid);
    const s = try std.testing.allocator.create(S);
    defer std.testing.allocator.destroy(s);
    s.init(g, 42, 4);
    var frames: [4]input.Frame = @splat(.{ .steer = 40, .throttle = 100, .buttons = Button.fire, .aim = 0, .seq = 0 });
    for (0..100) |_| s.step(&frames);
    var buf: [S.state_size]u8 = undefined;
    _ = s.save(&buf);
    frames[1].buttons |= Button.enter_exit;
    for (0..50) |_| s.step(&frames);
    const h1 = s.hash();
    s.load(&buf);
    for (0..50) |_| s.step(&frames);
    try std.testing.expectEqual(h1, s.hash());
    // A second instance from the same seed matches too.
    const s2 = try std.testing.allocator.create(S);
    defer std.testing.allocator.destroy(s2);
    s2.init(g, 42, 4);
    s2.load(&buf);
    for (0..50) |_| s2.step(&frames);
    try std.testing.expectEqual(h1, s2.hash());
}
