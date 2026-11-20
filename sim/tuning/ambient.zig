//! Tuning: Ambient population near players.
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// Ambient cars and peds this far (blocks, Chebyshev) from every player are
/// moved: despawned and replaced between `ambient_near_min` and
/// `ambient_near_radius` blocks of a random player.
pub const ambient_far: i32 = 36;
pub const ambient_near_radius: i32 = 26;
pub const ambient_near_min: i32 = 14;
/// At most this many are moved per tick.
pub const ambient_moves_per_tick: u32 = 2;
