//! Tuning: Health and respawn.
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// The "wasted" countdown before respawning (power-ups-death-and-arrest.md).
pub const respawn_ticks: u32 = 70;
/// A player (joining or respawning) appears on pavement within this many
/// blocks of another active player, and at least `spawn_near_min` away,
/// when such a spot exists; otherwise anywhere on pavement.
pub const spawn_near_radius: i32 = 12;
pub const spawn_near_min: i32 = 3;
