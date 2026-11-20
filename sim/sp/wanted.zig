//! Wanted level (single player): points and stars, crime reports, the
//! one-star timeout. Owner: workstream E (wanted-level.md). W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

/// Per player, in the SP state block (`state.sp.wanted[slot]`).
pub const State = extern struct {
    points: u16 = 0,
    /// Stars cap set by the script (0 = none, 6 = no cap).
    cap: u8 = 0,
    flags: u8 = 0,
    /// Ticks since the last pursuit (the 900-tick one-star timeout).
    quiet: u16 = 0,
    _pad: u16 = 0,
};

/// What was done (wanted-level.md: what earns points).
pub const Crime = enum(u8) { shot_fired, ped_hurt, ped_killed, cop_hurt, cop_killed, car_stolen, car_destroyed, ran_over, rammed_cop, _ };

pub fn Sys(comptime Self: type) type {
    return struct {
        pub fn addPoints(self: *Self, slot: u8, points: i32) void {
            _ = .{ self, slot, points };
        }
        /// At least one star (script-player.md).
        pub fn atLeastOneStar(self: *Self, slot: u8) void {
            _ = .{ self, slot };
        }
        pub fn clear(self: *Self, slot: u8) void {
            _ = .{ self, slot };
        }
        pub fn setCap(self: *Self, slot: u8, max_stars: u8) void {
            _ = .{ self, slot, max_stars };
        }
        pub fn stars(self: *const Self, slot: u8) u8 {
            _ = .{ self, slot };
            return 0;
        }
        /// File a crime report: `by` did `crime` at (x, y, z), seen or not.
        pub fn reportCrime(self: *Self, crime: Crime, by: EntityId, x: Fx, y: Fx, z: Fx) void {
            _ = .{ self, crime, by, x, y, z };
        }
        /// Wanted bookkeeping, once a tick.
        pub fn sysWanted(self: *Self) void {
            _ = self;
        }
    };
}
