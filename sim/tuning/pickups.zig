//! Tuning: Pickups near players.
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;
const pickup_kinds = @import("weapons.zig").pickup_kinds;

/// Pickups on the map: this many, plus `pickups_per_player` per active
/// player, placed on pavement near a random player.
pub const pickups_base: u32 = 2;
pub const pickups_per_player: u32 = 2;
pub const pickup_near_radius: i32 = 14;
pub const pickup_near_min: i32 = 3;
/// A pickup nobody takes disappears after this many ticks (60 s).
pub const pickup_life: u16 = 1800;
pub const pickup_reach = fx.ratio(6, 10);
/// Health pickups restore full health (power-ups-death-and-arrest.md).
/// Odds of each pickup kind, out of 100 (ours), in `Weapon.kind` order:
/// pistol (never), machine gun, shotgun, rockets, dual pistols, silenced
/// machine gun, flamethrower, electro gun, grenades, molotovs, then health,
/// armour, invulnerability, double damage, fast reload.
pub const pickup_odds = [pickup_kinds]u32{ 0, 12, 10, 6, 8, 5, 6, 5, 7, 7, 14, 6, 3, 5, 6 };
comptime {
    var sum: u32 = 0;
    for (pickup_odds) |o| sum += o;
    if (sum != 100) @compileError("pickup odds must add up to 100");
}
