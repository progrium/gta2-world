//! QA helpers shared by the native runner, the soak and the level runner:
//! per-tick invariant checks and play statistics. They read the sim's state
//! from outside and never change it, so they are safe to run beside a
//! golden replay (the hashes do not move).
//!
//! Invariants (docs/plan-notes.md, workstream Q):
//!   - inside_matter: a body that collides (peds on foot, cars) has matter
//!     around its body height for `stuck_limit` ticks in a row
//!   - below_world: a body under z = 0, or outside the map in x or y
//!   - void: a body standing over a column with no floor at all
//!   - speed: a body moving faster than `max_speed` blocks a tick
//!   - riding: a ped rides a car that is gone, or a car's driver is gone or
//!     rides another car
//!   - player_row: a player row points at a dead ped or car
//!   - capacity: a kind sits at its capacity for `capacity_limit` ticks
//!   - health: hit points above the kind's maximum
//!
//! Each check counts breaks per kind of invariant and keeps the first few
//! with their tick and entity for the report.

const std = @import("std");
const sim = @import("sim");
const fx = sim.fx;
const c = sim.c;
const map = sim.map;
const abi = sim.abi;
const EntityId = abi.EntityId;

pub const Which = enum(u8) {
    inside_matter,
    below_world,
    void,
    speed,
    riding,
    player_row,
    capacity,
    health,
};
pub const n_which = @typeInfo(Which).@"enum".field_names.len;

pub const Break = struct {
    which: Which,
    tick: u32,
    id: u32,
    x: fx.Fx = 0,
    y: fx.Fx = 0,
    z: fx.Fx = 0,
};

pub const Limits = struct {
    /// Ticks in a row inside matter before it counts (a body may graze a
    /// corner for a tick or two while contacts push it out).
    stuck_limit: u32 = 30,
    /// Ticks in a row at capacity before it counts.
    capacity_limit: u32 = 900,
    /// Blocks per tick.
    max_speed: fx.Fx = fx.fromInt(2),
    /// Peds start at `tuning.ped_hp`; cars count down from 32000.
    max_ped_hp: i32 = 1000,
    max_car_hp: i32 = 32000,
};

pub fn Checker(comptime S: type) type {
    const ped_cap = S.Ped.capacity;
    const car_cap = S.Car.capacity;
    return struct {
        const Self = @This();
        limits: Limits = .{},
        counts: [n_which]u64 = @splat(0),
        first: [32]Break = undefined,
        n_first: u32 = 0,
        ticks: u64 = 0,
        ped_stuck: [ped_cap]u16 = @splat(0),
        car_stuck: [car_cap]u16 = @splat(0),
        full_ticks: [3]u32 = @splat(0),

        pub fn total(self: *const Self) u64 {
            var n: u64 = 0;
            for (self.counts) |k| n += k;
            return n;
        }

        fn add(self: *Self, b: Break) void {
            self.counts[@intFromEnum(b.which)] += 1;
            if (self.n_first < self.first.len) {
                self.first[self.n_first] = b;
                self.n_first += 1;
            }
        }

        fn body(self: *Self, s: *S, comptime K: type, id: EntityId, stuck: *u16, step: fx.Fx) void {
            const w = &s.state.world;
            const t = w.get(id, c.Transform).?;
            const tick = s.tick();
            const lim = self.limits;
            const outside = t.x < 0 or t.y < 0 or t.x >= fx.fromInt(map.size_x) or t.y >= fx.fromInt(map.size_y);
            if (outside or t.z < -fx.one) {
                self.add(.{ .which = .below_world, .tick = tick, .id = id.raw, .x = t.x, .y = t.y, .z = t.z });
                return;
            }
            if (w.get(id, c.Velocity)) |v| {
                if (@abs(v.vx) > lim.max_speed or @abs(v.vy) > lim.max_speed or @abs(v.vz) > lim.max_speed)
                    self.add(.{ .which = .speed, .tick = tick, .id = id.raw, .x = t.x, .y = t.y, .z = t.z });
            }
            if (w.get(id, c.Health)) |h| {
                const max_hp = if (K == S.Car) lim.max_car_hp else lim.max_ped_hp;
                if (h.hp > max_hp)
                    self.add(.{ .which = .health, .tick = tick, .id = id.raw, .x = t.x, .y = t.y, .z = t.z });
            }
            const col = w.get(id, c.Collider).?;
            if (col.flags & c.Collider.flag_disabled != 0) {
                stuck.* = 0;
                return;
            }
            // Water: sinking and drowning bodies go into the water cell on
            // purpose.
            if (map.waterAt(s.grid, t.x, t.y, t.z)) {
                stuck.* = 0;
                return;
            }
            if (map.isVoid(s.grid, t.x, t.y, t.z + step)) {
                self.add(.{ .which = .void, .tick = tick, .id = id.raw, .x = t.x, .y = t.y, .z = t.z });
            }
            if (map.blocks(s.grid, t.x, t.y, t.z, step)) {
                if (stuck.* < 0xFFFF) stuck.* += 1;
                if (stuck.* == lim.stuck_limit)
                    self.add(.{ .which = .inside_matter, .tick = tick, .id = id.raw, .x = t.x, .y = t.y, .z = t.z });
            } else stuck.* = 0;
        }

        /// Run every check against the state after a step.
        pub fn check(self: *Self, s: *S) void {
            self.ticks += 1;
            const w = &s.state.world;
            const tick = s.tick();
            // Bodies.
            {
                const tb = w.table(S.Ped);
                var i: u32 = 0;
                while (i < tb.len) : (i += 1) {
                    if (tb.slot[i] != abi.Slot.alive) {
                        self.ped_stuck[i] = 0;
                        continue;
                    }
                    const id = EntityId.make(S.Ped.kind, i, tb.gen[i]);
                    self.body(s, S.Ped, id, &self.ped_stuck[i], sim.tuning.ped_step);
                    const r = w.get(id, c.Riding).?.vehicle;
                    if (!r.isNone() and !w.isAlive(r))
                        self.add(.{ .which = .riding, .tick = tick, .id = id.raw });
                }
            }
            {
                const tb = w.table(S.Car);
                var i: u32 = 0;
                while (i < tb.len) : (i += 1) {
                    if (tb.slot[i] != abi.Slot.alive) {
                        self.car_stuck[i] = 0;
                        continue;
                    }
                    const id = EntityId.make(S.Car.kind, i, tb.gen[i]);
                    self.body(s, S.Car, id, &self.car_stuck[i], sim.tuning.car_step);
                    const d = w.get(id, c.Vehicle).?.driver;
                    if (!d.isNone()) {
                        const ok = w.isAlive(d) and (w.get(d, c.Riding).?.vehicle.raw == id.raw);
                        if (!ok) self.add(.{ .which = .riding, .tick = tick, .id = id.raw });
                    }
                }
            }
            // Player rows.
            for (&s.state.players, 0..) |*p, slot| {
                if (p.flags & abi.PlayerRow.flag_active == 0) continue;
                if (!p.ped.isNone() and w.get(p.ped, c.Transform) == null)
                    self.add(.{ .which = .player_row, .tick = tick, .id = @intCast(slot) });
                if (!p.car.isNone() and w.get(p.car, c.Transform) == null)
                    self.add(.{ .which = .player_row, .tick = tick, .id = @intCast(slot) });
            }
            // Capacity.
            inline for (.{ S.Car, S.Ped, S.Shot }, 0..) |K, ki| {
                if (w.count(K) >= K.capacity) {
                    self.full_ticks[ki] += 1;
                    if (self.full_ticks[ki] == self.limits.capacity_limit)
                        self.add(.{ .which = .capacity, .tick = tick, .id = @intFromEnum(K.kind) });
                } else self.full_ticks[ki] = 0;
            }
        }

        pub fn report(self: *const Self, out: anytype) !void {
            try out.print("invariants: {d} ticks checked, {d} breaks\n", .{ self.ticks, self.total() });
            for (self.counts, 0..) |n, i| {
                if (n > 0) try out.print("  {s}: {d}\n", .{ @tagName(@as(Which, @enumFromInt(i))), n });
            }
            for (self.first[0..self.n_first]) |b| {
                try out.print("  first: {s} tick {d} id {x:0>8} at ({d:.2}, {d:.2}, {d:.2})\n", .{
                    @tagName(b.which), b.tick, b.id, toF(b.x), toF(b.y), toF(b.z),
                });
            }
        }
    };
}

fn toF(v: fx.Fx) f64 {
    return @as(f64, @floatFromInt(v)) / 65536.0;
}

/// Play statistics for a run, in game terms, for the behaviour diff that
/// goes beside every golden re-record.
pub const PlayStats = struct {
    ticks: u64 = 0,
    kills: u64 = 0,
    player_kills: u64 = 0,
    run_over: u64 = 0,
    fire_kills: u64 = 0,
    suicides: u64 = 0,
    explosions: u64 = 0,
    pickups: u64 = 0,
    rounds: u64 = 0,
    shots: u64 = 0,
    shot_hits: u64 = 0,
    ped_deaths: u64 = 0,
    car_wrecks: u64 = 0,
    boardings: u64 = 0,
    exits: u64 = 0,
    contacts: u64 = 0,
    impacts: u64 = 0,
    wall_hits: u64 = 0,
    /// Blocks, summed over players.
    driven: u64 = 0,
    walked: u64 = 0,
    ticks_in_cars: u64 = 0,
    score_total: i64 = 0,
    max_kills: i64 = 0,
    max_deaths: i64 = 0,
    final_cars: u64 = 0,
    final_peds: u64 = 0,
    /// Fixed-point sub-block remainder for distances.
    dist_fx: [2]i64 = .{ 0, 0 },

    pub const fields_shown = [_][]const u8{
        "ticks",       "kills",     "player_kills", "run_over", "fire_kills", "suicides", "explosions",
        "pickups",     "rounds",    "shots",        "shot_hits", "ped_deaths", "car_wrecks", "boardings",
        "exits",       "contacts",  "impacts",      "wall_hits", "driven",     "walked",   "ticks_in_cars",
        "score_total", "max_kills", "max_deaths",   "final_cars", "final_peds",
    };

    /// Per-player last positions, to measure distance.
    pub fn Tracker(comptime S: type) type {
        return struct {
            const T = @This();
            last: [S.config.max_players]?[3]fx.Fx = @splat(null),
            in_car: [S.config.max_players]bool = @splat(false),

            pub fn after(tr: *T, ps: *PlayStats, s: *S) void {
                ps.ticks += 1;
                // An if chain, not a switch, so new event kinds need no
                // change here.
                for (s.events()) |e| {
                    if (e.kind == .kill) {
                        ps.kills += 1;
                        if (e.a != S.Event.no_slot and e.a != e.b) ps.player_kills += 1;
                        if (e.a == e.b) ps.suicides += 1;
                        if (e.c == S.Event.weapon_car) ps.run_over += 1;
                        if (e.c == S.Event.weapon_fire) ps.fire_kills += 1;
                    } else if (e.kind == .explosion) {
                        ps.explosions += 1;
                    } else if (e.kind == .pickup) {
                        ps.pickups += 1;
                    } else if (e.kind == .round_end) {
                        ps.rounds += 1;
                    }
                }
                const w = &s.state.world;
                for (&s.state.players, 0..) |*p, i| {
                    const ped = s.pedOf(@intCast(i)) orelse {
                        tr.last[i] = null;
                        continue;
                    };
                    const veh = w.get(ped, c.Riding).?.vehicle;
                    const body_id = if (!veh.isNone() and w.isAlive(veh)) veh else ped;
                    const t = w.get(body_id, c.Transform).?;
                    const now_in = body_id.raw != ped.raw;
                    if (now_in) ps.ticks_in_cars += 1;
                    if (tr.last[i]) |l| {
                        if (now_in == tr.in_car[i]) {
                            const d: i64 = fx.length(t.x - l[0], t.y - l[1]);
                            // A respawn or teleport is not distance.
                            if (d < fx.fromInt(2)) ps.dist_fx[@intFromBool(now_in)] += d;
                        }
                    }
                    tr.last[i] = .{ t.x, t.y, t.z };
                    tr.in_car[i] = now_in;
                    _ = p;
                }
            }

            pub fn finish(tr: *T, ps: *PlayStats, s: *S) void {
                _ = tr;
                const st = s.scratch.stats;
                ps.shots = st.shots;
                ps.shot_hits = st.shot_hits;
                ps.ped_deaths = st.ped_deaths;
                ps.car_wrecks = st.car_wrecks;
                ps.boardings = st.boardings;
                ps.exits = st.exits;
                ps.contacts = st.contacts;
                ps.impacts = st.impacts;
                ps.wall_hits = st.wall_hits;
                ps.walked = @intCast(@divTrunc(ps.dist_fx[0], fx.one));
                ps.driven = @intCast(@divTrunc(ps.dist_fx[1], fx.one));
                for (&s.state.players) |*p| {
                    ps.score_total += p.score;
                    ps.max_kills = @max(ps.max_kills, p.kills);
                    ps.max_deaths = @max(ps.max_deaths, p.deaths);
                }
                const w = &s.state.world;
                ps.final_cars = w.count(S.Car);
                ps.final_peds = w.count(S.Ped);
            }
        };
    }

    /// `key value` lines, the format of golden/stats.txt.
    pub fn write(ps: *const PlayStats, out: anytype) !void {
        inline for (fields_shown) |f| try out.print("{s} {d}\n", .{ f, @field(ps, f) });
    }

    /// Parse `key value` lines; unknown keys are kept out, missing ones
    /// stay null.
    pub fn parse(text: []const u8) [fields_shown.len]?i64 {
        var r: [fields_shown.len]?i64 = @splat(null);
        var it = std.mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |line| {
            var p = std.mem.tokenizeScalar(u8, line, ' ');
            const k = p.next() orelse continue;
            const v = p.next() orelse continue;
            inline for (fields_shown, 0..) |f, i| {
                if (std.mem.eql(u8, k, f)) r[i] = std.fmt.parseInt(i64, v, 10) catch null;
            }
        }
        return r;
    }

    pub fn values(ps: *const PlayStats) [fields_shown.len]i64 {
        var r: [fields_shown.len]i64 = undefined;
        inline for (fields_shown, 0..) |f, i| r[i] = @intCast(@field(ps, f));
        return r;
    }

    /// Markdown table of old vs new, with the change in percent.
    pub fn diff(out: anytype, old: [fields_shown.len]?i64, new: [fields_shown.len]i64) !void {
        try out.print("| measure | before | after | change |\n|---|---:|---:|---:|\n", .{});
        for (fields_shown, 0..) |f, i| {
            const n = new[i];
            if (old[i]) |o| {
                if (o == n) {
                    try out.print("| {s} | {d} | {d} | same |\n", .{ f, o, n });
                } else if (o == 0) {
                    try out.print("| {s} | {d} | {d} | new |\n", .{ f, o, n });
                } else {
                    const pct = @as(f64, @floatFromInt(n - o)) * 100.0 / @as(f64, @floatFromInt(@abs(o)));
                    try out.print("| {s} | {d} | {d} | {s}{d:.1}% |\n", .{ f, o, n, if (pct > 0) "+" else "", pct });
                }
            } else try out.print("| {s} | - | {d} | new |\n", .{ f, n });
        }
    }
};
