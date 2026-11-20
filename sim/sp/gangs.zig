//! Gangs and respect (single player). Owner: workstream D2
//! (gangs-and-respect.md, script-declarations.md 2.11). W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

/// In the SP state block (`state.sp.gangs`).
pub const State = extern struct {
    /// Respect per gang, -100..100 (gangs-and-respect.md).
    respect: [ids.max_gangs]i8 = @splat(0),
    /// Gangs the level declared.
    count: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

pub fn Sys(comptime Self: type) type {
    return struct {
        pub fn respect(self: *const Self, gang: u8) i8 {
            _ = .{ self, gang };
            return 0;
        }
        /// Change respect by whole steps (mission rewards, script).
        pub fn changeRespect(self: *Self, gang: u8, steps: i8) void {
            _ = .{ self, gang, steps };
        }
        /// A member of `gang` was killed by `by` (knock-ons to rivals).
        pub fn onKill(self: *Self, gang: u8, by: EntityId) void {
            _ = .{ self, gang, by };
        }
        /// The weapon members of `gang` use against the player.
        pub fn weaponForPlayer(self: *const Self, gang: u8) u8 {
            _ = .{ self, gang };
            return 0;
        }
        /// The gang whose area holds block (bx, by), or `ids.gang_none`.
        pub fn gangOfArea(self: *const Self, bx: i32, by: i32) u8 {
            _ = .{ self, bx, by };
            return ids.gang_none;
        }
        pub fn sysGangs(self: *Self) void {
            _ = self;
        }
    };
}
