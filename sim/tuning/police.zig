//! Tuning: wanted level and police (wanted-level.md, police-ai.md).
//! Owner: workstream E. Imported directly by `sp/wanted.zig` and
//! `sp/police.zig`; numbers marked "notes" come from the behaviour notes,
//! "ours" are our own where the notes are silent.

const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// Points for 0-6 stars (notes: wanted-level.md 3.1).
pub const star_points = [7]u16{ 0, 600, 1600, 3000, 5000, 8000, 12000 };
pub const max_points: u16 = 12000;
pub const max_stars: u8 = 6;

/// What earns points (notes: wanted-level.md 3.2).
pub const points_civilian: i32 = 100;
pub const points_emergency: i32 = 500;
pub const points_gang: i32 = 1;
pub const points_car_destroyed: i32 = 200;
/// Impact on a police, SWAT or FBI vehicle that earns a star (notes:
/// car-collision.md 3.7, wanted-level.md 3.2). Impact is the impulse
/// magnitude, the same `j` that `sys/contacts.zig` turns into damage.
pub const ram_cop_impact: Fx = fx.ratio(6, 10);

/// One-star timeout (notes: wanted-level.md 3.4).
pub const one_star_timeout: u16 = 900;

/// Ticks the "recent crime" timer runs after a report (ours: the notes name
/// the timer but not its length).
pub const recent_crime_ticks: u16 = 300;
/// Crime report ring size (ours: "a small ring").
pub const report_ring: usize = 8;

/// How far a cop sees the player, in blocks either way (ours: about the
/// original's screen at normal zoom; the notes say "in view"). Within one
/// level of height either way (ours).
pub const cop_view_x: Fx = fx.fromInt(7);
pub const cop_view_y: Fx = fx.fromInt(6);
pub const cop_view_z: Fx = fx.fromInt(1);

/// "Can still see them" clock (notes: police-ai.md 5).
pub const sight_ticks: u16 = 250;
/// Spawn delay for the first crew and for a backup crew (notes:
/// wanted-level.md 3.5, police-ai.md 5).
pub const first_crew_delay: u16 = 200;
pub const backup_crew_delay: u16 = 50;
/// Global cap on new police cars after a pursuit ends (notes:
/// wanted-level.md 3.5).
pub const new_car_cap_reset: u8 = 2;
