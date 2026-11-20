//! Constant tuning: per-kind and per-model numbers that are not state, so
//! they cost no save or snapshot bytes. Units: blocks, blocks per tick and
//! binary angle units per tick, at 30 ticks per second.
//!
//! The car numbers are a placeholder handling model of our own, tuned by
//! feel. Authentic GTA2 handling comes later from clean-room behaviour notes;
//! nothing here was taken from the original game or its decompilation.
//!
//! The car models and the on-foot speeds are `var`s so a local, offline host
//! (the browser build's tuning panel) can change them between ticks. Every
//! networked or recorded host must leave them at their defaults: they are
//! not part of the state, so changing them on one side only would desync.

const fx = @import("fixed.zig");
const Fx = fx.Fx;

// --- Pedestrians -----------------------------------------------------------

pub const ped_radius = fx.ratio(3, 16);
pub const ped_mass: i32 = 1;
pub const ped_hp: i32 = 100;
/// Walking and running speed (blocks per tick). 0.06 is 1.8 blocks/s.
pub var ped_walk = fx.ratio(6, 100);
pub var ped_run = fx.ratio(11, 100);
/// Backward walking in tank mode is slower.
pub var ped_back = fx.ratio(4, 100);
/// Tank mode turn rate at full steer (about 230 degrees per second).
pub var ped_tank_turn: i32 = 1400;
/// Direct mode turn rate toward the aim heading (about 650 degrees per second).
pub var ped_direct_turn: i32 = 4000;
/// Jump take-off speed and the ticks before another jump.
pub var ped_jump_vz = fx.ratio(15, 100);
pub const ped_jump_cooldown: u8 = 20;
/// How far a ped reaches to get into a car (centre to centre), and the
/// fastest a car may be moving to be entered.
pub const enter_reach = fx.ratio(3, 2);
pub const enter_max_speed = fx.ratio(8, 100);

// --- Bodies ------------------------------------------------------------------

pub const gravity = fx.ratio(15, 1000);
pub const max_fall = fx.ratio(6, 10);
/// A grounded body follows the floor down by up to this much per tick
/// (driving down a ramp); further than that it falls.
pub const snap_down = fx.ratio(3, 10);
/// Step heights: a ped climbs 5/16 of a block, a car 7/10 (so its corners
/// do not catch at the top of a ramp). A full block always blocks.
pub const ped_step = fx.ratio(5, 16);
pub const car_step = fx.ratio(7, 10);
/// Largest move per physics sub-step, so nothing tunnels through a block.
pub const max_substep = fx.ratio(1, 4);

// --- Cars --------------------------------------------------------------------

pub const CarModel = struct {
    /// Half extents of the body box: along the heading and across it.
    half_len: Fx,
    half_wid: Fx,
    /// Radius used against other bodies (peds, cars).
    radius: Fx,
    mass: i32,
    hp: i32,
    /// Top speed forward and in reverse.
    max_speed: Fx,
    max_reverse: Fx,
    /// Acceleration at full pedal from rest; it tapers to zero at top speed.
    accel: Fx,
    /// Braking deceleration at full pedal against the motion.
    brake: Fx,
    /// Fraction of speed lost per tick to drag, as a shift (v -= v >> n).
    drag_shift: u5,
    /// Coasting deceleration with no pedal.
    coast: Fx,
    /// Most lateral speed the tyres can remove per tick. Above it, the car
    /// slides: this is the whole drift model.
    grip: Fx,
    /// Grip with the handbrake on.
    handbrake_grip: Fx,
    /// Yaw per tick at full lock, per block/tick of forward speed, and its cap.
    steer_gain: i32,
    max_yaw: i32,
    /// Extra yaw with the handbrake on, as a multiplier in 1/8ths.
    handbrake_yaw_8ths: i32,
    /// How fast the pedal and the front wheels follow input, per tick (of 127).
    pedal_rate: i32,
    steer_rate: i32,
    /// Bounce off walls: fraction of the normal speed kept, in 1/8ths.
    restitution_8ths: i32,
};

/// Model 0: a generic saloon. All cars use it until real handling arrives.
pub const default_car_models = [_]CarModel{.{
    .half_len = fx.ratio(56, 100),
    .half_wid = fx.ratio(27, 100),
    .radius = fx.ratio(42, 100),
    .mass = 12,
    .hp = 400,
    .max_speed = fx.ratio(42, 100), // about 13 blocks per second
    .max_reverse = fx.ratio(12, 100),
    .accel = fx.ratio(24, 1000),
    .brake = fx.ratio(20, 1000),
    .drag_shift = 8,
    .coast = fx.ratio(4, 1000),
    .grip = fx.ratio(22, 1000),
    .handbrake_grip = fx.ratio(5, 1000),
    .steer_gain = 7000,
    .max_yaw = 1150, // about 190 degrees per second
    .handbrake_yaw_8ths = 12,
    .pedal_rate = 32,
    .steer_rate = 40,
    .restitution_8ths = 2,
}};

pub var car_models = default_car_models;

pub fn carModel(m: u8) *const CarModel {
    return &car_models[if (m < car_models.len) m else 0];
}

// --- Weapons -----------------------------------------------------------------

pub const pistol_cooldown: u16 = 8;
pub const pistol_damage: u16 = 25;
pub const projectile_speed = fx.ratio(9, 10);
pub const projectile_ttl: u16 = 30;
pub const player_ammo: u32 = 99;

// --- Health and respawn ---------------------------------------------------

pub const respawn_ticks: u32 = 90;
pub const wreck_driver_damage: i32 = 60;
/// Closing speed above which a contact hurts, and damage per block/tick.
pub const impact_threshold = fx.ratio(1, 10);
pub const impact_damage: i32 = 120;
