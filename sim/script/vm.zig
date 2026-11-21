//! The mission script VM (single player): threads, one command a tick,
//! EXEC and WHILE_EXEC blocks, the gosub stack, triggers, the
//! fail-on-death-or-arrest unwind. Owner: workstream A1
//! (mission-scripts.md, script-flow-control.md, script-counters.md,
//! script-messages.md, script-missions.md).
//!
//! The command families live in `cmd_flow.zig`, `cmd_counters.zig`,
//! `cmd_messages.zig` and `cmd_missions.zig`; anything they do not handle
//! goes to A2's `world.zig`.
//!
//! The level's script is static (`Level.script`, `Level.missions`); the
//! state holds which mission is loaded, the threads, the triggers and one
//! 32-bit slot per command number: a declared counter's value, or the
//! handle a declaration or creation command attached to its number
//! ("looked up by command number", script-declarations.md 2).

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const lv = @import("interfaces").level;
pub const world = @import("world.zig");
pub const Cmd = world.Cmd;
pub const Outcome = world.Outcome;

/// Command slots (mission-scripts.md 5).
pub const slots = 6000;
pub const level_end: u16 = 0xFFFF;
/// Ours: threads alive at once, gosub depth, triggers, the mission cleanup
/// list, and commands one thread may run in one tick inside a block before
/// the VM gives up on it for the tick (an endless EXEC loop).
pub const max_threads = 64;
pub const max_gosub = 8;
pub const max_triggers = 128;
pub const max_cleanup = 128;
pub const block_budget = 2000;
/// Timed bonus challenges at once (script-missions.md 5: 10).
pub const max_challenges = 10;
/// Basic keyframe slots (script-declarations.md 2.16: 25).
pub const max_keyframes = 25;

/// The command types the VM handles itself (numbers in formats/scr.zig).
pub const k = struct {
    pub const level_start = 59;
    pub const level_end_ = 60;
    pub const exec = 63;
    pub const endexec = 64;
    pub const label = 67;
    pub const ret = 68;
    pub const not_ = 71;
    pub const endwhile = 77;
    pub const gosub = 78;
    pub const if_ = 98;
    pub const wait = 61;
    pub const delay = 62;
    pub const start_thread = 207;
    pub const stop_thread = 208;
    pub const thread_decl = 210;
    pub const trigger_on = 215;
    pub const trigger_off = 216;
    pub const counter = 21;
    pub const counter_bare = 22;
    pub const save_counter = 23;
    pub const save_counter_bare = 24;
    /// A second plain counter declaration, used by the bil and ste scripts
    /// the way the others use 21.
    pub const counter_v = 276;
    pub const set = 340;
    pub const copy = 341;
    pub const inc = 96;
    pub const dec = 97;
    pub const message = 117;
    pub const brief = 118;
    pub const brief_now = 279;
    pub const brief_soon = 321;
    pub const clear_briefs = 317;
    pub const brief_showing = 325;
    pub const display_decl = 233;
    pub const counter_display_decl = 413;
    pub const timer = 119;
    pub const timer_add = 433;
    pub const timer_clear = 120;
    pub const clock_clear = 416;
    pub const show_counter = 414;
    pub const counter_clear = 415;
    pub const mission = 274;
    pub const gang_phone = 263;
    pub const gang_phone_open = 329;
    pub const mission_begin = 272;
    pub const mission_end = 273;
    pub const cleanup = 391;
    pub const challenge_dead = 401;
    pub const frenzy = 422;
};

pub const Thread = extern struct {
    /// Current command (0xFFFF: ended).
    cur: u16 = 0,
    /// Unique id (never 0) for stop-thread and the mission thread.
    id: u16 = 0,
    /// The declared entry point this thread was started under.
    entry: u16 = 0,
    /// The command a wait or delay is counting on (0: none).
    wait_at: u16 = 0,
    /// Flags, inherited by threads it starts; always 0 (script-flow-control
    /// 2.6).
    flags: u8 = 0,
    /// EXEC nesting (0 or 1, script-flow-control 2.5).
    exec: u8 = 0,
    stopped: u8 = 0,
    /// Gosub depth.
    sp: u8 = 0,
    live: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Pending condition result: nonzero is true. Kept as a number because
    /// two counter tests leave a sum or difference in it (script-counters 5).
    cond: i32 = 0,
    /// Wait or delay count.
    wait: i32 = 0,
    /// Ticks spent on the same command (for the level runner).
    same: u32 = 0,
    ret: [max_gosub]u16 = @splat(0),
    ret_cond: [max_gosub]i32 = @splat(0),
};

pub const Trigger = extern struct {
    /// `trig_*`.
    kind: u8 = 0,
    enabled: u8 = 0,
    /// The character was inside (area) or touching (phone) last time.
    inside: u8 = 0,
    _pad: u8 = 0,
    /// The declaring command (215/216 and 422 name it).
    decl: u16 = 0,
    /// Where the thread starts.
    entry: u16 = 0,
    character: EntityId = .none,
    target: EntityId = .none,
    /// Area centre and size (sim fixed point).
    x: Fx = 0,
    y: Fx = 0,
    z: Fx = 0,
    w: Fx = 0,
    h: Fx = 0,
    /// Last tick a phone was touched.
    touched: u32 = 0,
};
pub const trig_car: u8 = 1;
pub const trig_phone: u8 = 2;
pub const trig_block: u8 = 3;
pub const trig_area_on_foot: u8 = 4;
pub const trig_area_any: u8 = 5;

/// A timed bonus challenge (script-missions.md 2.3).
pub const Challenge = extern struct {
    /// The starting command (its slot holds the result), 0 = free.
    cmd: u16 = 0,
    /// What counts: `what_*`.
    what: u8 = 0,
    exclusive: u8 = 0,
    /// Car model, occupation or gang (0xFFFF any), and the alternate model.
    kind: u16 = 0,
    alt: u16 = 0,
    /// Required vehicle model the player drives (0xFFFF none).
    vehicle: u16 = 0,
    /// Required cause of death (0xFFFF any).
    cause: u16 = 0,
    /// Zone string key (0xFFFF none).
    zone: u16 = 0,
    _pad: u16 = 0,
    target: i32 = 0,
    progress: i32 = 0,
    /// Ticks left (-1: no limit).
    ticks: i32 = 0,
    reward: i32 = 0,
};
pub const what_car_model: u8 = 0;
pub const what_occupation: u8 = 1;
pub const what_gang_car: u8 = 2;
pub const what_gang_member: u8 = 3;

/// A challenge's result, kept in its command's slot (script-missions 2.3:
/// remembered after the challenge's own slot is freed).
pub const result_running: i32 = 1;
pub const result_passed: i32 = 2;
pub const result_failed: i32 = 3;

/// In the SP state block (`state.sp.script`).
pub const State = extern struct {
    /// Live threads (`thread[0..threads]`, in creation order).
    threads: u16 = 0,
    /// The loaded mission sub-script: index into `Level.missions` + 1.
    mission: u16 = 0,
    flags: u32 = 0,
    next_id: u16 = 0,
    /// The thread running a mission (its id), 0 = none.
    mission_thread: u16 = 0,
    triggers: u16 = 0,
    cleanup_len: u16 = 0,
    /// Mission-in-progress flags: general, gangs 1-3 (declared counters,
    /// script-declarations 2.16).
    mission_flag: [4]u16 = @splat(0),
    /// Fail message bases for gangs 1-3 (script-declarations 2.16).
    fail_base: [3]u16 = @splat(0),
    /// The car model a "car model destroyed" test watches for this tick
    /// (0xFFFF none), cleared after the threads run (mission-scripts.md 4).
    destroyed_model: u16 = 0xFFFF,
    /// Gang string keys by gang index (A2's gang info declarations).
    gang_key: [ids.max_gangs]u16 = @splat(0),
    /// 0 or 1 (bools; A2 reads the first two through `*bool`).
    death_arrest: u8 = 0,
    notify_death_arrest: u8 = 0,
    frenzy_running: u8 = 0,
    _pad0: u8 = 0,
    /// Basic keyframe ids (422 declarations) and which have started.
    keyframe: [max_keyframes]u16 = @splat(0),
    keyframe_len: u16 = 0,
    keyframe_started: u32 = 0,
    /// Commands run this tick, unhandled commands met (diagnostics, saved
    /// so that replays compare equal).
    unhandled: u32 = 0,
    thread: [max_threads]Thread = @splat(.{}),
    trigger: [max_triggers]Trigger = @splat(.{}),
    cleanup: [max_cleanup]EntityId = @splat(.none),
    challenge: [max_challenges]Challenge = @splat(.{}),
    slot: [slots]i32 = @splat(0),

    pub const flag_started: u32 = 1;
};

comptime {
    for (.{ Thread, Trigger, Challenge, State }) |T| {
        var sum: usize = 0;
        for (@typeInfo(T).@"struct".field_types) |FT| sum += @sizeOf(FT);
        if (sum != @sizeOf(T)) @compileError("implicit padding in " ++ @typeName(T));
    }
}

/// What a command did to its thread.
pub const Step = enum { advance, jumped, hold, ended };

/// Little-endian parameter words.
pub const P = struct {
    b: []const u8,
    pub fn u(p: P, i: usize) u16 {
        const o = i * 2;
        if (o + 2 > p.b.len) return 0;
        return std.mem.readInt(u16, p.b[o..][0..2], .little);
    }
    pub fn s(p: P, i: usize) i16 {
        return @bitCast(p.u(i));
    }
    /// The 32-bit value in words i and i + 1.
    pub fn l(p: P, i: usize) i32 {
        return @bitCast(@as(u32, p.u(i)) | (@as(u32, p.u(i + 1)) << 16));
    }
    pub fn lo(p: P, i: usize) u8 {
        return @truncate(p.u(i));
    }
    pub fn hi(p: P, i: usize) u8 {
        return @truncate(p.u(i) >> 8);
    }
};

/// Script positions have 14 fraction bits, the sim's 16.
pub fn fromScript(v: i32) Fx {
    return v *% 4;
}

/// Salts (ids.salts.script, A1 takes 0x1000-0x103F).
pub const salt_fail_message: u32 = 0x1000;

pub fn Sys(comptime Self: type) type {
    return struct {
        const Vm = @This();
        const flow = @import("cmd_flow.zig").Sys(Self);
        const counters = @import("cmd_counters.zig").Sys(Self);
        const messages = @import("cmd_messages.zig").Sys(Self);
        const missions = @import("cmd_missions.zig").Sys(Self);

        pub fn st(self: *Self) *State {
            return &self.state.sp.script;
        }

        // ------------------------------------------------------------------
        // Commands and slots

        pub const Found = struct { num: u16, kind: u16, next: u16, ret: i16, params: []const u8 };

        fn findIn(s: *const lv.Script, num: u16) ?Found {
            if (num < s.first) return null;
            const i = num - s.first;
            if (i >= s.pointers.len) return null;
            const p = s.pointers[i];
            if (p == 0 and !(s.first == 0 and i == 0)) return null;
            if (p < s.base) return null;
            const off: usize = p - s.base;
            if (off + 8 > s.code.len) return null;
            const cd = s.code;
            const w = P{ .b = cd[off..] };
            return .{ .num = w.u(0), .kind = w.u(1), .next = w.u(2), .ret = w.s(3), .params = cd[off + 8 .. @min(cd.len, off + 8 + 64)] };
        }

        /// The loaded mission, if any.
        pub fn loadedMission(self: *Self) ?*const lv.Script {
            const l = self.level orelse return null;
            const m = st(self).mission;
            if (m == 0 or m > l.missions.len) return null;
            return &l.missions[m - 1];
        }

        /// Command `num`: the loaded mission's when it has one there, else
        /// the main script's.
        pub fn lookup(self: *Self, num: u16) ?Found {
            if (num == 0 or num >= slots) return null;
            if (loadedMission(self)) |m| if (findIn(m, num)) |f| return f;
            const l = self.level orelse return null;
            return findIn(&l.script, num);
        }

        pub fn slotPtr(self: *Self, num: u16) ?*i32 {
            if (num >= slots) return null;
            return &st(self).slot[num];
        }

        /// The handle attached to command `num` (stored as raw + 1 so an
        /// empty slot is none).
        pub fn handle(self: *Self, num: u16) EntityId {
            const p = slotPtr(self, num) orelse return .none;
            if (p.* == 0) return .none;
            return .{ .raw = @as(u32, @bitCast(p.*)) -% 1 };
        }

        pub fn setHandle(self: *Self, num: u16, id: EntityId) void {
            const p = slotPtr(self, num) orelse return;
            p.* = if (id.isNone()) 0 else @bitCast(id.raw +% 1);
        }

        pub fn string(self: *Self, key: u16) []const u8 {
            const l = self.level orelse return "";
            var it = StringIter{ .b = l.script.strings };
            while (it.next()) |e| if (e.key == key) return e.text;
            return "";
        }

        pub const StringIter = struct {
            b: []const u8,
            p: usize = 0,
            pub const Entry = struct { key: u32, kind: u32, text: []const u8 };
            pub fn next(it: *StringIter) ?Entry {
                if (it.p + 9 > it.b.len) return null;
                const w = P{ .b = it.b[it.p..] };
                const key: u32 = @bitCast(w.l(0));
                const kind: u32 = @bitCast(w.l(2));
                const n = it.b[it.p + 8];
                const from = it.p + 9;
                const end = @min(it.b.len, from + n);
                it.p = from + n;
                const raw = it.b[from..end];
                const z = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
                return .{ .key = key, .kind = kind, .text = raw[0..z] };
            }
        };

        // ------------------------------------------------------------------
        // Threads

        pub fn threadById(self: *Self, id: u16) ?*Thread {
            if (id == 0) return null;
            const s = st(self);
            for (s.thread[0..s.threads]) |*t| if (t.live != 0 and t.id == id) return t;
            return null;
        }

        /// Start a thread at `start` under entry point `entry` (its handle is
        /// written to the entry's slot). Null when the table is full.
        pub fn spawnThread(self: *Self, at: u16, entry: u16, flags: u8) ?*Thread {
            const s = st(self);
            if (s.threads >= max_threads) return null;
            s.next_id +%= 1;
            if (s.next_id == 0) s.next_id = 1;
            const t = &s.thread[s.threads];
            t.* = .{ .cur = at, .id = s.next_id, .entry = entry, .flags = flags, .live = 1 };
            s.threads += 1;
            if (entry != 0) if (slotPtr(self, entry)) |p| {
                p.* = t.id;
            };
            return t;
        }

        pub fn endThread(self: *Self, t: *Thread) void {
            if (st(self).mission_thread == t.id) st(self).mission_thread = 0;
            t.live = 0;
            t.cur = level_end;
        }

        /// Push a gosub frame and jump.
        pub fn gosub(self: *Self, t: *Thread, target: u16, back: u16) Step {
            _ = self;
            if (t.sp >= max_gosub) return .advance; // ours: too deep, ignored
            t.ret[t.sp] = back;
            t.ret_cond[t.sp] = t.cond;
            t.sp += 1;
            t.cur = target;
            return .jumped;
        }

        /// RETURN (and mission end, 273): pop a frame, or end the thread.
        pub fn doReturn(self: *Self, t: *Thread) Step {
            if (t.sp == 0) {
                endThread(self, t);
                return .ended;
            }
            t.sp -= 1;
            t.cur = t.ret[t.sp];
            t.cond = t.ret_cond[t.sp];
            t.ret[t.sp] = 0;
            t.ret_cond[t.sp] = 0;
            return .jumped;
        }

        // ------------------------------------------------------------------
        // The context handed to command families (and A2's world.zig)

        pub const Ctx = struct {
            self: *Self,
            t: ?*Thread,
            num: u16,

            pub fn declaring(x: Ctx) bool {
                return x.t == null;
            }
            pub fn handle(x: Ctx, num: u16) EntityId {
                return Vm.handle(x.self, num);
            }
            pub fn setHandle(x: Ctx, num: u16, id: EntityId) void {
                Vm.setHandle(x.self, num, id);
            }
            pub fn cond(x: Ctx) bool {
                return if (x.t) |t| t.cond != 0 else false;
            }
            pub fn setCond(x: Ctx, b: bool) void {
                if (x.t) |t| t.cond = @intFromBool(b);
            }
            pub fn counter(x: Ctx, num: u16) ?*i32 {
                return slotPtr(x.self, num);
            }
            pub fn addCleanup(x: Ctx, id: EntityId) void {
                Vm.addCleanup(x.self, id);
            }
            pub fn string(x: Ctx, key: u16) []const u8 {
                return Vm.string(x.self, key);
            }
            pub fn deathArrestFlag(x: Ctx) *bool {
                return @ptrCast(&st(x.self).death_arrest);
            }
            pub fn notifyDeathArrest(x: Ctx) *bool {
                return @ptrCast(&st(x.self).notify_death_arrest);
            }
            pub fn setMissionFlag(x: Ctx, which: u2, counter_num: u16) void {
                st(x.self).mission_flag[which] = counter_num;
            }
            pub fn setFailBase(x: Ctx, gang: u2, base: u16) void {
                if (gang < 3) st(x.self).fail_base[gang] = base;
            }
            pub fn registerGang(x: Ctx, index: u8, key: u16) void {
                if (index < ids.max_gangs) st(x.self).gang_key[index] = key;
            }
            pub fn player(x: Ctx, slot: u8) EntityId {
                return x.self.pedOf(slot) orelse .none;
            }
            /// A2's trigger declarations (211-214, 434).
            pub fn addTrigger(x: Ctx, t: anytype) void {
                const kind: u8 = switch (@backingInt(t.kind)) {
                    0 => trig_car,
                    1 => trig_phone,
                    2 => trig_block,
                    3 => trig_area_on_foot,
                    else => trig_area_any,
                };
                _ = Vm.addTrigger(x.self, .{
                    .kind = kind,
                    .enabled = 1,
                    .decl = x.num,
                    .entry = t.thread,
                    .character = t.character,
                    .target = t.target,
                    .x = t.x,
                    .y = t.y,
                    .z = t.z,
                    .w = t.w,
                    .h = t.h,
                });
            }
        };

        pub fn addCleanup(self: *Self, id: EntityId) void {
            const s = st(self);
            if (id.isNone()) return;
            for (s.cleanup[0..s.cleanup_len]) |e| if (e.raw == id.raw) return;
            if (s.cleanup_len >= max_cleanup) return;
            s.cleanup[s.cleanup_len] = id;
            s.cleanup_len += 1;
            if (self.state.world.get(id, c.ScriptTag)) |tag| tag.flags |= c.ScriptTag.flag_mission;
        }

        pub fn addTrigger(self: *Self, t: Trigger) bool {
            const s = st(self);
            if (s.triggers >= max_triggers) return false;
            s.trigger[s.triggers] = t;
            s.triggers += 1;
            return true;
        }

        pub fn triggerByDecl(self: *Self, decl: u16) ?*Trigger {
            const s = st(self);
            for (s.trigger[0..s.triggers]) |*t| if (t.decl == decl) return t;
            return null;
        }

        fn fire(self: *Self, t: *Trigger) void {
            _ = spawnThread(self, t.entry, t.entry, 0);
        }

        // ------------------------------------------------------------------
        // Weapon hits (mission-scripts.md 3.4), for A2's hit tests

        pub fn hitBy(self: *Self, id: EntityId, weapon: u8) bool {
            const tag = self.state.world.get(id, c.ScriptTag) orelse return false;
            return tag.hits & (@as(u32, 1) << @intCast(weapon & 31)) != 0;
        }

        pub fn clearHit(self: *Self, id: EntityId, weapon: u8) void {
            const tag = self.state.world.get(id, c.ScriptTag) orelse return;
            tag.hits &= ~(@as(u32, 1) << @intCast(weapon & 31));
        }

        // ------------------------------------------------------------------
        // Level start (mission-scripts.md 3.1)

        fn hasScript(self: *Self) bool {
            const l = self.level orelse return false;
            return l.script.pointers.len > 0;
        }

        /// Declaration pass over commands 1-5999, then the level-start
        /// thread. Runs once, on the first tick with a level attached.
        pub fn startLevel(self: *Self) void {
            const s = st(self);
            s.flags |= State.flag_started;
            const l = self.level.?;
            var num: u16 = 1;
            while (num < slots) : (num += 1) {
                const f = findIn(&l.script, num) orelse continue;
                declare(self, f);
            }
            num = 1;
            while (num < slots) : (num += 1) {
                const f = findIn(&l.script, num) orelse continue;
                if (f.kind == k.level_start) {
                    _ = spawnThread(self, num, 0, 0);
                    return;
                }
            }
            // No level start: a fatal error in the original; the script
            // simply does not run here.
        }

        fn declare(self: *Self, f: Found) void {
            const p = P{ .b = f.params };
            switch (f.kind) {
                k.counter, k.save_counter, k.counter_v => st(self).slot[f.num] = p.s(0),
                k.counter_bare, k.save_counter_bare => st(self).slot[f.num] = 0,
                k.frenzy => missions.declareKeyframe(self, f),
                k.display_decl, k.counter_display_decl, k.thread_decl, k.label => {},
                else => {
                    const ctx: Ctx = .{ .self = self, .t = null, .num = f.num };
                    const r = world.exec(Self, self, ctx, .{ .num = f.num, .kind = f.kind, .ret = f.ret, .params = f.params });
                    if (r == .unhandled) st(self).unhandled +%= 1;
                },
            }
        }

        /// Load mission `index` (into `Level.missions`): its command slots
        /// go back to their compiled values, as copying the sub-script into
        /// the command area does in the original (counters live in their
        /// declaring commands, script-counters.md 2.1).
        pub fn loadMission(self: *Self, index: usize) void {
            const l = self.level orelse return;
            if (index >= l.missions.len) return;
            const s = st(self);
            s.mission = @intCast(index + 1);
            const m = &l.missions[index];
            for (m.pointers, 0..) |_, i| {
                const num: usize = m.first + i;
                if (num >= slots) break;
                s.slot[num] = 0;
                const f = findIn(m, @intCast(num)) orelse continue;
                const p = P{ .b = f.params };
                if (f.kind == k.counter or f.kind == k.save_counter or f.kind == k.counter_v) s.slot[num] = p.s(0);
            }
        }

        /// The mission sub-script a string key names ("wil_le1.mis").
        pub fn missionByKey(self: *Self, key: u16) ?usize {
            const l = self.level orelse return null;
            const name = stem(string(self, key));
            if (name.len == 0) return null;
            for (l.missions, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m.name, name)) return i;
            return null;
        }

        pub fn stem(name: []const u8) []const u8 {
            const base = if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| name[i + 1 ..] else name;
            return if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[0..i] else base;
        }

        // ------------------------------------------------------------------
        // The tick

        /// Run every script thread one step (mission-scripts.md 3.2-3.4, 4).
        pub fn sysScript(self: *Self) void {
            if (comptime !Self.single_player) return;
            if (self.predicting()) return;
            const s = st(self);
            if (s.flags & State.flag_started == 0) {
                if (!hasScript(self)) return;
                startLevel(self);
            }
            pollTriggers(self);
            missions.tickChallenges(self);
            var i: usize = 0;
            while (i < s.threads) : (i += 1) {
                const t = &s.thread[i];
                if (t.live == 0 or t.stopped != 0) continue;
                const before = t.cur;
                failCheck(self, t);
                runThread(self, t);
                t.same = if (t.cur == before) t.same +| 1 else 0;
            }
            // Drop ended threads, keeping creation order.
            var w: usize = 0;
            for (0..s.threads) |r| {
                if (s.thread[r].live == 0) continue;
                if (w != r) s.thread[w] = s.thread[r];
                w += 1;
            }
            for (w..s.threads) |r| s.thread[r] = .{};
            s.threads = @intCast(w);
            s.destroyed_model = 0xFFFF;
            Self.hud.tickHud(self);
        }

        fn runThread(self: *Self, t: *Thread) void {
            const first = lookup(self, t.cur) orelse {
                endThread(self, t);
                return;
            };
            const while_block = first.ret == 1 and first.kind != k.exec;
            var budget: u32 = block_budget;
            while (true) {
                const cur = lookup(self, t.cur) orelse {
                    endThread(self, t);
                    return;
                };
                const step = execOne(self, t, cur);
                if (step == .hold or step == .ended or t.live == 0) return;
                if (t.cur == level_end) {
                    endThread(self, t);
                    return;
                }
                budget -= 1;
                if (budget == 0) return;
                if (t.exec > 0) continue;
                if (!while_block) return;
                // An end-exec line closes this tick's WHILE_EXEC run: the
                // player's scripts end every path through a WHILE_EXEC body
                // with one (script-flow-control 2.5), flagged or not.
                if (cur.kind == k.endexec) return;
                const nx = lookup(self, t.cur) orelse return;
                if (nx.kind == k.exec) continue;
                if (nx.ret != 1) return;
            }
        }

        /// Execute one command and move the thread on.
        pub fn execOne(self: *Self, t: *Thread, f: Found) Step {
            const cmd: Cmd = .{ .num = f.num, .kind = f.kind, .ret = f.ret, .params = f.params };
            const step: Step = flow.exec(self, t, cmd) orelse
                counters.exec(self, t, cmd) orelse
                messages.exec(self, t, cmd) orelse
                missions.exec(self, t, cmd) orelse blk: {
                const ctx: Ctx = .{ .self = self, .t = t, .num = f.num };
                const r = world.exec(Self, self, ctx, cmd);
                if (r == .unhandled) st(self).unhandled +%= 1;
                break :blk if (r == .hold) .hold else .advance;
            };
            if (step == .advance) t.cur = f.next;
            return step;
        }

        // ------------------------------------------------------------------
        // Mission fail on death or arrest (mission-scripts.md 3.3)

        fn missionFlagSet(self: *Self) bool {
            const s = st(self);
            for (s.mission_flag) |n| if (n != 0 and s.slot[n] != 0) return true;
            return false;
        }

        fn failCheck(self: *Self, t: *Thread) void {
            const s = st(self);
            if (s.notify_death_arrest == 0) return;
            if (s.mission_thread != t.id) return;
            if (!missionFlagSet(self)) return;
            if (!Self.career.isOut(self, 0)) return;
            missionFail(self, t);
        }

        /// The fail unwind itself (also called by tests).
        pub fn missionFail(self: *Self, t: *Thread) void {
            const s = st(self);
            // Ours (the notes say "unwound by two levels and returns from
            // the mission routine"): with the player's scripts' nesting
            // (trigger thread -> mission launch -> mission body) this lands
            // on the line after the launch command.
            if (t.sp < 2) return;
            t.sp -= 2;
            t.cur = t.ret[t.sp];
            t.cond = t.ret_cond[t.sp];
            t.ret[t.sp] = 0;
            t.ret[t.sp + 1] = 0;
            t.exec = 0;
            t.wait_at = 0;
            failMessages(self);
            s.death_arrest = 1;
            // Ours: the fail fires once. The mission's own clearing lines are
            // skipped by the unwind, so the in-progress flags are cleared here.
            s.notify_death_arrest = 0;
            for (s.mission_flag) |n| if (n != 0) {
                s.slot[n] = 0;
            };
            s.mission_thread = 0;
            self.pushEvent(.{ .kind = .mission_fail, .a = 0 });
        }

        fn failMessages(self: *Self) void {
            const s = st(self);
            const hud = Self.hud;
            hud.clearBriefs(self, 0);
            // A busted player's ped is alive; a wasted one's is not (ours).
            const busted = if (self.pedOf(0)) |ped| (if (self.state.world.get(ped, c.Health)) |hp| hp.hp > 0 else false) else false;
            var text: u32 = @import("../sp/hud.zig").named_fail_brief;
            for (0..3) |g| {
                const n = s.mission_flag[g + 1];
                if (n != 0 and s.slot[n] != 0 and s.fail_base[g] != 0) {
                    text = @as(u32, s.fail_base[g]) + self.randBelow(.none, salt_fail_message, 5) + (if (busted) @as(u32, 5) else 0);
                    break;
                }
            }
            hud.queueBriefPrio(self, 0, text, @import("../sp/hud.zig").brief_normal, 0);
            hud.postBannerPrio(self, 0, @import("../sp/hud.zig").named_mission_failed, @import("../sp/hud.zig").banner_ticks, @import("../sp/hud.zig").banner_important, 0);
        }

        // ------------------------------------------------------------------
        // Triggers (mission-scripts.md 3.4)

        fn pollTriggers(self: *Self) void {
            const s = st(self);
            const w = &self.state.world;
            for (s.trigger[0..s.triggers]) |*t| {
                switch (t.kind) {
                    trig_block, trig_area_on_foot, trig_area_any => {},
                    trig_phone => {
                        if (t.inside != 0 and self.state.tick > t.touched + 1) t.inside = 0;
                        continue;
                    },
                    else => continue,
                }
                if (!w.isAlive(t.character)) continue;
                var pos = w.get(t.character, c.Transform) orelse continue;
                const riding = if (w.get(t.character, c.Riding)) |r| r.vehicle else EntityId.none;
                const in_car = !riding.isNone();
                if (in_car) {
                    if (t.kind != trig_area_any) {
                        t.inside = 0;
                        continue;
                    }
                    if (w.get(riding, c.Transform)) |ct| pos = ct;
                }
                const in = if (t.kind == trig_block)
                    fx.toInt(pos.x) == fx.toInt(t.x) and fx.toInt(pos.y) == fx.toInt(t.y)
                else
                    @abs(pos.x - t.x) * 2 <= t.w and @abs(pos.y - t.y) * 2 <= t.h;
                if (in and t.inside == 0 and t.enabled != 0) fire(self, t);
                t.inside = @intFromBool(in);
            }
        }

        /// From the objects system (B): a ped touched or answered a phone.
        pub fn onPhone(self: *Self, phone: EntityId, ped: EntityId) void {
            const s = st(self);
            for (s.trigger[0..s.triggers]) |*t| {
                if (t.kind != trig_phone or t.target.raw != phone.raw or t.character.raw != ped.raw) continue;
                const was = t.inside != 0;
                t.inside = 1;
                t.touched = self.state.tick;
                if (!was and t.enabled != 0) fire(self, t);
            }
        }

        /// From entering cars (D2): a ped got into a car.
        pub fn onCarEntered(self: *Self, car: EntityId, ped: EntityId) void {
            const s = st(self);
            for (s.trigger[0..s.triggers]) |*t| {
                if (t.kind != trig_car or t.target.raw != car.raw or t.character.raw != ped.raw) continue;
                if (t.enabled != 0) fire(self, t);
            }
        }

        pub fn onEntityHit(self: *Self, id: EntityId, weapon: u8) void {
            const tag = self.state.world.get(id, c.ScriptTag) orelse return;
            tag.hits |= @as(u32, 1) << @intCast(weapon & 31);
        }

        pub fn onCarModelDestroyed(self: *Self, model: u8, by: EntityId) void {
            st(self).destroyed_model = model;
            missions.onCarDestroyed(self, model, by);
        }

        pub fn onPedKilled(self: *Self, ped: EntityId, by: EntityId, cause: u8) void {
            missions.onPedKilled(self, ped, by, cause);
        }
    };
}
