//! Tuning: Scoring (scoring.md).
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// First to this many frags (kills, less one for each death by your own
/// hand) wins the round; frags and points then reset.
pub const frag_limit: i32 = 10;

/// Points (scoring.md; the multiplier is 1 in deathmatch). Another player
/// killed: by weapon, fire or blast; run over; electrocuted.
pub const points_player_weapon: i32 = 2000;
pub const points_player_run_over: i32 = 1000;
pub const points_player_electro: i32 = 5000;
/// An ordinary civilian killed by weapon; run over pays half, electrocution
/// two and a half times; times the kill combo.
pub const points_civilian: i32 = 20;
/// Kills (and car destructions) less than this many ticks apart raise the
/// combo, up to `combo_max`.
pub const combo_window: u8 = 15;
pub const combo_max: u8 = 5;
/// Destroying a car pays its value times this, times the car combo.
pub const destroy_value_factor: i32 = 5;
/// Each credited hit on a car: 1 point under 300 damage, 10 under 400,
/// else 100.
pub const damage_band_low: i32 = 300;
pub const damage_band_high: i32 = 400;
