//! Mission commands (script-missions.md): launching a mission (274), the
//! gang-phone gate (263, and 329 read the same way), mission end (273 is
//! RETURN, in cmd_flow) and cleanup (391), timed bonus challenges
//! (288-294, 402) and the kill frenzy (422, 423). Owner: workstream A1.
//!
//! Parameter layouts are read from the player's own level scripts; fields
//! the notes name but whose numbering is not settled are listed as "ours"
//! in docs/coverage/script-missions.md.

const std = @import("std");
const vm = @import("vm.zig");
const hudm = @import("../sp/hud.zig");
const prelude = @import("../prelude.zig");
const c = prelude.c;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const Thread = vm.Thread;
const Step = vm.Step;
const Cmd = vm.Cmd;
const P = vm.P;
const k = vm.k;

/// Respect per gate step (gangs-and-respect.md 3.2: +-20 a step).
pub const respect_per_step = 20;

/// Gang-phone gate brief offsets from its base message (script-missions
/// 2.1, 5: seven canned lines). In the player's text these sit just below
/// each gate's base, with the "already passed" and "already failed" lines
/// at base and base + 1. Which line goes with which reason is read from
/// the text (ours where it says so).
pub const gate_passed: i32 = 0;
pub const gate_failed: i32 = 1;
pub const gate_low_respect: i32 = -7;
pub const gate_zero_respect: i32 = -6;
pub const gate_on_own_job: i32 = -5;
pub const gate_negative_respect: i32 = -4;
/// Ours: the other two gangs' "you're on their job" lines.
pub const gate_on_other_job = [2]i32{ -3, -2 };

pub fn Sys(comptime Self: type) type {
    return struct {
        const V = Self.script;
        const H = Self.hud;

        fn nextOf(self: *Self, cmd: Cmd) u16 {
            const f = V.lookup(self, cmd.num) orelse return vm.level_end;
            return f.next;
        }

        fn val(self: *Self, num: u16) i32 {
            if (num == 0) return 0;
            return if (V.slotPtr(self, num)) |q| q.* else 0;
        }

        /// Load the mission a string key names and GOSUB into it.
        fn launch(self: *Self, t: *Thread, key: u16, back: u16) Step {
            return launchGated(self, t, key, back, 0, 0);
        }

        fn launchGated(self: *Self, t: *Thread, key: u16, back: u16, passed: u16, failed: u16) Step {
            const idx = V.missionByKey(self, key) orelse {
                V.st(self).unhandled +%= 1;
                return .advance;
            };
            V.loadMission(self, idx);
            const m = &self.level.?.missions[idx];
            const s = V.st(self);
            s.mission_thread = t.id;
            s.mission_passed = passed;
            s.mission_failed = failed;
            self.pushEvent(.{ .kind = .mission_start, .a = 0, .x = @intCast(idx) });
            const step = V.gosub(self, t, m.start, back);
            s.mission_sp = t.sp;
            return step;
        }

        /// The gang a string key names: the index A2's gang declarations
        /// registered, else its rank among the gang names in the string
        /// table (ours).
        pub fn gangOfKey(self: *Self, key: u16) ?u8 {
            const s = V.st(self);
            for (s.gang_key, 0..) |g, i| if (g == key and key != 0) return @intCast(i);
            const l = self.level orelse return null;
            var it = V.StringIter{ .b = l.script.strings };
            var rank: u8 = 0;
            var found = false;
            while (it.next()) |e| {
                if (e.kind != 17) continue;
                if (e.key == key) found = true else if (e.key < key) rank += 1;
            }
            return if (found) rank else null;
        }

        fn gateBrief(self: *Self, base: u16, off: i32) void {
            const id = @as(i32, base) + off;
            if (id <= 0) return;
            H.queueBriefPrio(self, 0, @intCast(id), hudm.brief_normal, 0);
        }

        fn gate(self: *Self, t: *Thread, cmd: Cmd) Step {
            const p = P{ .b = cmd.params };
            const base = p.u(0);
            const passed = p.u(1);
            const failed = p.u(2);
            const mission2 = p.u(3);
            const mission1 = p.u(10);
            const back = nextOf(self, cmd);
            // Ours: a mission sub-script already running counts as being on
            // a job, so a second phone answered before the first mission
            // has set its own flags cannot load over it.
            if (V.st(self).mission_thread != 0) {
                gateBrief(self, base, gate_on_own_job);
                return .advance;
            }
            // On a job for this gang or another (the general flag, word 4,
            // has no line of its own: script-missions 6).
            if (val(self, p.u(5)) != 0) {
                gateBrief(self, base, gate_on_own_job);
                return .advance;
            }
            for (0..2) |j| if (val(self, p.u(6 + j)) != 0) {
                gateBrief(self, base, gate_on_other_job[j]);
                return .advance;
            };
            const gang = gangOfKey(self, p.u(8));
            const respect: i32 = if (gang) |g| Self.gangs.respect(self, g) else 0;
            const steps = @divTrunc(respect, respect_per_step);
            const enough = steps >= p.s(9);
            if (passed != 0 and val(self, passed) != 0) {
                if (enough) return launchGated(self, t, mission2, back, passed, failed);
                gateBrief(self, base, gate_passed);
                return .advance;
            }
            if (failed != 0 and val(self, failed) != 0) {
                if (enough) return launchGated(self, t, mission2, back, passed, failed);
                gateBrief(self, base, gate_failed);
                return .advance;
            }
            if (enough) {
                V.st(self).death_arrest = 0;
                return launchGated(self, t, mission1, back, passed, failed);
            }
            gateBrief(self, base, if (steps == 0) gate_zero_respect else if (steps < 0) gate_negative_respect else gate_low_respect);
            return .advance;
        }

        /// 391 (script-missions 2.2): remove everything on the cleanup list.
        pub fn cleanup(self: *Self) void {
            const s = V.st(self);
            const w = &self.state.world;
            for (s.cleanup[0..s.cleanup_len]) |*id| {
                if (w.isAlive(id.*)) {
                    if (id.kind() == @backingInt(prelude.abi.Kind.map_object)) Self.objects.removeObject(self, id.*) else self.kill(id.*);
                }
                id.* = .none;
            }
            s.cleanup_len = 0;
        }

        pub fn exec(self: *Self, t: *Thread, cmd: Cmd) ?Step {
            const p = P{ .b = cmd.params };
            switch (cmd.kind) {
                k.mission => return launch(self, t, p.u(0), nextOf(self, cmd)),
                k.gang_phone, k.gang_phone_open => return gate(self, t, cmd),
                k.cleanup => {
                    cleanup(self);
                    return .advance;
                },
                288...291 => {
                    startChallenge(self, p);
                    return .advance;
                },
                292, 293, 294 => {
                    const r = val(self, p.u(0));
                    t.cond = @intFromBool(switch (cmd.kind) {
                        292 => r == vm.result_passed,
                        293 => r == vm.result_failed,
                        else => r == vm.result_passed or r == vm.result_failed,
                    });
                    return .advance;
                },
                402 => {
                    if (challengeOf(self, p.u(0))) |ch| {
                        if (V.slotPtr(self, p.u(1))) |q| q.* = ch.progress;
                    }
                    return .advance;
                },
                k.frenzy => return frenzy(self, t, cmd),
                423 => return frenzyRun(self, t, cmd),
                else => return null,
            }
        }

        // ------------------------------------------------------------------
        // Timed bonus challenges (2.3)

        fn challengeOf(self: *Self, handle_cmd: u16) ?*vm.Challenge {
            for (&V.st(self).challenge) |*ch| if (ch.cmd == handle_cmd and handle_cmd != 0) return ch;
            return null;
        }

        /// 288-291: (zone key or 0xFFFF, B:what:?, target, kind, ticks,
        /// vehicle, L:reward, handle, cause). `what` 1 counts ped kills,
        /// 0 cars destroyed (as the player's files use it).
        fn startChallenge(self: *Self, p: P) void {
            const s = V.st(self);
            const handle_cmd = p.u(8);
            const free = for (&s.challenge) |*ch| {
                if (ch.cmd == 0) break ch;
            } else return;
            free.* = .{
                .cmd = handle_cmd,
                .what = if (p.lo(1) != 0) vm.what_occupation else vm.what_car_model,
                .kind = p.u(3),
                .alt = p.hi(1),
                .vehicle = p.u(5),
                .cause = p.u(9),
                .zone = p.u(0),
                .target = p.s(2),
                .ticks = if (p.s(4) > 0) p.s(4) else -1,
                .reward = p.l(6),
            };
            if (V.slotPtr(self, handle_cmd)) |q| q.* = vm.result_running;
        }

        fn resolve(self: *Self, ch: *vm.Challenge, passed: bool) void {
            if (V.slotPtr(self, ch.cmd)) |q| q.* = if (passed) vm.result_passed else vm.result_failed;
            if (passed and ch.reward != 0) Self.career.addScore(self, 0, ch.reward, .with_multiplier);
            ch.* = .{};
        }

        pub fn tickChallenges(self: *Self) void {
            for (&V.st(self).challenge) |*ch| {
                if (ch.cmd == 0 or ch.ticks < 0) continue;
                ch.ticks -= 1;
                if (ch.ticks <= 0) resolve(self, ch, false);
            }
        }

        fn byPlayer(self: *Self, by: EntityId) bool {
            if (by.isNone()) return false;
            const ped = self.pedOf(0) orelse return false;
            if (by.raw == ped.raw) return true;
            const r = self.state.world.get(ped, c.Riding) orelse return false;
            return !r.vehicle.isNone() and r.vehicle.raw == by.raw;
        }

        fn inZone(self: *Self, ch: *const vm.Challenge, id: EntityId) bool {
            if (ch.zone == 0xFFFF or ch.zone == 0) return true;
            const name = V.string(self, ch.zone);
            const l = self.level orelse return true;
            const tr = self.state.world.get(id, c.Transform) orelse return false;
            const bx = prelude.fx.toInt(tr.x);
            const by_ = prelude.fx.toInt(tr.y);
            for (l.zones) |z| if (std.ascii.eqlIgnoreCase(z.name, name) and z.contains(bx, by_)) return true;
            return false;
        }

        fn credit(self: *Self, ch: *vm.Challenge) void {
            ch.progress += 1;
            if (ch.progress >= ch.target) resolve(self, ch, true);
        }

        /// A ped was killed (hooks.pedKilled). Ours: any ped killed by the
        /// player counts toward a ped challenge in its zone; the kind,
        /// vehicle and cause filters wait on settled numbering.
        pub fn onPedKilled(self: *Self, ped: EntityId, by: EntityId, cause: u8) void {
            _ = cause;
            if (!byPlayer(self, by)) return;
            for (&V.st(self).challenge) |*ch| {
                if (ch.cmd == 0 or ch.what != vm.what_occupation) continue;
                if (!inZone(self, ch, ped)) continue;
                credit(self, ch);
            }
        }

        /// A car was destroyed (hooks.carModelDestroyed).
        pub fn onCarDestroyed(self: *Self, model: u8, by: EntityId) void {
            if (!byPlayer(self, by)) return;
            for (&V.st(self).challenge) |*ch| {
                if (ch.cmd == 0 or ch.what != vm.what_car_model) continue;
                if (ch.kind != 0xFFFF and ch.kind != model and ch.alt != model) continue;
                credit(self, ch);
            }
        }

        // ------------------------------------------------------------------
        // Kill frenzy (2.4)

        pub fn declareKeyframe(self: *Self, f: V.Found) void {
            const s = V.st(self);
            if (s.keyframe_len >= vm.max_keyframes) return;
            s.keyframe[s.keyframe_len] = f.num;
            s.keyframe_len += 1;
        }

        /// 422: (trigger, brief, object, player, weapon).
        fn frenzy(self: *Self, t: *Thread, cmd: Cmd) Step {
            const p = P{ .b = cmd.params };
            const s = V.st(self);
            const trig = V.triggerByDecl(self, p.u(0));
            if (s.frenzy_running != 0) {
                if (trig) |tr| tr.enabled = 1;
                V.endThread(self, t);
                return .ended;
            }
            s.frenzy_running = 1;
            if (trig) |tr| tr.enabled = 0;
            H.postBannerPrio(self, 0, hudm.named_kill_frenzy, hudm.banner_ticks, hudm.banner_important, 0);
            const obj = V.handle(self, p.u(2));
            if (!obj.isNone() and obj.kind() == @backingInt(prelude.abi.Kind.map_object)) Self.objects.removeObject(self, obj);
            H.queueBriefPrio(self, 0, p.u(1), hudm.brief_normal, 0);
            // The weapon itself is A2's grant (types 411/412) once G's
            // weapons land: stubbed here.
            for (s.keyframe[0..s.keyframe_len], 0..) |kf, i| if (kf == cmd.num) {
                s.keyframe_started |= @as(u32, 1) << @intCast(i);
            };
            return .advance;
        }

        /// 423: (challenge, timer, seconds, -, counter display, counter,
        /// target, brief (unused), player, reward kind, amount). Holds the
        /// thread until the challenge resolves (3).
        fn frenzyRun(self: *Self, t: *Thread, cmd: Cmd) Step {
            const p = P{ .b = cmd.params };
            const s = V.st(self);
            if (t.wait_at != cmd.num) {
                t.wait_at = cmd.num;
                _ = H.startTimer(self, 0, p.u(1), @as(i32, p.s(2)) * 30);
                _ = H.showCounter(self, 0, p.u(4), p.u(5), p.s(6));
                return .hold;
            }
            if (challengeOf(self, p.u(0))) |ch| {
                if (V.slotPtr(self, p.u(5))) |q| q.* = p.s(6) - ch.progress;
                if (Self.career.isOut(self, 0)) resolve(self, ch, false) else return .hold;
            }
            t.wait_at = 0;
            if (H.displayOf(self, 0, p.u(1))) |d| d.* = .{};
            if (H.displayOf(self, 0, p.u(4))) |d| d.* = .{};
            s.frenzy_running = 0;
            if (val(self, p.u(0)) == vm.result_passed) {
                H.postBannerPrio(self, 0, hudm.named_frenzy_passed, hudm.banner_ticks, hudm.banner_important, 1);
                Self.wanted.clear(self, 0);
                const amount = p.s(10);
                switch (p.u(9)) {
                    1 => Self.career.addScore(self, 0, amount, .with_multiplier),
                    2 => Self.career.setMultiplier(self, 0, @intCast(std.math.clamp(@as(i32, Self.career.multiplier(self, 0)) + amount, 1, 99))),
                    3 => Self.career.addLives(self, 0, @intCast(std.math.clamp(amount, -99, 99))),
                    else => {},
                }
            } else {
                H.postBannerPrio(self, 0, hudm.named_frenzy_failed, hudm.banner_ticks, hudm.banner_important, 2);
            }
            return .advance;
        }
    };
}
