//! Message commands (script-messages.md): the banner, briefs, and the
//! timer and counter displays. The display state is `sp/hud.zig`.
//! Owner: workstream A1.
//!
//! The timer and counter commands name a display-declaration command
//! (type 233) as the handle their display hangs on: in the player's files
//! 119, 120, 433 and 416 take that command as their first parameter, and
//! 414/415 do the same, with the counter second.

const vm = @import("vm.zig");
const hudm = @import("../sp/hud.zig");
const Thread = vm.Thread;
const Step = vm.Step;
const Cmd = vm.Cmd;
const P = vm.P;
const k = vm.k;
const world = @import("world.zig");
const EntityId = @import("../prelude.zig").EntityId;

/// Seconds to ticks (script-messages.md 4: x30).
pub const ticks_per_second = 30;

pub fn Sys(comptime Self: type) type {
    return struct {
        const V = Self.script;
        const H = Self.hud;

        fn showArrow(self: *Self, decl: u16, target: EntityId, x: @import("../prelude.zig").Fx, y: @import("../prelude.zig").Fx) void {
            V.st(self).arrow_owner = decl;
            H.setArrow(self, 0, target, x, y);
        }

        pub fn exec(self: *Self, t: *Thread, cmd: Cmd) ?Step {
            const p = P{ .b = cmd.params };
            const slot: u8 = 0; // the local player
            switch (cmd.kind) {
                k.message => {
                    H.postBannerPrio(self, slot, p.u(0), hudm.banner_ticks, hudm.banner_important, @truncate(p.u(1)));
                    return .advance;
                },
                k.brief, k.brief_soon, k.brief_now => {
                    const prio: u8 = switch (cmd.kind) {
                        k.brief => hudm.brief_normal,
                        k.brief_soon => hudm.brief_soon,
                        else => hudm.brief_now,
                    };
                    H.queueBriefPrio(self, slot, p.u(0), prio, @truncate(p.u(1)));
                    return .advance;
                },
                k.clear_briefs => {
                    H.clearBriefs(self, slot);
                    return .advance;
                },
                k.brief_showing => {
                    t.cond = @intFromBool(H.briefShowing(self, slot));
                    return .advance;
                },
                k.display_decl, k.counter_display_decl, k.arrow => return .advance,
                // The arrow (ours): 113 points declaration @4 at the thing
                // command @0 declared, 114 at the place @0 (x, y, z),
                // declaration @12; 116 removes declaration @0's arrow.
                k.arrow_at => {
                    const target = V.handle(self, p.u(0));
                    if (!target.isNone()) showArrow(self, p.u(2), target, 0, 0);
                    return .advance;
                },
                k.arrow_pos => {
                    const pos = world.params(cmd).pos(0);
                    showArrow(self, p.u(6), .none, pos.x, pos.y);
                    return .advance;
                },
                k.arrow_clear => {
                    const s = V.st(self);
                    if (s.arrow_owner == p.u(0)) {
                        s.arrow_owner = 0;
                        H.setArrow(self, slot, .none, 0, 0);
                    }
                    return .advance;
                },
                k.timer => {
                    _ = H.startTimer(self, slot, p.u(0), @as(i32, p.s(1)) * ticks_per_second);
                    return .advance;
                },
                k.timer_add => {
                    if (H.displayOf(self, slot, p.u(0))) |d| {
                        d.timer +%= @as(i32, p.s(1)) * ticks_per_second;
                        d.flags |= hudm.display_timer;
                    }
                    return .advance;
                },
                k.timer_clear => {
                    if (H.displayOf(self, slot, p.u(0))) |d| d.* = .{};
                    return .advance;
                },
                k.clock_clear => {
                    if (H.displayOf(self, slot, p.u(0))) |d| {
                        d.flags &= ~hudm.display_timer;
                        d.timer = 0;
                        if (d.flags == 0) d.* = .{};
                    }
                    return .advance;
                },
                k.show_counter => {
                    const v = if (V.slotPtr(self, p.u(1))) |q| q.* else 0;
                    _ = H.showCounter(self, slot, p.u(0), p.u(1), v);
                    return .advance;
                },
                k.counter_clear => {
                    if (H.displayOf(self, slot, p.u(0))) |d| {
                        d.flags &= ~hudm.display_counter;
                        d.counter = 0;
                        d.counter_cmd = 0;
                        if (d.flags == 0) d.* = .{};
                    }
                    return .advance;
                },
                else => return null,
            }
        }
    };
}
