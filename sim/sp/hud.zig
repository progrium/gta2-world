//! The sim-side display state the client draws (single player): the
//! one-line banner, the brief queue, the four timer/counter display slots
//! and the arrow. Owner: workstream A1 (script-messages.md); H draws it.
//!
//! Text ids are `.gxt` message numbers (looked up as their decimal digits).
//! Ids with the top bit set (`text_named | n`) are fixed texts the client
//! supplies itself (the `named_*` constants).

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

pub const text_named: u32 = 0x8000_0000;
/// The "mission failed" banner (script-messages.md 5).
pub const named_mission_failed: u32 = text_named | 1;
/// The single fixed fail brief when no gang's mission flag is set
/// (script-declarations.md 2.16).
pub const named_fail_brief: u32 = text_named | 2;
pub const named_kill_frenzy: u32 = text_named | 3;
pub const named_frenzy_passed: u32 = text_named | 4;
pub const named_frenzy_failed: u32 = text_named | 5;

/// Banner priorities (script-messages.md 4).
pub const banner_normal: u8 = 0;
pub const banner_important: u8 = 1;
/// Brief priorities: normal (118), soon (321), now (279).
pub const brief_normal: u8 = 0;
pub const brief_soon: u8 = 1;
pub const brief_now: u8 = 2;

/// How long a banner stays up (script-messages.md 4: 90 ticks).
pub const banner_ticks: u16 = 90;
/// Shared pool of queued briefs (script-messages.md 4: 20).
pub const max_briefs = 20;
/// Timer/counter display slots (script-messages.md 4: 4).
pub const max_displays = 4;
/// Brief typing speed (script-messages.md 4: 3 ticks a character).
pub const ticks_per_char: u16 = 3;
/// Ours: how long a typed-out brief stays up before the next one, and the
/// length assumed for a text the host gave no length for.
pub const brief_linger: u16 = 90;
pub const default_text_len: u16 = 60;

pub const Brief = extern struct {
    text: u32 = 0,
    prio: u8 = 0,
    voice: u8 = 0,
    _pad: u16 = 0,
};

pub const Display = extern struct {
    /// Ticks left on the countdown (keeps counting below zero; shown as 0).
    timer: i32 = 0,
    /// The bound counter's live value.
    counter: i32 = 0,
    /// The script command that owns this slot (its handle), 0 = free.
    owner: u16 = 0,
    /// The counter shown (its declaring command).
    counter_cmd: u16 = 0,
    /// `display_*`.
    flags: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
};
pub const display_timer: u8 = 1;
pub const display_counter: u8 = 2;

/// Per player, in the SP state block (`state.sp.hud[slot]`).
pub const State = extern struct {
    /// Banner text id and ticks left (shown while > 0).
    banner: u32 = 0,
    banner_ticks: u16 = 0,
    banner_prio: u8 = 0,
    /// 0 none, 1 "job complete", 2 "job fail" voice line.
    banner_voice: u8 = 0,
    /// Entries in `briefs`, front first.
    brief_len: u8 = 0,
    /// 1 when `briefs[0]` is on screen.
    brief_showing: u8 = 0,
    flags: u8 = 0,
    _pad0: u8 = 0,
    /// Ticks the front brief has been up, and how long it stays.
    brief_ticks: u16 = 0,
    brief_total: u16 = 0,
    briefs: [max_briefs]Brief = @splat(.{}),
    display: [max_displays]Display = @splat(.{}),
    /// The arrow points at this entity, or at (arrow_x, arrow_y).
    arrow: EntityId = .none,
    arrow_x: Fx = 0,
    arrow_y: Fx = 0,
};

comptime {
    for (.{ Brief, Display, State }) |T| {
        var sum: usize = 0;
        for (@typeInfo(T).@"struct".field_types) |FT| sum += @sizeOf(FT);
        if (sum != @sizeOf(T)) @compileError("implicit padding in " ++ @typeName(T));
    }
}

pub fn Sys(comptime Self: type) type {
    return struct {
        fn hud(self: *Self, slot: u8) ?*State {
            if (comptime !Self.single_player) return null;
            if (slot >= self.state.sp.hud.len) return null;
            return &self.state.sp.hud[slot];
        }

        /// A normal-priority banner (pickups, bonuses, death text).
        pub fn postBanner(self: *Self, slot: u8, text: u32, ticks: u16) void {
            postBannerPrio(self, slot, text, ticks, banner_normal, 0);
        }

        /// Show `text` as the banner unless the one up is more urgent.
        pub fn postBannerPrio(self: *Self, slot: u8, text: u32, ticks: u16, prio: u8, voice: u8) void {
            const h = hud(self, slot) orelse return;
            if (h.banner_ticks > 0 and h.banner_prio > prio) return;
            h.banner = text;
            h.banner_ticks = ticks;
            h.banner_prio = prio;
            h.banner_voice = voice;
            self.pushEvent(.{ .kind = .message, .a = slot, .b = voice, .x = @bitCast(text) });
        }

        pub fn queueBrief(self: *Self, slot: u8, text: u32) void {
            queueBriefPrio(self, slot, text, brief_normal, 0);
        }

        /// Queue a brief (script-messages.md 2.3): behind every entry of
        /// higher or equal priority; `brief_now` goes to the front and starts
        /// at once, the one showing moving back behind it.
        pub fn queueBriefPrio(self: *Self, slot: u8, text: u32, prio: u8, voice: u8) void {
            const h = hud(self, slot) orelse return;
            const e: Brief = .{ .text = text, .prio = prio, .voice = voice };
            var at: usize = h.brief_len;
            if (prio == brief_now) {
                at = 0;
            } else {
                // Never in front of the one showing.
                var i: usize = if (h.brief_showing != 0) 1 else 0;
                while (i < h.brief_len) : (i += 1) {
                    if (h.briefs[i].prio < prio) {
                        at = i;
                        break;
                    }
                }
            }
            if (h.brief_len >= max_briefs) {
                if (at >= max_briefs) return;
                h.brief_len = max_briefs - 1; // the last queued one is dropped
            }
            var j: usize = h.brief_len;
            while (j > at) : (j -= 1) h.briefs[j] = h.briefs[j - 1];
            h.briefs[at] = e;
            h.brief_len += 1;
            if (at == 0) {
                h.brief_showing = 0;
                startFront(self, slot, h);
            }
        }

        pub fn clearBriefs(self: *Self, slot: u8) void {
            const h = hud(self, slot) orelse return;
            h.brief_len = 0;
            h.brief_showing = 0;
            h.brief_ticks = 0;
            h.brief_total = 0;
            h.briefs = @splat(.{});
        }

        pub fn briefShowing(self: *Self, slot: u8) bool {
            const h = hud(self, slot) orelse return false;
            return h.brief_showing != 0;
        }

        fn textLen(self: *Self, text: u32) u16 {
            if (self.level) |l| if (text < l.text_lengths.len and l.text_lengths[text] != 0) return l.text_lengths[text];
            return default_text_len;
        }

        fn startFront(self: *Self, slot: u8, h: *State) void {
            if (h.brief_len == 0 or h.brief_showing != 0) return;
            const b = h.briefs[0];
            h.brief_showing = 1;
            h.brief_ticks = 0;
            const len: u32 = textLen(self, b.text);
            h.brief_total = @intCast(@min(0xFFFF, len * ticks_per_char + brief_linger));
            self.pushEvent(.{ .kind = .brief, .a = slot, .b = b.voice, .x = @bitCast(b.text) });
        }

        /// The first display slot `owner` holds, if any.
        pub fn displayOf(self: *Self, slot: u8, owner: u16) ?*Display {
            const h = hud(self, slot) orelse return null;
            for (&h.display) |*d| if (d.owner == owner and d.flags != 0) return d;
            return null;
        }

        /// Start a countdown in a free display slot, owned by `owner`
        /// (script-messages.md 2.6). Null when every slot is in use.
        pub fn startTimer(self: *Self, slot: u8, owner: u16, ticks: i32) ?*Display {
            const h = hud(self, slot) orelse return null;
            if (displayOf(self, slot, owner)) |d| {
                d.timer = ticks;
                d.flags |= display_timer;
                return d;
            }
            for (&h.display) |*d| if (d.flags == 0) {
                d.* = .{ .timer = ticks, .owner = owner, .flags = display_timer };
                return d;
            };
            return null;
        }

        /// Show counter `counter_cmd` (script-messages.md 2.7): a slot with
        /// only a countdown on it is reused first, then a free one.
        pub fn showCounter(self: *Self, slot: u8, owner: u16, counter_cmd: u16, value: i32) ?*Display {
            const h = hud(self, slot) orelse return null;
            if (displayOf(self, slot, owner)) |d| {
                d.counter_cmd = counter_cmd;
                d.counter = value;
                d.flags |= display_counter;
                return d;
            }
            for (&h.display) |*d| if (d.flags == display_timer) {
                d.counter_cmd = counter_cmd;
                d.counter = value;
                d.flags |= display_counter;
                return d;
            };
            for (&h.display) |*d| if (d.flags == 0) {
                d.* = .{ .counter = value, .owner = owner, .counter_cmd = counter_cmd, .flags = display_counter };
                return d;
            };
            return null;
        }

        /// W0 API: a countdown in the first display slot.
        pub fn setTimer(self: *Self, slot: u8, ticks: u32) void {
            const h = hud(self, slot) orelse return;
            h.display[0].timer = @intCast(@min(ticks, 0x7FFF_FFFF));
            if (ticks > 0) h.display[0].flags |= display_timer else h.display[0].flags &= ~display_timer;
        }
        /// W0 API: a number in display slot `which`.
        pub fn setCounter(self: *Self, slot: u8, which: u1, value: i32) void {
            const h = hud(self, slot) orelse return;
            h.display[which].counter = value;
            h.display[which].flags |= display_counter;
        }
        pub fn setArrow(self: *Self, slot: u8, target: EntityId, x: Fx, y: Fx) void {
            const h = hud(self, slot) orelse return;
            h.arrow = target;
            h.arrow_x = x;
            h.arrow_y = y;
        }

        /// Once a tick (from the script system): banner time, brief typing
        /// and turnover, countdowns.
        pub fn tickHud(self: *Self) void {
            if (comptime !Self.single_player) return;
            for (&self.state.sp.hud, 0..) |*h, i| {
                const slot: u8 = @intCast(i);
                if (h.banner_ticks > 0) h.banner_ticks -= 1;
                if (h.brief_showing != 0) {
                    h.brief_ticks +|= 1;
                    if (h.brief_ticks >= h.brief_total) {
                        var j: usize = 1;
                        while (j < h.brief_len) : (j += 1) h.briefs[j - 1] = h.briefs[j];
                        h.brief_len -= 1;
                        h.briefs[h.brief_len] = .{};
                        h.brief_showing = 0;
                    }
                }
                startFront(self, slot, h);
                for (&h.display) |*d| {
                    if (d.flags & display_timer != 0 and d.timer > -0x7FFF_0000) d.timer -= 1;
                    if (d.flags & display_counter != 0 and d.counter_cmd < self.state.sp.script.slot.len) d.counter = self.state.sp.script.slot[d.counter_cmd];
                }
            }
        }
    };
}
