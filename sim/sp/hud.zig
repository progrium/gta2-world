//! The sim-side display state the client draws (single player): banner,
//! brief queue, timer, counters, arrow target. Owner: workstream A1
//! (script-messages.md); H draws it. W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

/// Per player, in the SP state block (`state.sp.hud[slot]`).
pub const State = extern struct {
    /// Banner text id and ticks left.
    banner: u32 = 0,
    banner_ticks: u16 = 0,
    brief_len: u8 = 0,
    flags: u8 = 0,
    /// Queued brief text ids.
    briefs: [4]u32 = @splat(0),
    /// Countdown in ticks (0 = none).
    timer: u32 = 0,
    counters: [2]i32 = @splat(0),
    /// The arrow points at this entity, or at (arrow_x, arrow_y).
    arrow: EntityId = .none,
    arrow_x: Fx = 0,
    arrow_y: Fx = 0,
};

pub fn Sys(comptime Self: type) type {
    return struct {
        pub fn postBanner(self: *Self, slot: u8, text: u32, ticks: u16) void {
            _ = .{ self, slot, text, ticks };
        }
        pub fn queueBrief(self: *Self, slot: u8, text: u32) void {
            _ = .{ self, slot, text };
        }
        pub fn setTimer(self: *Self, slot: u8, ticks: u32) void {
            _ = .{ self, slot, ticks };
        }
        pub fn setCounter(self: *Self, slot: u8, which: u1, value: i32) void {
            _ = .{ self, slot, which, value };
        }
        pub fn setArrow(self: *Self, slot: u8, target: EntityId, x: Fx, y: Fx) void {
            _ = .{ self, slot, target, x, y };
        }
    };
}
