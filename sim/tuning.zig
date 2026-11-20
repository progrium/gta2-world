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
//
// Our own set, tuned by feel: nothing here came from the original game.

pub const WeaponDef = struct {
    /// Ticks between shots while fire is held.
    cooldown: u16,
    /// Damage per projectile on a direct hit (0 for explosive rounds).
    damage: u16,
    speed: Fx,
    /// Lifetime of a projectile in ticks (range = speed x ttl).
    ttl: u16,
    /// Projectiles per shot, fanned across `spread` (angle units).
    pellets: u8,
    spread: u16,
    /// Random aim error per shot, up to this many angle units either way.
    jitter: u16,
    /// Explodes where it lands instead of hitting one body.
    explosive: bool,
    /// Rounds a pickup gives, and the most a ped can carry.
    pickup_ammo: u16,
    max_ammo: u16,
};

pub const weapon_pistol: u8 = 0;
pub const weapon_smg: u8 = 1;
pub const weapon_shotgun: u8 = 2;
pub const weapon_rocket: u8 = 3;
pub const weapon_count = 4;
/// `Weapon.kind` on a health pickup.
pub const pickup_health: u8 = 4;
pub const pickup_kinds = 5;
pub const infinite_ammo: u16 = 0xFFFF;

pub const weapons = [weapon_count]WeaponDef{
    // Pistol: always in hand, never runs out.
    .{ .cooldown = 8, .damage = 25, .speed = fx.ratio(9, 10), .ttl = 30, .pellets = 1, .spread = 0, .jitter = 0, .explosive = false, .pickup_ammo = 0, .max_ammo = infinite_ammo },
    // Machine gun: fast, light, a little wild.
    .{ .cooldown = 3, .damage = 12, .speed = fx.ratio(1, 1), .ttl = 24, .pellets = 1, .spread = 0, .jitter = 700, .explosive = false, .pickup_ammo = 80, .max_ammo = 240 },
    // Shotgun: six pellets in a fan, short range.
    .{ .cooldown = 24, .damage = 16, .speed = fx.ratio(8, 10), .ttl = 10, .pellets = 6, .spread = 4200, .jitter = 300, .explosive = false, .pickup_ammo = 12, .max_ammo = 40 },
    // Rocket launcher: slow rocket, explodes on contact or at the end.
    .{ .cooldown = 36, .damage = 0, .speed = fx.ratio(4, 10), .ttl = 70, .pellets = 1, .spread = 0, .jitter = 0, .explosive = true, .pickup_ammo = 4, .max_ammo = 12 },
};

/// Explosions: full damage out to `explosion_core`, falling to zero at the
/// radius (larger for a car), and a push away from the centre.
pub const explosion_radius = fx.ratio(2, 1);
pub const car_explosion_radius = fx.ratio(25, 10);
pub const explosion_core = fx.ratio(9, 10);
pub const explosion_damage: i32 = 300;
pub const explosion_push = fx.ratio(25, 100);

// --- Pickups -----------------------------------------------------------------

/// Pickups on the map: this many, plus `pickups_per_player` per active
/// player, placed on pavement near a random player.
pub const pickups_base: u32 = 2;
pub const pickups_per_player: u32 = 2;
pub const pickup_near_radius: i32 = 14;
pub const pickup_near_min: i32 = 3;
/// A pickup nobody takes disappears after this many ticks (60 s).
pub const pickup_life: u16 = 1800;
pub const pickup_reach = fx.ratio(6, 10);
pub const health_pickup_hp: i32 = 50;
/// Odds of each pickup kind, out of 100: machine gun, shotgun, rockets, health.
pub const pickup_odds = [pickup_kinds]u32{ 0, 35, 25, 15, 25 };

// --- Cars on fire -----------------------------------------------------------

/// Below this much health a car catches fire, then loses `burn_rate` a tick
/// until it explodes (about 3 s from catching).
pub const car_burn_hp: i32 = 100;
pub const car_burn_rate: i32 = 1;
/// A burnt-out wreck stays for this many ticks (10 s).
pub const wreck_ticks: u16 = 300;
/// `Appearance.remap` of a burnt-out wreck (a dark palette in the style).
pub const wreck_remap: u16 = 0;

// --- Traffic -----------------------------------------------------------------

/// Of the ambient cars, this many in 8 drive (the rest are parked).
pub const traffic_8ths: u32 = 5;
pub const traffic_speed = fx.ratio(17, 100); // about 5 blocks per second
/// The look-ahead box for braking: from the car's centre, this far along the
/// lane and this far either side of it.
pub const traffic_look = fx.ratio(19, 10);
pub const traffic_look_side = fx.ratio(55, 100);
/// Ticks without moving (and nothing in the way) before backing out, and
/// ticks spent backing out.
pub const traffic_stuck_ticks: u16 = 45;
pub const traffic_reverse_ticks: u16 = 25;

// --- Ambient population near players ---------------------------------------

/// Ambient cars and peds this far (blocks, Chebyshev) from every player are
/// moved: despawned and replaced between `ambient_near_min` and
/// `ambient_near_radius` blocks of a random player.
pub const ambient_far: i32 = 36;
pub const ambient_near_radius: i32 = 26;
pub const ambient_near_min: i32 = 14;
/// At most this many are moved per tick.
pub const ambient_moves_per_tick: u32 = 2;

// --- Scoring -----------------------------------------------------------------

/// First to this many kills wins the round; scores then reset.
pub const frag_limit: i32 = 10;

// --- Health and respawn ---------------------------------------------------

pub const respawn_ticks: u32 = 90;
/// A player (joining or respawning) appears on pavement within this many
/// blocks of another active player, and at least `spawn_near_min` away,
/// when such a spot exists; otherwise anywhere on pavement.
pub const spawn_near_radius: i32 = 12;
pub const spawn_near_min: i32 = 3;
pub const wreck_driver_damage: i32 = 60;
/// Closing speed above which a contact hurts, and damage per block/tick.
pub const impact_threshold = fx.ratio(1, 10);
pub const impact_damage: i32 = 120;
