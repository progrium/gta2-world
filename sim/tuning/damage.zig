//! Tuning: Car damage, knock-downs and wrecks (car-collision.md, explosions-and-damage.md, ped-movement.md 3.8).
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// Cars count damage up to 32000; `Health.hp` on a car is 32000 minus it.
pub const car_damage_max: i32 = 32000;
/// First fire at 16000 damage; a larger fire at 25000.
pub const car_fire_damage: i32 = 16000;
pub const car_fire2_damage: i32 = 25000;
/// Whether burning cars blow up on their own is open in the notes; ours:
/// from the larger fire, damage keeps rising until the car explodes (about
/// 3 s).
pub const car_burn_rate: i32 = 80;
/// Raw damage per unit of impact, before anti-strength; restitution of
/// walls and of car against car.
pub const impact_damage: i32 = 200;
pub const wall_restitution_8ths: i32 = 2;
pub const car_restitution_8ths: i32 = 4;
/// An impulse moving a car by less than this a tick leaves it alone
/// (car-collision.md 3.4).
pub const impulse_min = fx.ratio(1, 100);
/// Unstick nudge against a wall: 1 degree and 1/64 block a tick.
pub const unstick_turn: u16 = 182;
pub const unstick_push: Fx = fx.one / 64;
/// Closing speeds below this do no damage (ours: so a car pushing on a wall
/// or another car is not ground down; the notes' dent threshold for walls).
pub const impact_min_speed = fx.ratio(3, 100);
/// Car and object hits dent a car only above this impact
/// (car-collision.md 3.5); walls use `impact_min_speed`.
pub const dent_min_impact = fx.ratio(3, 10);
/// A car closing on a ped faster than this hits him (ours); slower, he is
/// just pushed aside.
pub const car_hit_min = fx.ratio(2, 100);
/// Lift of a player thrown by a car hit of 0.1-0.2 and of 0.2-0.3.
pub const knock_lift_light = fx.ratio(5, 100);
pub const knock_lift_mid = fx.ratio(1, 10);
/// Ped knock-back thresholds from a car hit (ped-movement.md 3.8).
pub const knock_light = fx.ratio(1, 10);
pub const knock_mid = fx.ratio(2, 10);
pub const knock_hard = fx.ratio(3, 10);

/// A burnt-out wreck stays for this many ticks (10 s), then a new traffic
/// car appears elsewhere.
pub const wreck_ticks: u16 = 300;
/// `Appearance.remap` of a burnt-out wreck (a dark palette in the style).
pub const wreck_remap: u16 = 0;
