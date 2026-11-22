//! Trains. Owner: vehicles. There is no train behaviour note yet
//! (docs/behaviour/README.md, "Public transport"), so what a train does is
//! ours, built from the player's own data and the few hooks other notes
//! give:
//!
//! - **Rails.** A railway block is a "field" ground block with green
//!   arrows: in all three districts the tracks are one-block lines of such
//!   blocks, raised and ramped, and no road uses that ground type with
//!   arrows. A train follows the arrows; where a block offers more than one
//!   way on, it picks one by the block and the train.
//! - **Stations.** The map's railway zones (`level.ZoneKind`): a platform,
//!   and on the track beside it an entry point, a stop point and an exit
//!   point, named after the station (`trak00platform`, `trak00entry`,
//!   `trak00stop`, `trak00exit`). Each level script declares its trains
//!   with type 285 (script-declarations.md 2.13): the station's platform
//!   zone and the coaches, freight wagons and boxcars behind the engine
//!   (286, an empty station, declares none). A declared train starts at its
//!   station's entry point.
//! - **Running.** The engine runs at a fixed top speed and brakes for the
//!   next stop point ahead, waits there, then pulls away. Its carriages
//!   follow the trail the engine leaves (`train_crumb` apart), so the whole
//!   train takes the same path round corners.
//! - **Other notes.** Trains follow the railway height, not the ground
//!   (car-height.md 3.7); take no damage (explosions-and-damage.md); a
//!   moving train blows up a car it touches (car-collision.md 3.6); a
//!   carriage can be entered only while its train is stopped
//!   (entering-and-exiting-cars.md 3.1), and its passenger rides, unable to
//!   drive, until the next stop. The four train models have no doors
//!   except the coaches and the engine (public-sources.md 1).
//!
//! The trains run in the city configurations (single player and police
//! rooms), where level scripts declare them. Their state is in
//! `state.sp.trains`; the carriages are ordinary cars with
//! `Vehicle.train` set, so they replicate like any car.

const std = @import("std");
const prelude = @import("../prelude.zig");
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const TV = @import("../tuning/vehicles.zig");
const level = @import("interfaces").level;

/// One train. No implicit padding: the state is hashed byte for byte.
pub const Train = extern struct {
    /// Engine first, then the carriages in order; none past `count`.
    cars: [TV.max_carriages]EntityId = @splat(.none),
    /// Each carriage's centre, as a distance back along the trail from the
    /// engine's centre.
    offset: [TV.max_carriages]Fx = @splat(0),
    /// The trail: a point every `train_crumb` the engine has run, newest
    /// at `head`.
    trail_x: [TV.train_crumbs]Fx = @splat(0),
    trail_y: [TV.train_crumbs]Fx = @splat(0),
    trail_z: [TV.train_crumbs]Fx = @splat(0),
    /// The engine's centre on the rail.
    x: Fx = 0,
    y: Fx = 0,
    z: Fx = 0,
    /// Speed (blocks a tick) and the distance run since the newest point.
    speed: Fx = 0,
    since: Fx = 0,
    /// Ticks left waiting at a station.
    timer: u16 = 0,
    /// The stop zone last served (index + 1), ignored once `run` passes 8.
    last_stop: u16 = 0,
    /// Blocks run since the last stop, saturating.
    run: u16 = 0,
    head: u8 = 0,
    /// Trail points recorded, up to `train_crumbs`.
    filled: u8 = 0,
    count: u8 = 0,
    /// Travel: 0 +x, 1 +y, 2 -x, 3 -y.
    dir: u8 = 0,
    /// `phase_*`.
    phase: u8 = 0,
    used: u8 = 0,

    pub const phase_running: u8 = 0;
    pub const phase_waiting: u8 = 1;
};

pub const State = extern struct {
    trains: [TV.max_trains]Train = @splat(.{}),
};

/// Travel direction `d` as a sim arrow bit (map.Arrow).
fn arrowBit(d: u8) u4 {
    return switch (d & 3) {
        0 => map.Arrow.pos_x,
        1 => map.Arrow.pos_y,
        2 => map.Arrow.neg_x,
        else => map.Arrow.neg_y,
    };
}
fn dx(d: u8) Fx {
    return switch (d & 3) {
        0 => fx.one,
        2 => -fx.one,
        else => 0,
    };
}
fn dy(d: u8) Fx {
    return switch (d & 3) {
        1 => fx.one,
        3 => -fx.one,
        else => 0,
    };
}

/// The arrows of the railway block at (bx, by) near height z, 0 if none.
pub fn railArrows(g: *const map.Grid, bx: i32, by: i32, z: Fx) u4 {
    var l = fx.toInt(z) + 1;
    while (l >= fx.toInt(z) - 1) : (l -= 1) {
        const cell = map.cellAt(g, bx, by, l);
        if (map.groundOf(cell) == map.Ground.field and map.arrowsOf(cell) != 0) return map.arrowsOf(cell);
    }
    return 0;
}

/// The topmost railway block at (bx, by): its layer, or null.
fn railLayer(g: *const map.Grid, bx: i32, by: i32) ?i32 {
    var l: i32 = map.size_z - 1;
    while (l >= 0) : (l -= 1) {
        const cell = map.cellAt(g, bx, by, l);
        if (map.groundOf(cell) == map.Ground.field and map.arrowsOf(cell) != 0) return l;
    }
    return null;
}

fn zoneIndex(l: *const level.Level, kind: level.ZoneKind, bx: i32, by: i32) ?u16 {
    for (l.zones, 0..) |z, i| if (z.kind == kind and z.contains(bx, by)) return @intCast(i);
    return null;
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const Me = @This();

        fn st(self: *Self) *State {
            return &self.state.sp.trains;
        }

        /// Is `car` a carriage of a train that is moving (or about to)?
        pub fn moving(self: *Self, car: EntityId) bool {
            if (comptime !Self.city) return false;
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            if (v.train == 0 or v.train > TV.max_trains) return false;
            return st(self).trains[v.train - 1].phase != Train.phase_waiting;
        }

        /// Declaration 285/286: a train starting at the station whose
        /// platform zone is `platform`, with that many coaches, freight
        /// wagons and boxcars (counts held to the carriage limit). A
        /// station with none (286) gets no train. Returns the engine.
        pub fn declare(self: *Self, platform: []const u8, coaches: u16, freight: u16, boxcars: u16) ?EntityId {
            if (comptime !Self.city) return null;
            if (self.predicting()) return null;
            const l = self.level orelse return null;
            const total = @as(u32, coaches & 0xFF) + (freight & 0xFF) + (boxcars & 0xFF);
            if (total == 0) return null;
            // The station's entry point: the platform's name with "entry"
            // for "platform".
            const stem = if (std.mem.endsWith(u8, platform, "platform")) platform[0 .. platform.len - "platform".len] else platform;
            var entry: ?level.Zone = null;
            for (l.zones) |z| {
                if (z.kind != .railway_station_entry) continue;
                if (z.name.len == stem.len + "entry".len and std.mem.startsWith(u8, z.name, stem) and std.mem.endsWith(u8, z.name, "entry")) entry = z;
            }
            const e = entry orelse return null;
            const s = st(self);
            const slot = for (&s.trains, 0..) |*t, i| {
                if (t.used == 0) break i;
            } else return null;
            const tr = &s.trains[slot];
            tr.* = .{};
            const layer = railLayer(self.grid, e.x, e.y) orelse return null;
            const arrows = railArrows(self.grid, e.x, e.y, fx.fromInt(layer));
            tr.dir = for (0..4) |d| {
                if (arrows & arrowBit(@intCast(d)) != 0) break @intCast(d);
            } else 0;
            tr.x = fx.fromInt(e.x) + fx.half;
            tr.y = fx.fromInt(e.y) + fx.half;
            tr.z = map.floorAt(self.grid, tr.x, tr.y, fx.fromInt(layer), fx.one);
            tr.used = 1;
            // The makeup: engine, coaches, freight, boxcars.
            var models: [TV.max_carriages]u8 = undefined;
            var n: usize = 0;
            models[0] = TV.train_engine;
            n = 1;
            for ([_]struct { m: u8, k: u16 }{ .{ .m = TV.train_coach, .k = coaches & 0xFF }, .{ .m = TV.train_freight, .k = freight & 0xFF }, .{ .m = TV.train_boxcar, .k = boxcars & 0xFF } }) |p| {
                var k: u16 = 0;
                while (k < p.k and n < TV.max_carriages) : (k += 1) {
                    models[n] = p.m;
                    n += 1;
                }
            }
            tr.count = @intCast(n);
            var off: Fx = 0;
            for (0..n) |i| {
                const h = T.carModel(models[i]).half_len;
                if (i > 0) off += T.carModel(models[i - 1]).half_len + h + TV.train_gap;
                tr.offset[i] = off;
            }
            // Run the engine on from the entry point until the whole train
            // fits on the trail behind it, then set the carriages on it.
            const length = off + T.carModel(models[n - 1]).half_len + fx.one;
            Me.record(tr);
            var ran: Fx = 0;
            while (ran < length) : (ran += TV.train_crumb) Me.advance(self, tr, TV.train_crumb, false);
            tr.run = 0;
            for (0..n) |i| {
                const id = self.spawnCarAt(tr.x, tr.y, 0, models[i]) orelse break;
                const v = self.state.world.get(id, c.Vehicle).?;
                v.train = @intCast(slot + 1);
                tr.cars[i] = id;
            }
            Me.place(self, tr);
            return tr.cars[0];
        }

        /// Once a tick, after cars move: each train runs along its rails
        /// and sets its carriages on the trail.
        pub fn sysTrains(self: *Self) void {
            if (comptime !Self.city) return;
            if (self.predicting()) return;
            for (&st(self).trains) |*tr| {
                if (tr.used == 0) continue;
                if (tr.phase == Train.phase_waiting) {
                    tr.speed = 0;
                    if (tr.timer > 0) tr.timer -= 1 else tr.phase = Train.phase_running;
                } else {
                    var target = TV.train_speed;
                    if (Me.stopAhead(self, tr)) |d| target = @max(TV.train_creep, @min(target, fx.mul(d, TV.train_brake_per_block) + TV.train_creep));
                    if (tr.speed < target) tr.speed = @min(target, tr.speed + TV.train_accel) else tr.speed = @max(target, tr.speed - TV.train_accel * 2);
                    Me.advance(self, tr, tr.speed, true);
                }
                Me.place(self, tr);
            }
        }

        /// Distance to the next stop point straight ahead, if one is in
        /// sight.
        fn stopAhead(self: *Self, tr: *const Train) ?Fx {
            const l = self.level orelse return null;
            var bx = fx.toInt(tr.x);
            var by = fx.toInt(tr.y);
            var i: i32 = 0;
            while (i <= TV.train_look) : (i += 1) {
                if (zoneIndex(l, .railway_stop, bx, by)) |zi| {
                    if (zi + 1 != tr.last_stop) {
                        const cx = fx.fromInt(bx) + fx.half;
                        const cy = fx.fromInt(by) + fx.half;
                        const d = fx.mul(cx - tr.x, dx(tr.dir)) + fx.mul(cy - tr.y, dy(tr.dir));
                        if (d >= 0) return d;
                    }
                }
                bx += fx.toInt(dx(tr.dir));
                by += fx.toInt(dy(tr.dir));
            }
            return null;
        }

        fn record(tr: *Train) void {
            tr.head = @intCast((@as(u32, tr.head) + 1) % TV.train_crumbs);
            tr.trail_x[tr.head] = tr.x;
            tr.trail_y[tr.head] = tr.y;
            tr.trail_z[tr.head] = tr.z;
            if (tr.filled < TV.train_crumbs) tr.filled += 1;
            tr.since = 0;
        }

        /// Run the engine `dist` along the rails, block centre to block
        /// centre, turning where the arrows lead; with `stops`, halting at
        /// a stop point.
        fn advance(self: *Self, tr: *Train, dist: Fx, stops: bool) void {
            var left = dist;
            var guard: u32 = 0;
            while (left > 0 and guard < 64) : (guard += 1) {
                // Distance to the next block centre ahead.
                const along = fx.mul(tr.x, dx(tr.dir)) + fx.mul(tr.y, dy(tr.dir));
                const centre = if (dx(tr.dir) != 0) fx.fromInt(fx.toInt(tr.x)) + fx.half else fx.fromInt(fx.toInt(tr.y)) + fx.half;
                var to_centre = fx.mul(centre, dx(tr.dir) + dy(tr.dir)) - along;
                if (to_centre <= 0) to_centre += fx.one;
                const step = @min(left, @min(to_centre, TV.train_crumb - tr.since));
                tr.x += fx.mul(step, dx(tr.dir));
                tr.y += fx.mul(step, dy(tr.dir));
                tr.since += step;
                left -= step;
                tr.z = map.floorAt(self.grid, tr.x, tr.y, tr.z, fx.half);
                if (tr.since >= TV.train_crumb) Me.record(tr);
                if (step != to_centre) continue;
                // At a block centre: snap to it.
                const bx = fx.toInt(tr.x);
                const by = fx.toInt(tr.y);
                if (dx(tr.dir) != 0) tr.x = fx.fromInt(bx) + fx.half else tr.y = fx.fromInt(by) + fx.half;
                tr.run +|= 1;
                if (tr.run > 8) tr.last_stop = 0;
                if (stops) if (self.level) |l| if (zoneIndex(l, .railway_stop, bx, by)) |zi| if (zi + 1 != tr.last_stop) {
                    tr.last_stop = zi + 1;
                    tr.run = 0;
                    tr.speed = 0;
                    tr.phase = Train.phase_waiting;
                    tr.timer = TV.train_wait;
                    return;
                };
                // The way on: the block's arrows, not back the way it came.
                const arrows = railArrows(self.grid, bx, by, tr.z);
                const back = (tr.dir + 2) & 3;
                var ways: [4]u8 = undefined;
                var nw: u8 = 0;
                for (0..4) |d| {
                    if (d == back) continue;
                    if (arrows & arrowBit(@intCast(d)) != 0) {
                        ways[nw] = @intCast(d);
                        nw += 1;
                    }
                }
                if (nw == 0) {
                    // The end of the line (none in the districts): wait,
                    // then go back the way it came.
                    if (railArrows(self.grid, bx + fx.toInt(dx(tr.dir)), by + fx.toInt(dy(tr.dir)), tr.z) == 0) {
                        tr.speed = 0;
                        return;
                    }
                    continue;
                }
                const idx: u32 = @intCast((@intFromPtr(tr) - @intFromPtr(&st(self).trains[0])) / @sizeOf(Train));
                const pick: u32 = (@as(u32, @bitCast(bx)) *% 31 +% @as(u32, @bitCast(by)) *% 17 +% idx) % nw;
                tr.dir = ways[pick];
            }
        }

        /// A point `d` back along the trail from the engine's centre
        /// (negative: ahead of it, straight on).
        fn pointAt(tr: *const Train, d: Fx) [3]Fx {
            if (d <= 0) return .{ tr.x - fx.mul(d, dx(tr.dir)), tr.y - fx.mul(d, dy(tr.dir)), tr.z };
            var ax = tr.x;
            var ay = tr.y;
            var az = tr.z;
            var seg = tr.since;
            var rem = d;
            var k: u32 = 0;
            while (k < tr.filled) : (k += 1) {
                const i = (@as(u32, tr.head) + TV.train_crumbs - k) % TV.train_crumbs;
                const bx = tr.trail_x[i];
                const by = tr.trail_y[i];
                const bz = tr.trail_z[i];
                if (rem <= seg and seg > 0) {
                    const f = fx.div(rem, seg);
                    return .{ ax + fx.mul(bx - ax, f), ay + fx.mul(by - ay, f), az + fx.mul(bz - az, f) };
                }
                rem -= seg;
                ax = bx;
                ay = by;
                az = bz;
                seg = TV.train_crumb;
            }
            return .{ ax, ay, az };
        }

        /// Set every carriage on the trail: its centre at its offset, its
        /// heading along the chord between its two ends.
        fn place(self: *Self, tr: *Train) void {
            const w = &self.state.world;
            for (tr.cars[0..tr.count], tr.offset[0..tr.count]) |id, off| {
                const v = w.get(id, c.Vehicle) orelse continue;
                const t = w.get(id, c.Transform) orelse continue;
                const h = T.carModel(v.model).half_len;
                const p = pointAt(tr, off);
                const front = pointAt(tr, off - h);
                const back = pointAt(tr, off + h);
                const vel = w.get(id, c.Velocity).?;
                vel.* = .{ .vx = p[0] - t.x, .vy = p[1] - t.y, .vz = 0, .spin = 0 };
                t.x = p[0];
                t.y = p[1];
                t.z = p[2];
                if (front[0] != back[0] or front[1] != back[1]) t.heading = fx.atan2(front[1] - back[1], front[0] - back[0]);
                v.drive = if (tr.phase == Train.phase_waiting) c.Vehicle.drive_none else c.Vehicle.drive_forward;
                v.pedal = 0;
                v.flags &= ~c.Vehicle.flag_wrecked;
                if (w.get(id, c.Health)) |hp| hp.hp = T.car_damage_max;
            }
        }
    };
}
