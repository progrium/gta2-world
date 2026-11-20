//! A small I1-conforming sim for netcode work until workstream A's `sim/`
//! lands: an arena with pillars, player cars, AI traffic and wandering peds.
//!
//! It exists to give the netcode something realistic to predict, encode and
//! interpolate: drifting cars that bump each other (S3's handling model,
//! rescaled to I1 units, one block = 1.0), entities that spawn and despawn
//! (so generations change), AI that draws randomness only from `abi.rand`,
//! and a `.predict` mode that steps only `Predicted` entities and turns
//! spawns and despawns into intents. Not a reference for gameplay.
//!
//! Fixed point only at runtime; the sine table is built at comptime.

const std = @import("std");
const itf = @import("interfaces");
const abi = itf.abi;
const input = itf.input;
const Fx = abi.Fx;
const ONE: i32 = abi.fx_one;

/// Sim-owned components (I1 lets `sim/` own these layouts).
pub const Vehicle = extern struct {
    pub const id = abi.ComponentId.vehicle;
    model: u32,
    /// Ticks the car has been sliding; cosmetic (skid marks) and replicated
    /// so the renderer agrees with the server.
    slide: u32,
};

pub const Pedestrian = extern struct {
    pub const id = abi.ComponentId.pedestrian;
    ai_timer: u32,
    ai_heading: u16,
    _pad: u16 = 0,
};

pub const arena_w: Fx = 96 * ONE;
pub const arena_h: Fx = 64 * ONE;
pub const car_r: Fx = 29491; // 0.45 block
const pillar_r: Fx = 58982; // 0.9 block
const ped_r: Fx = 9830; // 0.15 block

pub const Pillar = struct { x: Fx, y: Fx };
pub const pillars = blk: {
    var p: [12]Pillar = undefined;
    var k = 0;
    for (0..4) |i| for (0..3) |j| {
        p[k] = .{ .x = (12 + 24 * i) * ONE, .y = (12 + 20 * j) * ONE };
        k += 1;
    };
    break :blk p;
};

pub fn Sim(comptime cfg: abi.Config) type {
    if (cfg.car_capacity % 4 != 0 or cfg.ped_capacity % 4 != 0) @compileError("capacities must be multiples of 4");
    const ncar = cfg.car_capacity;
    const nped = cfg.ped_capacity;
    const np = cfg.max_players;
    return struct {
        const Self = @This();
        pub const config = cfg;

        /// I3: the replicated component set of each kind, ascending id.
        pub const replicated = .{
            .{ abi.Kind.car, .{ abi.Transform, abi.Velocity, abi.Health, abi.Controller, Vehicle } },
            .{ abi.Kind.ped, .{ abi.Transform, abi.Velocity, abi.Health, abi.Controller, Pedestrian, abi.Riding } },
        };

        pub const CarTable = extern struct {
            len: u32,
            live: u32,
            gen: [ncar]u16,
            slot: [ncar]u8,
            transform: [ncar]abi.Transform,
            velocity: [ncar]abi.Velocity,
            health: [ncar]abi.Health,
            controller: [ncar]abi.Controller,
            vehicle: [ncar]Vehicle,
            predicted: [ncar]abi.Predicted,
        };
        pub const PedTable = extern struct {
            len: u32,
            live: u32,
            gen: [nped]u16,
            slot: [nped]u8,
            transform: [nped]abi.Transform,
            velocity: [nped]abi.Velocity,
            health: [nped]abi.Health,
            controller: [nped]abi.Controller,
            pedestrian: [nped]Pedestrian,
            riding: [nped]abi.Riding,
            predicted: [nped]abi.Predicted,
        };
        pub const State = extern struct {
            tick: u32,
            mode: u32,
            seed: u64,
            players: [np]abi.PlayerRow,
            car: CarTable,
            ped: PedTable,
        };
        comptime {
            for (.{ State, CarTable, PedTable }) |T| {
                var sum: usize = 0;
                for (@typeInfo(T).@"struct".field_types) |FT| sum += @sizeOf(FT);
                if (sum != @sizeOf(T)) @compileError(@typeName(T) ++ " has implicit padding");
            }
        }

        pub const state_size = @sizeOf(State);
        pub const layout_hash = abi.layoutHash(State);

        state: State,
        grid: *const abi.Grid = undefined,
        intent_buf: [64]abi.Intent = undefined,
        intent_len: usize = 0,

        // -------------------------------------------------------------------
        // I1

        pub fn init(self: *Self, grid: *const abi.Grid, p: abi.InitParams) void {
            self.state = std.mem.zeroes(State);
            self.state.seed = p.seed;
            self.state.mode = @intFromEnum(p.mode);
            for (&self.state.players) |*r| r.* = .{ .ped = .none, .car = .none, .kills = 0, .deaths = 0, .score = 0, .respawn_timer = 0, .flags = 0 };
            self.grid = grid;
            self.intent_len = 0;
        }

        pub fn step(self: *Self, frames: []const input.Frame, cmds: []const abi.Command) void {
            self.intent_len = 0;
            const s = &self.state;
            const predict = self.isPredict();
            for (cmds) |c| self.command(c);
            if (!predict) self.spawnAmbient();

            // Controllers, then motion.
            var i: u32 = 0;
            while (i < s.car.len) : (i += 1) {
                if (!self.carSteps(i)) continue;
                const ctl = &s.car.controller[i];
                ctl.prev_buttons = ctl.in.buttons;
                if (ctl.player != abi.Controller.no_player) {
                    if (ctl.player < frames.len) ctl.in = frames[ctl.player].sanitize();
                } else ctl.in = self.trafficAi(i);
                ctl.in.seq = input.seqOf(s.tick);
                self.stepCar(i);
            }
            i = 0;
            while (i < s.ped.len) : (i += 1) {
                if (s.ped.slot[i] != abi.Slot.alive) continue;
                if (predict and s.ped.predicted[i].on == 0) continue;
                self.stepPed(i);
            }
            // Collisions: car pairs, then pillars and walls.
            i = 0;
            while (i < s.car.len) : (i += 1) {
                if (s.car.slot[i] != abi.Slot.alive) continue;
                var j = i + 1;
                while (j < s.car.len) : (j += 1) {
                    if (s.car.slot[j] != abi.Slot.alive) continue;
                    const mi = self.carSteps(i);
                    const mj = self.carSteps(j);
                    if (!mi and !mj) continue;
                    self.collideCars(i, j, mi, mj);
                }
            }
            i = 0;
            while (i < s.car.len) : (i += 1) {
                if (!self.carSteps(i)) continue;
                collideStatic(&s.car.transform[i], &s.car.velocity[i], car_r);
            }
            if (!predict) self.pedLife();
            s.tick +%= 1;
        }

        pub fn save(self: *const Self, buf: []u8) usize {
            @memcpy(buf[0..state_size], std.mem.asBytes(&self.state));
            return state_size;
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

        const view_table = blk: {
            const cb = @offsetOf(State, "car");
            const pb = @offsetOf(State, "ped");
            const ck: u8 = @intFromEnum(abi.Kind.car);
            const pk: u8 = @intFromEnum(abi.Kind.ped);
            const Sp = abi.ColumnDesc.Special;
            const C = abi.ComponentId;
            break :blk [_]abi.ColumnDesc{
                .{ .kind = 0, .component = Sp.tick, .offset = @offsetOf(State, "tick"), .stride = 4, .count = 1 },
                .{ .kind = @intFromEnum(abi.Kind.player_row), .component = Sp.player_rows, .offset = @offsetOf(State, "players"), .stride = @sizeOf(abi.PlayerRow), .count = np },
                .{ .kind = ck, .component = Sp.len, .offset = cb + @offsetOf(CarTable, "len"), .stride = 4, .count = 1 },
                .{ .kind = ck, .component = Sp.generation, .offset = cb + @offsetOf(CarTable, "gen"), .stride = 2, .count = ncar },
                .{ .kind = ck, .component = Sp.slot, .offset = cb + @offsetOf(CarTable, "slot"), .stride = 1, .count = ncar },
                .{ .kind = ck, .component = @intFromEnum(C.transform), .offset = cb + @offsetOf(CarTable, "transform"), .stride = 16, .count = ncar },
                .{ .kind = ck, .component = @intFromEnum(C.velocity), .offset = cb + @offsetOf(CarTable, "velocity"), .stride = 16, .count = ncar },
                .{ .kind = ck, .component = @intFromEnum(C.health), .offset = cb + @offsetOf(CarTable, "health"), .stride = 8, .count = ncar },
                .{ .kind = ck, .component = @intFromEnum(C.controller), .offset = cb + @offsetOf(CarTable, "controller"), .stride = 16, .count = ncar },
                .{ .kind = ck, .component = @intFromEnum(C.vehicle), .offset = cb + @offsetOf(CarTable, "vehicle"), .stride = @sizeOf(Vehicle), .count = ncar },
                .{ .kind = ck, .component = @intFromEnum(C.predicted), .offset = cb + @offsetOf(CarTable, "predicted"), .stride = 4, .count = ncar },
                .{ .kind = pk, .component = Sp.len, .offset = pb + @offsetOf(PedTable, "len"), .stride = 4, .count = 1 },
                .{ .kind = pk, .component = Sp.generation, .offset = pb + @offsetOf(PedTable, "gen"), .stride = 2, .count = nped },
                .{ .kind = pk, .component = Sp.slot, .offset = pb + @offsetOf(PedTable, "slot"), .stride = 1, .count = nped },
                .{ .kind = pk, .component = @intFromEnum(C.transform), .offset = pb + @offsetOf(PedTable, "transform"), .stride = 16, .count = nped },
                .{ .kind = pk, .component = @intFromEnum(C.velocity), .offset = pb + @offsetOf(PedTable, "velocity"), .stride = 16, .count = nped },
                .{ .kind = pk, .component = @intFromEnum(C.health), .offset = pb + @offsetOf(PedTable, "health"), .stride = 8, .count = nped },
                .{ .kind = pk, .component = @intFromEnum(C.controller), .offset = pb + @offsetOf(PedTable, "controller"), .stride = 16, .count = nped },
                .{ .kind = pk, .component = @intFromEnum(C.pedestrian), .offset = pb + @offsetOf(PedTable, "pedestrian"), .stride = @sizeOf(Pedestrian), .count = nped },
                .{ .kind = pk, .component = @intFromEnum(C.riding), .offset = pb + @offsetOf(PedTable, "riding"), .stride = 4, .count = nped },
                .{ .kind = pk, .component = @intFromEnum(C.predicted), .offset = pb + @offsetOf(PedTable, "predicted"), .stride = 4, .count = nped },
            };
        };
        pub fn views() []const abi.ColumnDesc {
            return &view_table;
        }
        pub fn intents(self: *const Self) []const abi.Intent {
            return self.intent_buf[0..self.intent_len];
        }
        pub fn playerRow(self: *Self, slot: u32) *abi.PlayerRow {
            return &self.state.players[slot];
        }

        pub fn replicaPut(self: *Self, id: abi.EntityId) bool {
            const s = &self.state;
            const i = id.index();
            switch (id.kind()) {
                @intFromEnum(abi.Kind.car) => {
                    if (i >= ncar) return false;
                    if (s.car.gen[i] != id.gen() or s.car.slot[i] != abi.Slot.alive) {
                        s.car.gen[i] = id.gen();
                        s.car.slot[i] = abi.Slot.alive;
                        s.car.transform[i] = std.mem.zeroes(abi.Transform);
                        s.car.velocity[i] = std.mem.zeroes(abi.Velocity);
                        s.car.health[i] = std.mem.zeroes(abi.Health);
                        s.car.controller[i] = std.mem.zeroes(abi.Controller);
                        s.car.vehicle[i] = std.mem.zeroes(Vehicle);
                        s.car.predicted[i] = .{ .on = 0 };
                    }
                    if (i + 1 > s.car.len) s.car.len = i + 1;
                    return true;
                },
                @intFromEnum(abi.Kind.ped) => {
                    if (i >= nped) return false;
                    if (s.ped.gen[i] != id.gen() or s.ped.slot[i] != abi.Slot.alive) {
                        s.ped.gen[i] = id.gen();
                        s.ped.slot[i] = abi.Slot.alive;
                        s.ped.transform[i] = std.mem.zeroes(abi.Transform);
                        s.ped.velocity[i] = std.mem.zeroes(abi.Velocity);
                        s.ped.health[i] = std.mem.zeroes(abi.Health);
                        s.ped.controller[i] = std.mem.zeroes(abi.Controller);
                        s.ped.pedestrian[i] = std.mem.zeroes(Pedestrian);
                        s.ped.riding[i] = .{ .vehicle = .none };
                        s.ped.predicted[i] = .{ .on = 0 };
                    }
                    if (i + 1 > s.ped.len) s.ped.len = i + 1;
                    return true;
                },
                else => return false,
            }
        }

        pub fn replicaRemove(self: *Self, id: abi.EntityId) void {
            const s = &self.state;
            const i = id.index();
            switch (id.kind()) {
                @intFromEnum(abi.Kind.car) => if (i < ncar and s.car.gen[i] == id.gen()) {
                    s.car.slot[i] = abi.Slot.free;
                },
                @intFromEnum(abi.Kind.ped) => if (i < nped and s.ped.gen[i] == id.gen()) {
                    s.ped.slot[i] = abi.Slot.free;
                },
                else => {},
            }
        }

        comptime {
            abi.checkSim(Self);
        }

        // -------------------------------------------------------------------
        // Internals

        fn isPredict(self: *const Self) bool {
            return self.state.mode == @intFromEnum(abi.Mode.predict);
        }

        fn carSteps(self: *const Self, i: u32) bool {
            const s = &self.state;
            if (s.car.slot[i] != abi.Slot.alive) return false;
            return !self.isPredict() or s.car.predicted[i].on != 0;
        }

        fn intent(self: *Self, op: abi.Intent.Op, kind: abi.Kind, src: abi.EntityId, t: abi.Transform) void {
            if (self.intent_len == self.intent_buf.len) return;
            self.intent_buf[self.intent_len] = .{ .op = op, .kind = @intFromEnum(kind), .source = src, .x = t.x, .y = t.y, .z = t.z, .heading = t.heading };
            self.intent_len += 1;
        }

        fn allocCar(self: *Self) ?u32 {
            const s = &self.state;
            var i: u32 = 0;
            while (i < ncar) : (i += 1) {
                if (s.car.slot[i] == abi.Slot.free) {
                    s.car.gen[i] +%= 1;
                    s.car.slot[i] = abi.Slot.alive;
                    if (i + 1 > s.car.len) s.car.len = i + 1;
                    s.car.live += 1;
                    return i;
                }
            }
            return null;
        }

        fn allocPed(self: *Self) ?u32 {
            const s = &self.state;
            var i: u32 = 0;
            while (i < nped) : (i += 1) {
                if (s.ped.slot[i] == abi.Slot.free) {
                    s.ped.gen[i] +%= 1;
                    s.ped.slot[i] = abi.Slot.alive;
                    if (i + 1 > s.ped.len) s.ped.len = i + 1;
                    s.ped.live += 1;
                    return i;
                }
            }
            return null;
        }

        fn rnd(self: *const Self, id: abi.EntityId, salt: u32) u32 {
            return abi.rand(self.state.seed, self.state.tick, id, salt);
        }

        fn spawnPoint(self: *const Self, id: abi.EntityId, salt: u32) abi.Transform {
            const r1 = self.rnd(id, salt);
            const r2 = self.rnd(id, salt + 1);
            // Lanes between the pillar rows so spawns never overlap a pillar.
            const x: Fx = @intCast(2 * ONE + @as(i64, r1 % 92) * ONE);
            const y: Fx = @intCast((2 + 10 * @as(i64, r2 % 6)) * ONE + 2 * ONE);
            return .{ .x = x, .y = y, .z = ONE, .heading = @truncate(r2 >> 8) };
        }

        fn command(self: *Self, c: abi.Command) void {
            const s = &self.state;
            if (c.slot >= np or self.isPredict()) return;
            const row = &s.players[c.slot];
            switch (c.op) {
                .join => {
                    if (row.flags & abi.PlayerRow.flag_active != 0) return;
                    const i = self.allocCar() orelse return;
                    const id = abi.EntityId.make(.car, i, s.car.gen[i]);
                    row.* = .{ .ped = .none, .car = id, .kills = 0, .deaths = 0, .score = 0, .respawn_timer = 0, .flags = abi.PlayerRow.flag_active | abi.PlayerRow.flag_connected };
                    var t = self.spawnPoint(abi.EntityId.make(.player_row, c.slot, 0), 11);
                    if (c.arg != 0) {
                        t.x = @intCast((c.arg & 0xFFFF) * @as(u32, @intCast(ONE)) / 256);
                        t.y = @intCast((c.arg >> 16) * @as(u32, @intCast(ONE)) / 256);
                    }
                    self.initCar(i, t, c.slot);
                },
                .leave => {
                    if (row.flags & abi.PlayerRow.flag_active == 0) return;
                    if (!row.car.isNone()) self.freeCar(row.car.index());
                    row.* = .{ .ped = .none, .car = .none, .kills = 0, .deaths = 0, .score = 0, .respawn_timer = 0, .flags = 0 };
                },
                else => {},
            }
        }

        fn initCar(self: *Self, i: u32, t: abi.Transform, player: u32) void {
            const s = &self.state;
            s.car.transform[i] = t;
            s.car.velocity[i] = std.mem.zeroes(abi.Velocity);
            s.car.health[i] = .{ .hp = 100, .last_hit_by = .none };
            s.car.controller[i] = .{ .player = player, .prev_buttons = 0, .in = input.Frame.neutral(0) };
            s.car.vehicle[i] = .{ .model = player & 7, .slide = 0 };
            s.car.predicted[i] = .{ .on = 0 };
        }

        fn freeCar(self: *Self, i: u32) void {
            const s = &self.state;
            if (s.car.slot[i] == abi.Slot.free) return;
            s.car.slot[i] = abi.Slot.free;
            s.car.live -= 1;
        }

        fn spawnAmbient(self: *Self) void {
            const s = &self.state;
            var ambient_cars: u32 = 0;
            var i: u32 = 0;
            while (i < s.car.len) : (i += 1) {
                if (s.car.slot[i] == abi.Slot.alive and s.car.controller[i].player == abi.Controller.no_player) ambient_cars += 1;
            }
            // At most one spawn per kind per tick, so a full refill is spread out.
            if (ambient_cars < cfg.ambient_cars) {
                if (self.allocCar()) |k| {
                    const id = abi.EntityId.make(.car, k, s.car.gen[k]);
                    self.initCar(k, self.spawnPoint(id, 21), abi.Controller.no_player);
                    s.car.vehicle[k].model = 8 + (self.rnd(id, 22) & 7);
                }
            }
            if (s.ped.live < cfg.ambient_peds) {
                if (self.allocPed()) |k| {
                    const id = abi.EntityId.make(.ped, k, s.ped.gen[k]);
                    s.ped.transform[k] = self.spawnPoint(id, 31);
                    s.ped.velocity[k] = std.mem.zeroes(abi.Velocity);
                    s.ped.health[k] = .{ .hp = 20, .last_hit_by = .none };
                    s.ped.controller[k] = .{ .player = abi.Controller.no_player, .prev_buttons = 0, .in = input.Frame.neutral(0) };
                    s.ped.pedestrian[k] = .{ .ai_timer = 0, .ai_heading = s.ped.transform[k].heading };
                    s.ped.riding[k] = .{ .vehicle = .none };
                    s.ped.predicted[k] = .{ .on = 0 };
                }
            }
        }

        /// Peds occasionally "go indoors" (despawn), so ids and generations churn
        /// the way they will with real ambient life.
        fn pedLife(self: *Self) void {
            const s = &self.state;
            var i: u32 = 0;
            while (i < s.ped.len) : (i += 1) {
                if (s.ped.slot[i] != abi.Slot.alive) continue;
                const id = abi.EntityId.make(.ped, i, s.ped.gen[i]);
                if (self.rnd(id, 41) % 1800 == 0) {
                    s.ped.slot[i] = abi.Slot.free;
                    s.ped.live -= 1;
                }
            }
        }

        fn trafficAi(self: *const Self, i: u32) input.Frame {
            const s = &self.state;
            const id = abi.EntityId.make(.car, i, s.car.gen[i]);
            // A new waypoint every 4 s, from the keyed hash.
            const epoch = s.tick / 120;
            const r = abi.rand(s.seed, epoch, id, 51);
            const tx: Fx = @intCast(4 * ONE + @as(i64, r % 88) * ONE);
            const ty: Fx = @intCast(4 * ONE + @as(i64, (r >> 10) % 56) * ONE);
            const t = s.car.transform[i];
            const want = atan2(ty - t.y, tx - t.x);
            const diff: i16 = @bitCast(want -% t.heading);
            const steer = std.math.clamp(@divTrunc(@as(i32, diff), 64), -127, 127);
            const thr: i32 = if (@abs(diff) > 20000) 40 else 90;
            return .{ .steer = @intCast(steer), .throttle = @intCast(thr), .buttons = 0, .aim = 0, .seq = 0 };
        }

        fn stepPed(self: *Self, i: u32) void {
            const s = &self.state;
            const id = abi.EntityId.make(.ped, i, s.ped.gen[i]);
            const p = &s.ped.pedestrian[i];
            if (p.ai_timer == 0) {
                const r = self.rnd(id, 61);
                p.ai_heading = @truncate(r);
                p.ai_timer = 30 + (r >> 20) % 90;
            } else p.ai_timer -= 1;
            const t = &s.ped.transform[i];
            const diff: i16 = @bitCast(p.ai_heading -% t.heading);
            const turn = std.math.clamp(@as(i32, diff), -900, 900);
            t.heading +%= @bitCast(@as(i16, @intCast(turn)));
            const sp: Fx = 3277; // 0.05 block/tick
            const v = &s.ped.velocity[i];
            v.* = .{ .vx = mul(sp, cosA(t.heading)), .vy = mul(sp, sinA(t.heading)), .vz = 0, .spin = turn };
            t.x +%= v.vx;
            t.y +%= v.vy;
            collideStatic(t, v, ped_r);
        }

        // Handling: S3's drift model in blocks per tick.
        const accel: i32 = 1475;
        const brake: i32 = 2458;
        const reverse_accel: i32 = 819;
        const drag: i32 = 2949;
        const grip_normal: i32 = 19661;
        const grip_slide: i32 = 5243;
        const grip_handbrake: i32 = 2621;
        const slide_threshold: i32 = 4915;
        const max_turn: i32 = 1214;
        const full_turn_speed: i32 = 9830;

        fn stepCar(self: *Self, i: u32) void {
            const s = &self.state;
            const t = &s.car.transform[i];
            const v = &s.car.velocity[i];
            const in = s.car.controller[i].in;
            const fx = cosA(t.heading);
            const fy = sinA(t.heading);
            var vf = mul(v.vx, fx) + mul(v.vy, fy);
            var vl = mul(v.vx, -fy) + mul(v.vy, fx);
            const hb = in.buttons & input.Button.handbrake_jump != 0;
            const thr: i32 = in.throttle;
            if (thr > 0) {
                vf += @divTrunc(accel * thr, 127);
            } else if (thr < 0) {
                if (vf > 819) vf += @divTrunc(brake * thr, 127) else vf += @divTrunc(reverse_accel * thr, 127);
            }
            if (hb) vf -= mul(vf, 1311);
            vf -= mul(vf, drag);
            if (thr == 0 and @abs(vf) < 205) vf = 0;
            const sliding = @abs(vl) > slide_threshold;
            const grip = if (hb) grip_handbrake else if (sliding) grip_slide else grip_normal;
            vl -= mul(vl, grip);
            s.car.vehicle[i].slide = if (sliding or hb) s.car.vehicle[i].slide + 1 else 0;

            const speed_factor = std.math.clamp(div(vf, full_turn_speed), -ONE, ONE);
            var target = mul(@divTrunc(max_turn * @as(i32, in.steer), 127) * ONE, speed_factor) >> 16;
            if (hb) target = @divTrunc(target * 3, 2);
            v.spin += @divTrunc(target - v.spin, 3);
            t.heading +%= @truncate(@as(u32, @bitCast(v.spin)));
            v.vx = mul(vf, fx) + mul(vl, -fy);
            v.vy = mul(vf, fy) + mul(vl, fx);
            t.x +%= v.vx;
            t.y +%= v.vy;
        }

        fn collideCars(self: *Self, i: u32, j: u32, mi: bool, mj: bool) void {
            const s = &self.state;
            const a = &s.car.transform[i];
            const b = &s.car.transform[j];
            const va = &s.car.velocity[i];
            const vb = &s.car.velocity[j];
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const min_d = 2 * car_r;
            if (@abs(dx) >= min_d or @abs(dy) >= min_d) return;
            const d = len(dx, dy);
            if (d >= min_d) return;
            var nx: i32 = ONE;
            var ny: i32 = 0;
            if (d != 0) {
                nx = div(dx, d);
                ny = div(dy, d);
            }
            // A frozen (non-predicted) partner is an immovable obstacle.
            const push_a: i32 = if (mi and mj) @divTrunc(min_d - d, 2) else if (mi) min_d - d else 0;
            const push_b: i32 = if (mi and mj) @divTrunc(min_d - d, 2) else if (mj) min_d - d else 0;
            a.x -= mul(nx, push_a);
            a.y -= mul(ny, push_a);
            b.x += mul(nx, push_b);
            b.y += mul(ny, push_b);
            const van = mul(va.vx, nx) + mul(va.vy, ny);
            const vbn = mul(vb.vx, nx) + mul(vb.vy, ny);
            const rel = van - vbn;
            if (rel > 0) {
                const j_imp = mul(rel, 45875); // 0.7: equal masses, restitution 0.4
                if (mi) {
                    va.vx -= mul(j_imp, nx);
                    va.vy -= mul(j_imp, ny);
                    va.spin += @divTrunc(j_imp * 5, 128);
                }
                if (mj) {
                    vb.vx += mul(j_imp, nx);
                    vb.vy += mul(j_imp, ny);
                    vb.spin -= @divTrunc(j_imp * 5, 128);
                }
                const hit = @divTrunc(rel, 2048);
                if (hit > 0) {
                    s.car.health[i].hp -= hit;
                    s.car.health[j].hp -= hit;
                    s.car.health[i].last_hit_by = abi.EntityId.make(.car, j, s.car.gen[j]);
                    s.car.health[j].last_hit_by = abi.EntityId.make(.car, i, s.car.gen[i]);
                }
            }
        }
    };
}

fn collideStatic(t: *abi.Transform, v: *abi.Velocity, r: Fx) void {
    for (pillars) |p| {
        const dx = t.x - p.x;
        const dy = t.y - p.y;
        const min_d = r + pillar_r;
        if (@abs(dx) >= min_d or @abs(dy) >= min_d) continue;
        const d = len(dx, dy);
        if (d >= min_d or d == 0) continue;
        const nx = div(dx, d);
        const ny = div(dy, d);
        t.x = p.x + mul(nx, min_d);
        t.y = p.y + mul(ny, min_d);
        const vn = mul(v.vx, nx) + mul(v.vy, ny);
        if (vn < 0) {
            const k = vn + mul(vn, 19661);
            v.vx -= mul(k, nx);
            v.vy -= mul(k, ny);
        }
    }
    if (t.x < r) {
        t.x = r;
        if (v.vx < 0) v.vx = -mul(v.vx, 19661);
    }
    if (t.x > arena_w - r) {
        t.x = arena_w - r;
        if (v.vx > 0) v.vx = -mul(v.vx, 19661);
    }
    if (t.y < r) {
        t.y = r;
        if (v.vy < 0) v.vy = -mul(v.vy, 19661);
    }
    if (t.y > arena_h - r) {
        t.y = arena_h - r;
        if (v.vy > 0) v.vy = -mul(v.vy, 19661);
    }
}

// ---------------------------------------------------------------------------
// Fixed-point helpers

const sin_bits = 12;
const sin_n = 1 << sin_bits;
const sin_table: [sin_n]i32 = blk: {
    @setEvalBranchQuota(200000);
    var t: [sin_n]i32 = undefined;
    for (0..sin_n) |i| {
        const a: f64 = @as(f64, @floatFromInt(i)) * (2.0 * std.math.pi) / @as(f64, sin_n);
        t[i] = @intFromFloat(@round(@sin(a) * @as(f64, ONE)));
    }
    break :blk t;
};

pub fn sinA(h: u16) i32 {
    return sin_table[h >> (16 - sin_bits)];
}
pub fn cosA(h: u16) i32 {
    return sinA(h +% 16384);
}
pub fn mul(a: i32, b: i32) i32 {
    return @intCast((@as(i64, a) * @as(i64, b)) >> 16);
}
pub fn div(a: i32, b: i32) i32 {
    return @intCast(@divTrunc(@as(i64, a) << 16, @as(i64, b)));
}
fn isqrt64(n: u64) u64 {
    if (n == 0) return 0;
    var x: u64 = n;
    var y: u64 = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}
pub fn len(dx: i32, dy: i32) i32 {
    const sq: u64 = @intCast(@as(i64, dx) * dx + @as(i64, dy) * dy);
    return @intCast(isqrt64(sq));
}

/// Integer atan2 to a binary angle, by bisection on the sine table. Exact
/// enough for steering AI.
pub fn atan2(y: i32, x: i32) u16 {
    if (x == 0 and y == 0) return 0;
    // Octant reduction, then search the first octant.
    const ax: i64 = @intCast(@abs(@as(i64, x)));
    const ay: i64 = @intCast(@abs(@as(i64, y)));
    const swap = ay > ax;
    const num = if (swap) ax else ay;
    const den = if (swap) ay else ax;
    // angle in [0, 8192] (45 degrees) with tan = num/den
    var lo: u32 = 0;
    var hi: u32 = 8192;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        const s: i64 = sinA(@intCast(mid));
        const c: i64 = cosA(@intCast(mid));
        if (s * den < num * c) lo = mid else hi = mid;
    }
    var a: i32 = @intCast(lo);
    if (swap) a = 16384 - a;
    if (x < 0) a = 32768 - a;
    if (y < 0) a = -a;
    return @truncate(@as(u32, @bitCast(a)));
}

test "atan2 quadrants" {
    try std.testing.expect(@abs(@as(i32, atan2(0, 100)) - 0) <= 2);
    try std.testing.expect(@abs(@as(i32, atan2(100, 0)) - 16384) <= 2);
    try std.testing.expect(@abs(@as(i32, atan2(0, -100)) - 32768) <= 2);
    try std.testing.expect(@abs(@as(i32, atan2(-100, 0)) - 49152) <= 2);
    try std.testing.expect(@abs(@as(i32, atan2(100, 100)) - 8192) <= 2);
}

test "testsim conforms, steps, and round-trips state" {
    const S = Sim(.{ .name = "arena_test", .max_players = 4, .car_capacity = 16, .ped_capacity = 32, .projectile_capacity = 0, .ambient_cars = 4, .ambient_peds = 20 });
    const grid = try std.testing.allocator.create(abi.Grid);
    defer std.testing.allocator.destroy(grid);
    const s = try std.testing.allocator.create(S);
    defer std.testing.allocator.destroy(s);
    s.init(grid, .{ .seed = 7, .mode = .authoritative });
    var frames: [4]input.Frame = @splat(input.Frame.neutral(0));
    s.step(&frames, &.{.{ .op = .join, .slot = 0, .arg = 0 }});
    frames[0].throttle = 127;
    frames[0].steer = 50;
    for (0..100) |_| s.step(&frames, &.{});
    var buf: [S.state_size]u8 = undefined;
    _ = s.save(&buf);
    const h0 = s.hash();
    for (0..50) |_| s.step(&frames, &.{});
    const h1 = s.hash();
    try s.load(&buf);
    try std.testing.expectEqual(h0, s.hash());
    for (0..50) |_| s.step(&frames, &.{});
    try std.testing.expectEqual(h1, s.hash());
    try std.testing.expect(s.state.car.live >= 2);
    try std.testing.expect(s.state.ped.live >= 20);
}
