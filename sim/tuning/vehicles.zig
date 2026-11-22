//! Tuning: trailers, cranes and the script car flags (`sys/trailers.zig`,
//! `sys/cranes.zig`, `sys/car_flags.zig`). Every number here is ours: the
//! behaviour notes and the public sources give the rules but not these
//! values (docs/research/public-sources.md 4-6). Tagged "ours" in
//! docs/coverage/.

const fx = @import("../fixed.zig");

// --- Car flags

/// Ticks a car alarm rings once set off (about 10 s).
pub const alarm_ticks: u8 = 250;
/// A car-size explosion this close (Chebyshev, blocks) still hurts a
/// rocketproof car: "a car bomb going off very close still blows it up".
pub const bomb_close = fx.one;

// --- Trailers

/// A cab's hitch (fifth wheel), forward of the cab's rear edge, and a plain
/// car's tow point at its rear bumper.
pub const cab_hitch_in = fx.ratio(3, 8);
/// The trailer's kingpin, back from its front edge (trailer models); a car
/// towed as a trailer hooks on at its front bumper.
pub const kingpin_in = fx.ratio(1, 4);
/// Largest angle between cab and trailer (jack-knife stop), in angle units
/// (65536 a turn): 110 degrees.
pub const max_articulation: u16 = 20025;
/// A cab towing with a trailer steers with its turn ratio x 2.5
/// (car-handling.md 7).
pub const cab_turn_mul = fx.ratio(5, 2);
/// How much of the trailer's mass a towing car feels when accelerating:
/// none for a truck cab (they tow at full speed), all of it for anything
/// else (public-sources.md 5: only the two cabs tow at full speed).
pub const cab_tow_share = 0;
pub const car_tow_share = fx.one;
/// Re-hitching: a free trailer's kingpin within this of a cab's hitch, the
/// two headings within `hitch_angle`, the cab slower than `hitch_speed`.
pub const hitch_reach = fx.ratio(3, 4);
pub const hitch_angle: u16 = 5461; // 30 degrees
pub const hitch_speed = fx.ratio(8, 100);
/// Ticks after a detach before that cab may hitch again (so the trailer
/// it just dropped is not picked straight back up).
pub const rehitch_wait: u8 = 60;
/// The pair breaks if the hitch and kingpin end up this far apart (a
/// teleport, or the trailer jammed while the cab is pulled away).
pub const break_gap = fx.one;

// --- Cranes

/// The most cranes a level declares (public-sources.md 6: ten scripted).
pub const max_cranes = 16;
/// A crane reaches cars in a square this far out from its base, Chebyshev
/// (public-sources.md 6: "a square 4 blocks out from it").
pub const reach = fx.fromInt(4);
/// The jib's resting radius at its home rotation.
pub const home_radius = fx.fromInt(2);
/// Hook speeds: the jib's swing (angle units a tick), the trolley along
/// the jib and the hook's lift (blocks a tick), each easing in by `accel`
/// steps a tick and stopping exactly (camera.md 3.4's rule).
pub const swing_max: i32 = 360;
pub const swing_accel: i32 = 16;
pub const trolley_max = fx.ratio(5, 100);
pub const trolley_accel = fx.ratio(3, 1000);
pub const lift_max = fx.ratio(4, 100);
pub const lift_accel = fx.ratio(3, 1000);
/// The hook rides this high above the ground while carrying.
pub const carry_height = fx.fromInt(2);
/// A car is picked up once it has sat still this long in reach.
pub const wait_ticks: u16 = 75;
/// A car counts as still below this speed (blocks a tick).
pub const still_speed = fx.ratio(1, 100);
/// Ticks the hook pauses to grab or let go.
pub const grip_ticks: u16 = 25;
/// A wreck a crane is reaching for keeps at least this long before it is
/// cleared away.
pub const hold_wreck: u16 = 100;
/// Ticks a crane rests at home before looking again.
pub const rest_ticks: u16 = 50;
