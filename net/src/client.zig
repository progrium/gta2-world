//! Client netcode for one connection: prediction with rewind-and-replay,
//! error smoothing, snapshot interpolation, clock steering, and the input
//! datagram. Generic over any I1 sim type; the sim runs in `.predict` mode.
//!
//! Per client tick: sample a frame, step the predicted world, keep the state
//! in a ring. Per snapshot (tick T): load the ring state at T, write the
//! records into it, choose the Predicted set, replay T..now with the stored
//! frames, and turn the jump in each drawn entity into an offset that decays
//! over `smooth_ms`. Remote players inside the predict radius are
//! dead-reckoned on their last replicated `Controller.in`; everything else is
//! drawn interpolated between snapshot samples `interp_ms` in the past.
//!
//! Display poses are floats (this is presentation, not sim). The clock never
//! fast-forwards: a frame gap over `max_dt_ms` (background tab, debugger)
//! runs one tick and the next snapshot re-targets the lead (S3 bug fix).

const std = @import("std");
const itf = @import("interfaces");
const abi = itf.abi;
const wire = itf.wire;
const input = itf.input;
const schema = @import("schema.zig");
const decoder = @import("decoder.zig");

pub const tick_ms: f64 = 1000.0 / 30.0;
pub const ring_len = 64;
const interp_len = 8;

pub const Options = struct {
    /// Time for a correction to fade (95%), own entity and others.
    smooth_ms_own: f32 = 100,
    /// Others fade slower: S3's blind trials caught predicted remote cars
    /// by their corrections, and the soak shows 250 ms with a 4 block/s cap
    /// brings their jerk below the zero-latency run's.
    smooth_ms_other: f32 = 250,
    /// Corrections larger than this (blocks) snap instead of gliding.
    snap_blocks: f32 = 8,
    /// Cap on how fast a correction may move a drawn entity, in blocks per
    /// second. A large error then fades over longer than `smooth_ms` instead
    /// of sliding the car faster than it drives. 0 = no cap.
    max_fade_speed: f32 = 4,
    /// The cap does not apply to entities this close (blocks) to the own
    /// entity, so cars that touch converge quickly.
    fade_cap_min_dist: f32 = 2,
    /// Also switch an entity to the own fade rate when it comes that close.
    fast_fade_near: bool = false,
    /// How far past its newest sample an interpolated entity is
    /// dead-reckoned before it holds still.
    max_extrapolate_ticks: f64 = 8,
    /// Remote entities are drawn this far in the past.
    interp_ms: f32 = 100,
    /// Predict other cars and peds within this radius (Chebyshev, blocks) of
    /// the own entity, with hysteresis. 0 predicts only the own player.
    predict_enter: f32 = 6,
    predict_leave: f32 = 8,
    /// Server input buffer target in ticks (from `welcome`).
    buffer_ticks: f32 = 2,
    /// A gap between frames longer than this is a hitch, not time to catch up.
    max_dt_ms: f64 = 250,
};

pub const Pose = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    /// binary angle units, 0..65536
    h: f32 = 0,

    fn fromT(t: abi.Transform) Pose {
        return .{ .x = fx(t.x), .y = fx(t.y), .z = fx(t.z), .h = @floatFromInt(t.heading) };
    }
    fn lerp(a: Pose, b: Pose, t: f32) Pose {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t, .z = a.z + (b.z - a.z) * t, .h = wrapH(a.h + wrapD(b.h - a.h) * t) };
    }
};

fn fx(v: abi.Fx) f32 {
    return @as(f32, @floatFromInt(v)) / 65536.0;
}
fn wrapD(d: f32) f32 {
    var x = @mod(d + 32768.0, 65536.0) - 32768.0;
    if (x < -32768.0) x += 65536.0;
    return x;
}
fn wrapH(h: f32) f32 {
    return @mod(h, 65536.0);
}

/// Error-size samples for one class of entity, in blocks.
pub const Samples = struct {
    vals: []f32,
    n: usize = 0,
    total: u64 = 0,

    pub fn add(s: *Samples, v: f32) void {
        s.total += 1;
        if (s.n < s.vals.len) {
            s.vals[s.n] = v;
            s.n += 1;
        }
    }
    pub fn quantile(s: *Samples, q: f32) f32 {
        if (s.n == 0) return 0;
        std.sort.pdq(f32, s.vals[0..s.n], {}, std.sort.asc(f32));
        const i: usize = @min(s.n - 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(s.n)) * q)));
        return s.vals[i];
    }
};

pub const Class = enum { own, predicted, interpolated };

pub fn Client(comptime S: type) type {
    const Sc = schema.Schema(S);
    const Dec = decoder.Decoder(S);
    const N = Sc.total;
    const np = S.config.max_players;
    return struct {
        const Self = @This();
        pub const Schema = Sc;

        const Ent = struct {
            off: Pose = .{},
            /// fade time for the current offset, ms
            tau: f32 = 100,
            pred: bool = false,
            hist: [interp_len]struct { tick: u32, p: Pose, vx: f32, vy: f32, spin: f32 } = undefined,
            nh: u8 = 0,
            gen: u16 = 0,
            /// display pose before the current snapshot was applied
            before: Pose = .{},
            had: bool = false,
            /// pose before the last applied snapshot (for correction stats)
            raw_before: Pose = .{},
        };

        gpa: std.mem.Allocator,
        opts: Options,
        grid: *const abi.Grid,
        sim: *S,
        ring: []u8,
        ring_tick: [ring_len]u32 = @splat(0xFFFF_FFFF),
        inputs: [ring_len]input.Frame = undefined,
        input_tick: [ring_len]u32 = @splat(0xFFFF_FFFF),
        own_slot: u8,
        dec: Dec,
        ents: []Ent,
        render: []u8,
        remote_in: [np]input.Frame = @splat(input.Frame.neutral(0)),
        started: bool = false,

        // clock
        last_now: f64 = 0,
        acc: f64 = 0,
        interval: f64 = tick_ms,
        slack: ?f32 = null,
        last_resync: f64 = -1e9,
        srv_offset: ?f64 = null,
        input_ack: u32 = 0,
        rtt_ms: f32 = 100,
        last_snap_tick: u32 = 0,
        applying_tick: u32 = 0,

        stats: struct {
            snapshots: u64 = 0,
            replays: u64 = 0,
            replay_ticks: u64 = 0,
            max_replay: u32 = 0,
            snaps: u64 = 0,
            no_rewind: u64 = 0,
            resyncs: u64 = 0,
            hitches: u64 = 0,
            steer_jumps: u64 = 0,
            replay_ns: u64 = 0,
        } = .{},
        /// correction sizes (blocks) by class, one sample per entity per
        /// snapshot whose drawn position moved
        corr: [3]Samples,

        pub fn init(gpa: std.mem.Allocator, grid: *const abi.Grid, own_slot: u8, opts: Options) !Self {
            const sim = try gpa.create(S);
            sim.init(grid, .{ .seed = 0, .mode = .predict });
            const ents = try gpa.alloc(Ent, N);
            @memset(ents, .{});
            var corr: [3]Samples = undefined;
            for (&corr) |*c| c.* = .{ .vals = try gpa.alloc(f32, 1 << 16) };
            return .{
                .gpa = gpa,
                .opts = opts,
                .grid = grid,
                .sim = sim,
                .ring = try gpa.alloc(u8, ring_len * S.state_size),
                .own_slot = own_slot,
                .dec = try Dec.init(gpa),
                .ents = ents,
                .render = try gpa.alloc(u8, S.state_size),
                .corr = corr,
            };
        }

        pub fn deinit(self: *Self) void {
            const gpa = self.gpa;
            gpa.destroy(self.sim);
            gpa.free(self.ring);
            self.dec.deinit(gpa);
            gpa.free(self.ents);
            gpa.free(self.render);
            for (&self.corr) |*c| gpa.free(c.vals);
        }

        // ---------------------------------------------------------------
        // ring

        fn saveRing(self: *Self) void {
            const t = self.sim.tick();
            _ = self.sim.save(self.ring[(t % ring_len) * S.state_size ..][0..S.state_size]);
            self.ring_tick[t % ring_len] = t;
        }

        fn ringState(self: *const Self, t: u32) ?[]const u8 {
            if (self.ring_tick[t % ring_len] != t) return null;
            return self.ring[(t % ring_len) * S.state_size ..][0..S.state_size];
        }

        fn frameFor(self: *const Self, t: u32) ?input.Frame {
            if (self.input_tick[t % ring_len] != t) return null;
            return self.inputs[t % ring_len];
        }

        // ---------------------------------------------------------------
        // ticking

        fn stepOnce(self: *Self, own: input.Frame) void {
            var frames: [np]input.Frame = undefined;
            const t = self.sim.tick();
            for (&frames, 0..) |*f, p| {
                f.* = self.remote_in[p];
                f.seq = input.seqOf(t);
            }
            var o = own;
            o.seq = input.seqOf(t);
            frames[self.own_slot] = o;
            self.sim.step(&frames, &.{});
            self.saveRing();
        }

        /// Advance one predicted tick with a new local frame.
        pub fn tick(self: *Self, f: input.Frame) void {
            const t = self.sim.tick();
            var g = f;
            g.seq = input.seqOf(t);
            self.inputs[t % ring_len] = g;
            self.input_tick[t % ring_len] = t;
            self.stepOnce(g);
        }

        /// Per rendered frame: run the ticks that are due, decay offsets.
        /// Returns the number of ticks run.
        pub fn update(self: *Self, now_ms: f64, f: input.Frame) u32 {
            if (!self.started) {
                self.last_now = now_ms;
                return 0;
            }
            var dt = now_ms - self.last_now;
            self.last_now = now_ms;
            if (dt < 0) dt = 0;
            if (dt > self.opts.max_dt_ms) {
                // Background tab or a stall: do not fast-forward. Run one
                // tick and let the next snapshot pull the clock forward.
                self.stats.hitches += 1;
                dt = self.interval;
                self.acc = 0;
            }
            // Clock steering on the server's reported input slack (S3).
            if (self.slack) |sl| {
                const err = sl - self.opts.buffer_ticks;
                if ((err < -3 or err > 6) and now_ms - self.last_resync > 1500) {
                    self.acc -= err * self.interval;
                    self.last_resync = now_ms;
                    self.stats.steer_jumps += 1;
                }
                const dil = std.math.clamp(err * 0.015, -0.08, 0.08);
                self.interval = tick_ms * (1 + dil);
            }
            self.acc += dt;
            var n: u32 = 0;
            while (self.acc >= self.interval and n < 4) : (n += 1) {
                self.acc -= self.interval;
                self.tick(f);
            }
            if (self.acc > self.interval) self.acc = self.interval; // never queue a backlog
            if (self.acc < -10 * self.interval) self.acc = -10 * self.interval;
            // Anything drawn near the own entity fades at the own rate, so
            // cars that are about to touch are drawn where they will touch.
            const own_pose: ?Pose = if (self.ownEntity()) |o| self.basePose(o.k, o.i, now_ms) else null;
            for (self.ents, 0..) |*e, fi| {
                if (self.opts.fast_fade_near and own_pose != null and e.pred and e.tau > self.opts.smooth_ms_own and (e.off.x != 0 or e.off.y != 0)) {
                    const fe = Sc.fromFlat(@intCast(fi));
                    if (Sc.transform(self.sim.stateBytes(), fe.k, fe.i)) |t| {
                        const d = @max(@abs(fx(t.x) - own_pose.?.x), @abs(fx(t.y) - own_pose.?.y));
                        if (d < self.opts.fade_cap_min_dist) e.tau = self.opts.smooth_ms_own;
                    }
                }
                const k = decay(dt, e.tau);
                e.off.x *= k;
                e.off.y *= k;
                e.off.z *= k;
                e.off.h *= k;
            }
            return n;
        }

        fn decay(dt: f64, smooth: f32) f32 {
            if (smooth <= 0) return 0;
            return @floatCast(@exp(-dt * 3.0 / smooth));
        }

        // ---------------------------------------------------------------
        // snapshots

        /// Handle a snapshot or baseline body.
        pub fn onSnapshot(self: *Self, bytes: []const u8, now_ms: f64) !void {
            const snap = (self.dec.decode(bytes) catch |e| switch (e) {
                error.MissingBase => return,
                else => return e,
            }) orelse return;
            const T = snap.header.tick;
            self.stats.snapshots += 1;

            // Server clock estimate: earliest-arrival biased, like S3.
            const sample = @as(f64, @floatFromInt(T)) - now_ms / tick_ms;
            if (self.srv_offset == null or sample > self.srv_offset.? + 3 or snap.baseline) self.srv_offset = sample else self.srv_offset.? += (sample - self.srv_offset.?) * 0.05;
            for (snap.header.players) |p| if (p.slot == self.own_slot) {
                self.slack = @as(f32, @floatFromInt(p.slack_q)) / 4.0;
                self.input_ack = p.input_ack;
            };
            const now16: u16 = @truncate(@as(u64, @intFromFloat(@max(now_ms, 0))));
            const rtt: f32 = @floatFromInt(now16 -% snap.header.echo_time -% snap.header.hold_ms);
            if (rtt < 5000) self.rtt_ms += (rtt - self.rtt_ms) * 0.1;

            // Display poses before any change.
            self.captureBefore(now_ms);

            var cur = self.sim.tick();
            var jumped = false;
            if (!self.started or snap.baseline) {
                self.sim.init(self.grid, .{ .seed = 0, .mode = .predict });
                for (self.ents) |*e| e.* = .{};
                cur = T;
                jumped = true;
            } else if (@as(i32, @bitCast(T -% cur)) >= 0) {
                // The server is at or ahead of us (after a stall): no rewind;
                // apply and jump forward.
                cur = T;
                jumped = true;
                self.stats.resyncs += 1;
            } else if (self.ringState(T)) |st| {
                self.sim.load(st) catch unreachable;
            } else {
                self.stats.no_rewind += 1;
                // Too old to rewind: apply onto the present state.
            }

            const was_tick = self.sim.tick();
            self.applying_tick = T;
            Dec.apply(&snap, self.sim, self, onRecord);
            self.sim.setTick(if (self.ringState(T) != null or jumped) T else was_tick);
            self.last_snap_tick = T;
            self.updateRemoteInputs();
            self.choosePredicted(now_ms);
            self.saveRing();

            // Replay to the present.
            var t = self.sim.tick();
            var n: u32 = 0;
            var last_f = input.Frame.neutral(0);
            while (@as(i32, @bitCast(cur -% t)) > 0) : (t += 1) {
                const f = self.frameFor(t) orelse last_f;
                last_f = f;
                self.stepOnce(f);
                n += 1;
            }
            self.stats.replays += 1;
            self.stats.replay_ticks += n;
            self.stats.max_replay = @max(self.stats.max_replay, n);

            if (jumped) {
                // Run ahead of the server by about half the RTT plus the
                // input buffer, so inputs arrive just in time.
                const lead: u32 = @intFromFloat(@ceil(self.rtt_ms / 2.0 / @as(f32, @floatCast(tick_ms)) + self.opts.buffer_ticks) + 1);
                for (0..lead) |_| self.tick(input.Frame.neutral(0));
                self.acc = 0;
                self.started = true;
                self.last_now = now_ms;
            }
            self.applyCorrections(now_ms, jumped);
        }

        fn onRecord(self: *Self, k: usize, i: u32, op: wire.RecordOp) void {
            const f = Sc.flat(k, i);
            const e = &self.ents[f];
            const st = self.sim.stateBytes();
            switch (op) {
                .remove => {
                    e.nh = 0;
                    e.off = .{};
                    e.had = false;
                },
                else => {
                    if (k == Sc.player_kind) return;
                    const g = Sc.gen(st, k, i);
                    if (g != e.gen or op == .create) {
                        e.nh = 0;
                        e.off = .{};
                        e.gen = g;
                        if (op == .create) e.had = false;
                    }
                    if (Sc.transform(st, k, i)) |tr| {
                        // Interpolation sample at the snapshot's tick.
                        const tk = self.applying_tick;
                        if (e.nh == interp_len) {
                            std.mem.copyForwards(@TypeOf(e.hist[0]), e.hist[0 .. interp_len - 1], e.hist[1..interp_len]);
                            e.nh -= 1;
                        }
                        const v = Sc.velocity(st, k, i) orelse std.mem.zeroes(abi.Velocity);
                        e.hist[e.nh] = .{ .tick = tk, .p = Pose.fromT(tr), .vx = fx(v.vx), .vy = fx(v.vy), .spin = @floatFromInt(v.spin) };
                        e.nh += 1;
                    }
                },
                _ => {},
            }
        }

        fn updateRemoteInputs(self: *Self) void {
            const st = self.sim.stateBytes();
            var p: u32 = 0;
            while (p < np) : (p += 1) {
                if (p == self.own_slot) continue;
                const row = Sc.playerRow(st, p);
                const id = if (!row.car.isNone()) row.car else row.ped;
                if (row.flags & abi.PlayerRow.flag_active == 0 or id.isNone()) {
                    self.remote_in[p] = input.Frame.neutral(0);
                    continue;
                }
                const k = Sc.kindIndex(id.kind()) orelse continue;
                if (!Sc.alive(st, k, id.index())) continue;
                if (Sc.controller(st, k, id.index())) |c| self.remote_in[p] = c.in;
            }
        }

        pub fn ownEntity(self: *const Self) ?struct { k: usize, i: u32 } {
            const st = self.sim.stateBytes();
            const row = Sc.playerRow(st, self.own_slot);
            const id = if (!row.car.isNone()) row.car else row.ped;
            if (id.isNone()) return null;
            const k = Sc.kindIndex(id.kind()) orelse return null;
            if (!Sc.alive(st, k, id.index())) return null;
            return .{ .k = k, .i = id.index() };
        }

        fn ownFlat(self: *const Self) ?usize {
            const o = self.ownEntity() orelse return null;
            return Sc.flat(o.k, o.i);
        }

        fn isOwnId(st: []const u8, row: abi.PlayerRow, k: usize, i: u32) bool {
            const id = Sc.entityId(st, k, i);
            return id.raw == row.car.raw or id.raw == row.ped.raw;
        }

        /// I1 policy: own ped and vehicle, plus cars and peds within the
        /// predict radius of the own entity, with hysteresis.
        fn choosePredicted(self: *Self, now_ms: f64) void {
            _ = now_ms;
            const st: []u8 = @constCast(self.sim.stateBytes());
            const row = Sc.playerRow(st, self.own_slot);
            const own = self.ownEntity();
            const c = if (own) |o| Sc.transform(st, o.k, o.i) else null;
            for (0..Sc.num_kinds) |k| {
                if (!Sc.canPredict(k)) continue;
                var i: u32 = 0;
                while (i < Sc.desc[k].capacity) : (i += 1) {
                    const e = &self.ents[Sc.flat(k, i)];
                    if (!Sc.alive(st, k, i)) {
                        e.pred = false;
                        continue;
                    }
                    var on = isOwnId(st, row, k, i);
                    if (!on and c != null and self.opts.predict_enter > 0) {
                        if (Sc.transform(st, k, i)) |t| {
                            const d = @max(@abs(fx(t.x - c.?.x)), @abs(fx(t.y - c.?.y)));
                            on = d < (if (e.pred) self.opts.predict_leave else self.opts.predict_enter);
                        }
                    }
                    e.pred = on;
                    Sc.setPredicted(st, k, i, on);
                }
            }
        }

        // ---------------------------------------------------------------
        // display

        fn basePose(self: *const Self, k: usize, i: u32, now_ms: f64) ?Pose {
            const st = self.sim.stateBytes();
            if (!Sc.alive(st, k, i)) return null;
            const e = &self.ents[Sc.flat(k, i)];
            const cur_t = Sc.transform(st, k, i) orelse return null;
            if (e.pred) {
                const cur = Pose.fromT(cur_t);
                const a: f32 = @floatCast(std.math.clamp(self.acc / self.interval, 0, 1));
                const prev_state = self.ringState(self.sim.tick() -% 1) orelse return cur;
                if (!Sc.alive(prev_state, k, i) or Sc.gen(prev_state, k, i) != Sc.gen(st, k, i)) return cur;
                const pv = Sc.transform(prev_state, k, i).?;
                return Pose.lerp(Pose.fromT(pv), cur, a);
            }
            // Interpolated, interp_ms in the past on the server's timeline.
            if (e.nh == 0 or self.srv_offset == null) return Pose.fromT(cur_t);
            const rt = now_ms / tick_ms + self.srv_offset.? - @as(f64, self.opts.interp_ms) / tick_ms;
            const h = e.hist[0..e.nh];
            if (rt <= @as(f64, @floatFromInt(h[0].tick))) return h[0].p;
            // Past the newest sample (the budget skipped this entity, or a
            // snapshot was lost): dead-reckon on its velocity for a while.
            const last = h[h.len - 1];
            const ahead = rt - @as(f64, @floatFromInt(last.tick));
            if (ahead > 0) {
                const dtk: f32 = @floatCast(@min(ahead, self.opts.max_extrapolate_ticks));
                return .{ .x = last.p.x + last.vx * dtk, .y = last.p.y + last.vy * dtk, .z = last.p.z, .h = wrapH(last.p.h + last.spin * dtk) };
            }
            var j: usize = h.len - 1;
            while (j > 0) : (j -= 1) {
                const a = h[j - 1];
                const b = h[j];
                if (@as(f64, @floatFromInt(a.tick)) <= rt) {
                    if (rt >= @as(f64, @floatFromInt(b.tick))) return b.p;
                    const span: f64 = @floatFromInt(b.tick - a.tick);
                    return Pose.lerp(a.p, b.p, @floatCast((rt - @as(f64, @floatFromInt(a.tick))) / span));
                }
            }
            return h[h.len - 1].p;
        }

        pub fn displayPose(self: *const Self, k: usize, i: u32, now_ms: f64) ?Pose {
            const b = self.basePose(k, i, now_ms) orelse return null;
            const o = self.ents[Sc.flat(k, i)].off;
            return .{ .x = b.x + o.x, .y = b.y + o.y, .z = b.z + o.z, .h = wrapH(b.h + o.h) };
        }

        fn captureBefore(self: *Self, now_ms: f64) void {
            if (!self.started) return;
            for (0..Sc.num_kinds) |k| {
                if (k == Sc.player_kind) continue;
                var i: u32 = 0;
                while (i < Sc.desc[k].capacity) : (i += 1) {
                    const e = &self.ents[Sc.flat(k, i)];
                    e.had = false;
                    if (self.basePose(k, i, now_ms)) |b| {
                        e.raw_before = b;
                        e.before = .{ .x = b.x + e.off.x, .y = b.y + e.off.y, .z = b.z + e.off.z, .h = b.h + e.off.h };
                        e.had = true;
                    }
                }
            }
        }

        fn applyCorrections(self: *Self, now_ms: f64, jumped: bool) void {
            const own = self.ownFlat();
            const snap_b = self.opts.snap_blocks;
            const own_pose: ?Pose = if (own) |o| blk: {
                const oe = Sc.fromFlat(@intCast(o));
                break :blk self.basePose(oe.k, oe.i, now_ms);
            } else null;
            for (0..Sc.num_kinds) |k| {
                if (k == Sc.player_kind) continue;
                var i: u32 = 0;
                while (i < Sc.desc[k].capacity) : (i += 1) {
                    const fi = Sc.flat(k, i);
                    const e = &self.ents[fi];
                    if (!e.had) continue;
                    const b = self.basePose(k, i, now_ms) orelse continue;
                    // The raw jump (what an unsmoothed client would show).
                    const jx = e.raw_before.x - b.x;
                    const jy = e.raw_before.y - b.y;
                    const jump = @sqrt(jx * jx + jy * jy);
                    const cls: Class = if (own != null and own.? == fi) .own else if (e.pred) .predicted else .interpolated;
                    if (jump > 1e-4 and !jumped) self.corr[@intFromEnum(cls)].add(jump);
                    // Keep the drawn pose where it was; fade the difference.
                    e.off = .{ .x = e.before.x - b.x, .y = e.before.y - b.y, .z = e.before.z - b.z, .h = wrapD(e.before.h - b.h) };
                    const mag = @sqrt(e.off.x * e.off.x + e.off.y * e.off.y);
                    e.tau = if (cls == .own) self.opts.smooth_ms_own else self.opts.smooth_ms_other;
                    // Initial fade speed is 3 * mag / tau; cap it.
                    if (self.opts.max_fade_speed > 0 and (cls != .predicted or own_pose == null or
                        @max(@abs(b.x - own_pose.?.x), @abs(b.y - own_pose.?.y)) > self.opts.fade_cap_min_dist))
                        e.tau = @max(e.tau, 3000 * mag / self.opts.max_fade_speed);
                    if (mag > snap_b) {
                        e.off = .{};
                        self.stats.snaps += 1;
                    }
                }
            }
        }

        /// The state the renderer draws: the predicted state with every
        /// entity's Transform replaced by its display pose.
        pub fn renderState(self: *Self, now_ms: f64) []const u8 {
            @memcpy(self.render, self.sim.stateBytes());
            for (0..Sc.num_kinds) |k| {
                if (k == Sc.player_kind) continue;
                var i: u32 = 0;
                while (i < Sc.desc[k].capacity) : (i += 1) {
                    const p = self.displayPose(k, i, now_ms) orelse continue;
                    const old = Sc.transform(self.render, k, i).?;
                    Sc.setTransform(self.render, k, i, .{
                        .x = @intFromFloat(@round(p.x * 65536.0)),
                        .y = @intFromFloat(@round(p.y * 65536.0)),
                        .z = @intFromFloat(@round(p.z * 65536.0)),
                        .heading = @intFromFloat(@mod(@round(p.h), 65536.0)),
                        ._pad = old._pad,
                    });
                }
            }
            return self.render;
        }

        // ---------------------------------------------------------------
        // input datagram

        /// Encode the input datagram for this tick: every frame newer than
        /// the server's input_ack, up to 8.
        pub fn writeInput(self: *Self, out: []u8, now_ms: f64) ![]const u8 {
            const newest = self.sim.tick() -% 1;
            var frames: [wire.max_redundancy]input.Frame = undefined;
            var nf: usize = 0;
            var first = newest -% (wire.max_redundancy - 1);
            if (@as(i32, @bitCast(self.input_ack +% 1 -% first)) > 0) first = self.input_ack +% 1;
            var t = first;
            while (@as(i32, @bitCast(newest -% t)) >= 0) : (t +%= 1) {
                frames[nf] = self.frameFor(t) orelse input.Frame.neutral(input.seqOf(t));
                frames[nf].seq = input.seqOf(t);
                nf += 1;
            }
            if (nf == 0) {
                frames[0] = self.frameFor(newest) orelse input.Frame.neutral(input.seqOf(newest));
                nf = 1;
            }
            const af = self.dec.ackFields();
            var w: wire.Writer = .{ .buf = out };
            const p = [_]wire.InputPlayer{.{ .slot = self.own_slot, .newest_tick = newest, .frames = frames[0..nf] }};
            try wire.encodeInput(&w, .{
                .ack_seq = af.ack_seq,
                .ack_bits = af.ack_bits,
                .send_time = @truncate(@as(u64, @intFromFloat(@max(now_ms, 0)))),
                .players = 1,
            }, &p);
            return w.written();
        }
    };
}
