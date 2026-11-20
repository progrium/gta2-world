//! Tuning: Pedestrians (ped-movement.md, entering-and-exiting-cars.md).
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// Half the 0.2 x 0.2 block collision square.
pub const ped_radius = fx.ratio(1, 10);
/// Collision height.
pub const ped_height = fx.ratio(1, 4);
/// Mass for impacts (car-collision.md).
pub const ped_mass = fx.half;
pub const ped_hp: i32 = 100;
pub const ped_turn_aim: i32 = 546;
pub const ped_turn_max: i32 = 2185;
pub const ped_turn_jump: i32 = 182;
pub const ped_turn_jump_max: i32 = 1092;
/// A jump: this many ticks moving forward at the run pace, at the take-off
/// height (GTA2 jumps do not leave the ground; 8 animation frames, frame
/// length not in the notes, so ours). `ped_jump_vz` is unused and kept for
/// the tuning panel.
pub const ped_jump_ticks: u8 = 16;
pub const ped_jump_cooldown: u8 = 20;
/// Hitting a wall: slide along it at half speed.
pub const ped_slide_shift: u5 = 1;
/// Falling: 0.01 a tick more, to at most 0.1 a tick.
pub const ped_gravity = fx.ratio(1, 100);
pub const ped_max_fall = fx.ratio(1, 10);
/// Knocked over (gets straight up) and knocked down (lies a while): ticks on
/// the ground. The notes leave the timing to animations; ours.
pub const knock_over_ticks: u16 = 20;
pub const knock_down_ticks: u16 = 50;
/// Thrown bodies: gravity, and how fast a sliding body on the ground slows.
pub const thrown_gravity = fx.ratio(2, 100);
pub const thrown_friction = fx.ratio(1, 64);
/// Entering (entering-and-exiting-cars.md): the search starts half a block
/// in front of the ped; the car must be slower than 0.2 a tick. Getting out
/// needs the car below 0.3 a tick.
pub const enter_reach = fx.ratio(3, 2);
pub const enter_ahead = fx.ratio(1, 2);
pub const enter_max_speed = fx.ratio(2, 10);
pub const exit_max_speed = fx.ratio(3, 10);
