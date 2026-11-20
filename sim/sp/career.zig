//! Player career (single player): lives, multiplier, cash/points, jail
//! cards, death and arrest state, power-up timers not yet on the ped.
//! Owner: workstream G (power-ups-death-and-arrest.md, scoring.md,
//! script-player.md). W0 stub: the API has its final shape and does
//! nothing or returns defaults.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

/// Per player, in the SP state block (`state.sp.career[slot]`).
pub const State = extern struct {
    lives: u8 = 0,
    multiplier: u8 = 0,
    jail_cards: u8 = 0,
    flags: u8 = 0,
    /// Points; in GTA2 cash and points are one number.
    points: i32 = 0,
};

/// How a score is added (scoring.md: some rewards ignore the multiplier).
pub const Multiplied = enum { with_multiplier, flat };

pub fn Sys(comptime Self: type) type {
    return struct {
        /// Add points (or cash) for `slot`.
        pub fn addScore(self: *Self, slot: u8, amount: i32, how: Multiplied) void {
            _ = .{ self, slot, amount, how };
        }
        pub fn score(self: *const Self, slot: u8) i32 {
            _ = .{ self, slot };
            return 0;
        }
        pub fn lives(self: *const Self, slot: u8) u8 {
            _ = .{ self, slot };
            return 0;
        }
        pub fn addLives(self: *Self, slot: u8, n: i8) void {
            _ = .{ self, slot, n };
        }
        pub fn multiplier(self: *const Self, slot: u8) u8 {
            _ = .{ self, slot };
            return 1;
        }
        pub fn setMultiplier(self: *Self, slot: u8, m: u8) void {
            _ = .{ self, slot, m };
        }
        pub fn addJailCard(self: *Self, slot: u8) void {
            _ = .{ self, slot };
        }
        /// Wasted or busted and not yet back on the street.
        pub fn isOut(self: *const Self, slot: u8) bool {
            _ = .{ self, slot };
            return false;
        }
        /// Start the busted sequence (power-ups-death-and-arrest.md 3.3).
        pub fn bust(self: *Self, slot: u8, by: EntityId) void {
            _ = .{ self, slot, by };
        }
        /// Give a timed power-up (power-ups-death-and-arrest.md 3.1).
        pub fn givePowerUp(self: *Self, slot: u8, which: u8, ticks: u16) void {
            _ = .{ self, slot, which, ticks };
        }
    };
}
