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

// --- Crews (police-ai.md) -------------------------------------------------

/// Crews alive at once, all pursuits together (ours).
pub const max_crews = 6;
/// Officers per car (notes: police-ai.md 5).
pub const police_crew_size: u8 = 2;
pub const swat_crew_size: u8 = 4;
/// Health and weapon by crew kind and heat (ours: the note says police
/// are frailer with only a sidearm at the lowest heat, SWAT much tougher).
pub const police_hp_low: i32 = 60;
pub const police_hp: i32 = 100;
pub const swat_hp: i32 = 200;
/// Where a crew's car appears: a road block this many blocks from the last
/// known position, out of the way (ours).
pub const spawn_radius: i32 = 18;
pub const spawn_min: i32 = 10;
/// A crew gets out to chase on foot when the target is on foot within this
/// distance, or in a car below `stopped_speed` within `pull_out_dist`
/// (ours).
pub const foot_dist: Fx = fx.fromInt(5);
pub const pull_out_dist: Fx = fx.fromInt(3);
pub const stopped_speed: Fx = fx.ratio(3, 100);
/// Officers on foot go back to the car when the target is this far from
/// it (ours).
pub const back_to_car_dist: Fx = fx.fromInt(10);
/// An officer within this distance of the car gets in (ours).
pub const board_dist: Fx = fx.one;
/// Box-in offsets from the target car: beside, ahead, and the block point
/// (ours).
pub const side_off: Fx = fx.ratio(3, 2);
pub const behind_off: Fx = fx.one;
pub const ahead_off: Fx = fx.fromInt(3);
pub const block_off: Fx = fx.ratio(5, 2);
/// Close enough to a box-in point to take the next step (ours).
pub const step_dist: Fx = fx.ratio(3, 4);
/// Ticks a crew waits for a free side before ramming (ours: the note says
/// longer at lower heat, much shorter with several pursuers or high heat).
pub const ram_patience_low: u16 = 150;
pub const ram_patience_high: u16 = 50;
/// FBI hold back from ramming: patience times this (ours).
pub const fbi_patience_mul: u16 = 3;
/// Ticks of chasing without catching up before the crew rams instead
/// (ours: "the target is simply too fast").
pub const too_fast_ticks: u16 = 200;
/// Flat extra damage of a deliberate ram (notes: police-ai.md 5), and the
/// ticks before the same crew's ram counts again (ours).
pub const ram_damage: i32 = 500;
pub const ram_cooldown: u16 = 30;
/// On-foot search at the last known position (notes: police-ai.md 5).
pub const search_wait: u16 = 200;
/// Leash for a searching crew (notes: ~5 blocks; applied to every tier,
/// police-ai.md 3.3's reading).
pub const search_leash: Fx = fx.fromInt(5);
/// Ticks the car taking an arrested player's double away stays a crew
/// before the double is gone with it (ours).
pub const escort_ticks: u16 = 150;

// --- Roadblocks (police-ai.md 3.4) ----------------------------------------

/// Roadblocks live at once and from what tier (notes: police-ai.md 5).
pub const max_roadblocks = 2;
pub const roadblock_min_stars: u8 = 3;
/// Widest road a roadblock spans, and the most vehicles, guards and
/// barriers in one (notes).
pub const roadblock_max_lanes = 12;
pub const roadblock_max_cars = 6;
pub const roadblock_max_guards = 6;
pub const roadblock_max_barriers = 12;
/// Ticks between roadblock attempts (ours: the note says there is a
/// cooldown, not how long).
pub const roadblock_cooldown: u16 = 600;
/// Teardown: unseen this long (notes) and the player at least this far away
/// (ours: "well away").
pub const roadblock_unseen_ticks: u16 = 200;
pub const roadblock_far: i32 = 20;
/// Object model for a barrier (B's `barrier` kind: model 0 is a solid box
/// one block long along its heading; the objects note isn't written).
pub const barrier_model: u8 = 0;

/// Ticks between police voice lines on one pursuit, shouts and radio
/// together (ours: the notes have no voice timing).
pub const voice_gap: u16 = 90;
