//! Tuning: Explosions (explosions-and-damage.md).
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// Explosions live 99 ticks; they hurt while the timer is above 50.
pub const explosion_ticks: u16 = 99;
pub const explosion_active_above: u16 = 50;
/// Blast radius (Chebyshev distance, blocks): small (rockets) and car.
pub const explosion_small = fx.ratio(1, 2);
pub const explosion_car = fx.one;
/// How far above or below the blast it reaches.
pub const explosion_reach_z = fx.ratio(2, 10);
/// Thrown outward at this speed; lifted this much within half the radius,
/// this much within the radius; knocked over outside the radius (but inside
/// twice it) while the timer is above `explosion_knock_above`.
pub const blast_throw = fx.ratio(9, 100);
pub const blast_lift_close = fx.ratio(3, 10);
pub const blast_lift = fx.ratio(1, 10);
pub const blast_knock = fx.ratio(15, 100);
pub const explosion_knock_above: u16 = 70;
/// Cars in the radius take this raw damage in two windows of the timer.
pub const blast_car_damage: i32 = 32000;
