//! Script commands on the player (script-player.md): score and cash, the
//! multiplier, lives, the wanted level, control locks, the death/arrest
//! flag and the respect snapshot. Owner: workstream A2. A thin layer over
//! `career` (G), `wanted` (E) and `gangs` (D2).
//!
//! Layouts (from the player's .scr files): every command starts with the
//! character's u16 handle. 141/392/194 then pad to 4 and an i32; 342 pads
//! to 4 and a u16 counter; 195 and 282 a u16 at 2; 163 nothing more;
//! 164/421/400/407 a u16 at 2. Guessed (no level uses them): 196 and 192
//! like 194; 197 and 193 like 195; 281 like 282.

const std = @import("std");
const prelude = @import("../prelude.zig");
const c = prelude.c;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const W = @import("world.zig");
const Cmd = W.Cmd;
const Outcome = W.Outcome;

pub const done = [_]u16{ 141, 392, 342, 194, 195, 196, 197, 282, 281, 192, 193, 163, 164, 421, 418, 400, 407, 443, 445, 446 };
pub const stubbed = [_]u16{};

/// Points from which each star count starts (wanted-level.md 3.1).
pub const star_points = [_]i32{ 0, 600, 1600, 3000, 5000, 8000, 12000 };

pub fn Sys(comptime Self: type) type {
    return struct {
        const H = W.Helpers(Self);

        pub fn exec(self: *Self, ctx: anytype, cmd: Cmd) Outcome {
            const p = W.params(cmd);
            const who = ctx.handle(p.u16_(0));
            const slot = H.playerSlot(self, who);
            switch (cmd.kind) {
                // 2.1 Score, cash and the multiplier.
                141, 392 => if (slot) |s| Self.career.addScore(self, s, p.i32_(4), if (cmd.kind == 141) .with_multiplier else .flat),
                342 => if (slot) |s| {
                    if (ctx.counter(p.u16_(4))) |v| Self.career.addScore(self, s, v.*, .with_multiplier);
                },
                194 => if (slot) |s| ctx.setCond(Self.career.score(self, s) > p.i32_(4)),
                195 => if (slot) |s| {
                    if (ctx.counter(p.u16_(2))) |v| v.* = Self.career.score(self, s);
                },
                196 => if (slot) |s| ctx.setCond(@as(i32, Self.career.multiplier(self, s)) > p.i32_(4)),
                // 197 and 193 read the player's data with no player check:
                // a non-player character reads slot 0 (script-player 5).
                197 => if (ctx.counter(p.u16_(2))) |v| {
                    v.* = Self.career.multiplier(self, slot orelse 0);
                },
                282 => if (slot) |s| {
                    const m = std.math.clamp(@as(i32, Self.career.multiplier(self, s)) + p.i16_(2), 1, 99);
                    Self.career.setMultiplier(self, s, @intCast(m));
                },
                // 2.2 Lives.
                281 => if (slot) |s| {
                    const now: i32 = Self.career.lives(self, s);
                    const want = std.math.clamp(now + p.i16_(2), 0, 99);
                    Self.career.addLives(self, s, @intCast(want - now));
                },
                192 => if (slot) |s| ctx.setCond(@as(i32, Self.career.lives(self, s)) > p.i32_(4)),
                193 => if (ctx.counter(p.u16_(2))) |v| {
                    v.* = Self.career.lives(self, slot orelse 0);
                },
                // 2.3 Wanted level (any character; only the player's drives anything).
                163 => if (slot) |s| Self.wanted.clear(self, s),
                164, 421 => {
                    const n = p.u16_(2);
                    if (n > 6) return .done; // out of range: ignored (2.3)
                    const s = slot orelse return .done;
                    if (cmd.kind == 164) Self.wanted.setStars(self, s, @intCast(n)) else Self.wanted.raiseToStars(self, s, @intCast(n));
                },
                418 => setMaxWanted(self, p.u16_(2)),
                // 2.4 Locks on the local player's own controls (the
                // character is ignored).
                400 => setFlag(self, W.State.flag_no_enter, p.u16_(2) == 0),
                407 => setFlag(self, W.State.flag_no_controls, p.u16_(2) == 0),
                // 2.5 Death/arrest flag and the respect snapshot.
                443 => ctx.setCond(ctx.deathArrestFlag().*),
                445 => {
                    const s = H.st(self);
                    for (&s.respect_snapshot, 0..) |*r, g| r.* = Self.gangs.respect(self, @intCast(g));
                    s.flags |= W.State.flag_snapshot;
                },
                446 => {
                    const s = H.st(self);
                    for (s.respect_snapshot, 0..) |r, g| {
                        const now = Self.gangs.respect(self, @intCast(g));
                        // Respect moves in steps of 20 (gangs-and-respect.md).
                        const steps = @divTrunc(@as(i32, r) - now, 20);
                        if (steps != 0) Self.gangs.changeRespect(self, @intCast(g), @intCast(std.math.clamp(steps, -10, 10)));
                    }
                },
                else => return .unhandled,
            }
            return .done;
        }

        /// 304 and 418: cap the level's wanted level; exactly 0 also forces
        /// police simulation on (script-declarations 5).
        pub fn setMaxWanted(self: *Self, stars: u16) void {
            const s = H.st(self);
            const n: u8 = @intCast(@min(stars, 6));
            s.max_wanted = n;
            if (stars == 0) s.flags |= W.State.flag_police_forced;
            var slot: u8 = 0;
            while (slot < Self.config.max_players) : (slot += 1) Self.wanted.setCap(self, slot, n);
        }

        fn setFlag(self: *Self, f: u8, on: bool) void {
            const s = H.st(self);
            if (on) s.flags |= f else s.flags &= ~f;
        }

        /// For the input system: may the local player's ped act this tick,
        /// and may it get into cars (400, 407)?
        pub fn controlsLocked(self: *const Self) bool {
            return self.state.sp.world.flags & W.State.flag_no_controls != 0;
        }
        pub fn enterLocked(self: *const Self) bool {
            return self.state.sp.world.flags & W.State.flag_no_enter != 0;
        }
    };
}
