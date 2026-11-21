//! Tuning: getting in and out of cars (entering-and-exiting-cars.md).
//! Owner: workstream D2. Re-exported from `tuning.zig` as `enter_exit`.
//! Numbers marked "notes" come from the note; the rest are ours.

const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// The search looks up to 3 rings of blocks out from a point half a block
/// ahead (notes 3.1).
pub const search_rings: i32 = 3;
/// Giving up on a car more than 4 blocks away (notes 3.2).
pub const give_up = fx.fromInt(4);
/// Max car speed to arrive at the door: 0.2, or 0.1 for law enforcement
/// (notes 3.2).
pub const arrive_speed = fx.ratio(2, 10);
pub const arrive_speed_law = fx.ratio(1, 10);
/// Arrived within 5/32 of the door (notes 3.2).
pub const door_reach = fx.ratio(5, 32);
/// Waiting beside a car that is too fast: within 1 block of the door on the
/// flat (notes 3.2; the ramp's 3/4 is not modelled).
pub const wait_near = fx.one;
/// The door point: this far beyond the car's side (ours).
pub const door_gap = fx.ratio(1, 10);
/// Where along the car the doors are, forward of its centre (ours; the
/// per-model door positions are style data we do not read yet).
pub const door_fwd = fx.ratio(1, 8);
/// Bumped off a car whose doors are all blocked mid-entry: 45 degrees off
/// its heading at 0.05 (notes 3.2).
pub const bump_speed = fx.ratio(5, 100);
/// A pulled-out driver ends up this far further out than the door (ours).
pub const pulled_gap = fx.ratio(3, 10);
/// An AI thief drives his car for 600 ticks, then gets out (notes 3.4).
pub const thief_ticks: u16 = 600;
