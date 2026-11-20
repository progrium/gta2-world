//! Tuning: Bodies: gravity, falling, steps (car-height.md, ped-movement.md).
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

pub const gravity = fx.ratio(15, 1000);
pub const max_fall = fx.ratio(6, 10);
/// Cars (car-height.md 3.1-3.4): gravity 1/64 a tick, falling at most 1/8
/// a tick; they follow the ground down by up to half a block a step, and
/// past that they leave it at the rate they were climbing or descending
/// (a ramp jump). A car whose centre is over a drop but with a corner
/// still on the ground is tipped over the edge: each unsupported corner
/// pushes by (corner - centre) / 50 a tick. Height is capped below 8.
pub const car_gravity: Fx = fx.one / 64;
pub const car_max_fall: Fx = fx.one / 8;
pub const car_drop = fx.half;
pub const car_tip_div: i32 = 50;
/// Deep water (car-height.md 3.5): a car fully over it at this speed or
/// less sinks, shrinking 2 pixels a tick; gone when its width is.
pub const sink_speed: Fx = fx.ratio(5, 100);
pub const sink_px_per_tick: i32 = 2;
/// A ped who drowns is credited to whoever hurt him within this many ticks
/// (ped-movement.md 3.7).
pub const drown_credit_ticks: u8 = 50;
pub const car_ceiling: Fx = fx.fromInt(8) - fx.one / 64;
/// A grounded body follows the floor down by up to this much per tick
/// (driving down a ramp); further than that it falls.
pub const snap_down = fx.ratio(3, 10);
/// Step heights: a ped climbs 5/16 of a block, a car 7/10 (so its corners
/// do not catch at the top of a ramp). A full block always blocks.
pub const ped_step = fx.ratio(5, 16);
pub const car_step = fx.ratio(7, 10);
/// Largest move per physics sub-step, so nothing tunnels through a block.
pub const max_substep = fx.ratio(1, 4);
