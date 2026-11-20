//! Constant tuning: per-kind and per-model numbers that are not state, so
//! they cost no save or snapshot bytes. Units: blocks, blocks per tick and
//! binary angle units per tick, at 30 ticks per second.
//!
//! Numbers marked "notes" come from the clean-room behaviour notes in
//! docs/behaviour/ (the file named beside them); GTA2 also runs at 30 ticks
//! per second, so tick counts carry over unchanged. Unmarked numbers are our
//! own, tuned by feel. Nothing here was taken from the original game's
//! executable or its decompilation.
//!
//! The car models and the on-foot speeds are `var`s so a local, offline host
//! (the browser build's tuning panel) can change them between ticks. Every
//! networked or recorded host must leave them at their defaults: they are
//! not part of the state, so changing them on one side only would desync.

const std = @import("std");
const fx = @import("fixed.zig");
const Fx = fx.Fx;

// --- Pedestrians (notes: ped-movement.md) --------------------------------

/// Half the 0.2 x 0.2 block collision square.
pub const ped_radius = fx.ratio(1, 10);
/// Collision height.
pub const ped_height = fx.ratio(1, 4);
/// Mass for impacts (car-collision.md).
pub const ped_mass = fx.half;
pub const ped_hp: i32 = 100;
/// The one running pace, forward and back: 1/16 block per tick. GTA2 has no
/// separate walk or run; `ped_run` exists for the tuning panel and is the
/// same by default.
pub var ped_walk = fx.ratio(1, 16);
pub var ped_run = fx.ratio(1, 16);
pub var ped_back = fx.ratio(1, 16);
/// Tank turning builds up by this many angle units a tick (11 of 1440
/// steps), to at most `ped_turn_max` (48 steps, 12 degrees); faster build-up
/// while aiming (fire held, not moving forward); slower in a jump.
pub var ped_tank_turn: i32 = 501;
pub const ped_turn_aim: i32 = 546;
pub const ped_turn_max: i32 = 2185;
pub const ped_turn_jump: i32 = 182;
pub const ped_turn_jump_max: i32 = 1092;
/// Direct mode (our addition for sticks): turn rate toward the aim heading.
pub var ped_direct_turn: i32 = 4000;
/// A jump: this many ticks moving forward at the run pace, at the take-off
/// height (GTA2 jumps do not leave the ground; 8 animation frames, frame
/// length not in the notes, so ours). `ped_jump_vz` is unused and kept for
/// the tuning panel.
pub const ped_jump_ticks: u8 = 16;
pub var ped_jump_vz = fx.ratio(15, 100);
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

/// One car model's handling (car-handling.md). Hosts build these with
/// `deriveModel` from the player's `.gci` and style car info; without them
/// every car uses `default_car_models[0]`. All fixed point unless noted.
pub const CarModel = struct {
    /// Half extents of the body box (the sprite): along the heading and
    /// across it.
    half_len: Fx,
    half_wid: Fx,
    /// Radius used against other bodies (peds, cars).
    radius: Fx,
    /// .gci mass x 1.1 (a player driver adds another 5% while driving).
    mass: Fx,
    /// Scales the raw damage of every hit (the .gci's 15th field); 0 is
    /// indestructible.
    anti_strength: Fx,
    /// Plain integers: turbo (0 or 1); a sprite longer than 64 pixels (0 or
    /// 1, halves the arrow snap); `sprite` within the car sprite group;
    /// `ambient` (0 or 1) may appear as traffic or parked.
    turbo: i32,
    long: i32,
    sprite: i32,
    ambient: i32,
    front_drive_bias: Fx,
    brake_friction: Fx,
    turn_in: Fx,
    turn_ratio: Fx,
    rear_end_stability: Fx,
    handbrake_slide: Fx,
    thrust: Fx,
    max_speed: Fx,
    gear1: Fx,
    gear2: Fx,
    gear3: Fx,
    gear2_speed: Fx,
    gear3_speed: Fx,
    /// Axle positions along the length, from the centre of mass (front
    /// positive), and the moment of inertia.
    front_axle: Fx,
    rear_axle: Fx,
    inertia: Fx,
    /// Bounce off walls: fraction of the normal speed kept, in 1/8ths.
    restitution_8ths: i32,
};

/// What `deriveModel` takes: one `.gci` record's numbers (16.16) and the
/// style's car info (pixels, 64 to a block).
pub const CarSpec = struct {
    mass: Fx,
    front_drive_bias: Fx,
    front_mass_bias: Fx,
    brake_friction: Fx,
    turn_in: Fx,
    turn_ratio: Fx,
    rear_end_stability: Fx,
    handbrake_slide: Fx,
    thrust: Fx,
    max_speed: Fx,
    anti_strength: Fx,
    gear1: Fx,
    gear2: Fx,
    gear3: Fx,
    gear2_speed: Fx,
    gear3_speed: Fx,
    turbo: bool,
    w_px: i32,
    h_px: i32,
    front_wheel_px: i32,
    rear_wheel_px: i32,
    sprite: i32 = 0,
    ambient: bool = true,
};

/// The derived per-model values (car-handling.md, "Values derived once per
/// model at load"): mass x 1.1; the car as two half slabs, front mass
/// share b, for the centre of mass and moment of inertia; axles at the
/// wheel offsets.
pub fn deriveModel(sp: CarSpec) CarModel {
    const w = sp.w_px * 1024;
    const h = sp.h_px * 1024;
    const m = fx.mul(sp.mass, fx.ratio(11, 10));
    const mf = fx.mul(m, sp.front_mass_bias);
    const mr = m - mf;
    const q = h >> 2;
    const yc = if (m == 0) 0 else fx.div(fx.mul(q, mf - mr), m);
    const slab = @divTrunc(fx.mul(w, w) + fx.mul(h >> 1, h >> 1), 12);
    const df = yc - q;
    const dr = yc + q;
    const inertia = fx.mul(mf, slab) + fx.mul(mf, fx.mul(df, df)) + fx.mul(mr, slab) + fx.mul(mr, fx.mul(dr, dr));
    return .{
        .half_len = h >> 1,
        .half_wid = w >> 1,
        .radius = @divTrunc((h >> 1) + (w >> 1), 2) + fx.ratio(5, 100),
        .mass = m,
        .anti_strength = sp.anti_strength,
        .turbo = @intFromBool(sp.turbo),
        .long = @intFromBool(sp.h_px > 64),
        .sprite = sp.sprite,
        .ambient = @intFromBool(sp.ambient),
        .front_drive_bias = sp.front_drive_bias,
        .brake_friction = sp.brake_friction,
        .turn_in = sp.turn_in,
        .turn_ratio = sp.turn_ratio,
        .rear_end_stability = sp.rear_end_stability,
        .handbrake_slide = sp.handbrake_slide,
        .thrust = sp.thrust,
        .max_speed = sp.max_speed,
        .gear1 = sp.gear1,
        .gear2 = sp.gear2,
        .gear3 = sp.gear3,
        .gear2_speed = sp.gear2_speed,
        .gear3_speed = sp.gear3_speed,
        .front_axle = sp.front_wheel_px * 1024 - yc,
        .rear_axle = sp.rear_wheel_px * 1024 - yc,
        .inertia = @max(inertia, fx.ratio(1, 16)),
        .restitution_8ths = wall_restitution_8ths,
    };
}

/// Model 0 without the player's files: a mid-range saloon (our numbers, in
/// the range of the .gci's ordinary cars).
pub const default_spec: CarSpec = .{
    .mass = fx.ratio(155, 10),
    .front_drive_bias = fx.ratio(6, 10),
    .front_mass_bias = fx.half,
    .brake_friction = fx.ratio(175, 100),
    .turn_in = fx.ratio(3, 10),
    .turn_ratio = fx.ratio(42, 100),
    .rear_end_stability = fx.ratio(13, 10),
    .handbrake_slide = fx.ratio(2, 10),
    .thrust = fx.ratio(18, 100),
    .max_speed = fx.ratio(32, 100),
    .anti_strength = fx.one,
    .gear1 = fx.ratio(55, 100),
    .gear2 = fx.ratio(7, 10),
    .gear3 = fx.one,
    .gear2_speed = fx.ratio(12, 100),
    .gear3_speed = fx.ratio(2, 10),
    .turbo = false,
    .w_px = 32,
    .h_px = 64,
    .front_wheel_px = 20,
    .rear_wheel_px = -18,
};

pub const max_car_models = 96;

pub const default_car_models = [1]CarModel{deriveModel(default_spec)};

pub var car_models: [max_car_models]CarModel = @splat(default_car_models[0]);
pub var car_model_count: u32 = 1;

pub fn carModel(m: u8) *const CarModel {
    return &car_models[if (m < car_model_count) m else 0];
}

/// Install the models a host built (at most `max_car_models`), or go back
/// to the default with an empty slice. Every host in a session must
/// install the same list.
pub fn setCarModels(models: []const CarModel) void {
    const n = @min(models.len, max_car_models);
    if (n == 0) {
        car_models = @splat(default_car_models[0]);
        car_model_count = 1;
        return;
    }
    @memcpy(car_models[0..n], models[0..n]);
    car_model_count = @intCast(n);
}

/// Hash of the installed models, so hosts can check they agree.
pub fn carModelsHash() u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(car_models[0..car_model_count]));
}

// --- Car physics constants (car-handling.md) -------------------------------

/// Gas pedal 0-5, moving 0.25 a tick (kept in quarters, 0-20); turbo from 3.
pub const pedal_quarters_max: u8 = 20;
pub const turbo_quarters: u8 = 12;
/// Foot brake pressure 0-1 in quarters; handbrake ramp over 128 ticks.
pub const brake_quarters_max: u8 = 4;
pub const handbrake_ramp: u8 = 128;
/// Steering angle for a player: turn ratio x max(0.25, 0.6 - speed) / 0.48.
pub const steer_speed_ref = fx.ratio(6, 10);
pub const steer_speed_min = fx.ratio(25, 100);
pub const steer_div = fx.ratio(48, 100);
/// Rear axle angle: - steering x (0.6 - speed) / 2.28.
pub const rear_steer_div = fx.ratio(228, 100);
pub const rolling_drag = fx.ratio(139, 1000);
pub const front_brake_share = fx.ratio(8, 10);
pub const rear_brake_share = fx.ratio(2, 10);
/// Velocity and spin dead zones, and the damping per tick.
pub const dead_zone = fx.ratio(1, 256);
pub const slow_zone = fx.ratio(1, 128);
pub const damp_lateral = fx.ratio(9, 10);
pub const damp_long = fx.ratio(97, 100);
pub const damp_spin = fx.ratio(88, 100);
pub const damp_lateral_air = fx.ratio(95, 100);
pub const damp_long_air = fx.ratio(985, 1000);
pub const damp_spin_air = fx.ratio(94, 100);
/// Player drivers make the car 5% heavier.
pub const player_mass = fx.ratio(105, 100);
/// Arrow snap: within 25 degrees of the lane; at most 0.26 x speed (0.13
/// for long cars) radians a tick.
pub const snap_window: u16 = 4551;
pub const snap_rate = fx.ratio(26, 100);
/// Radians to angle units, with the original's 0.7% over-rotation (it
/// divides by 71 where 71.5 would be exact): 65536 / 2 pi x 71.5 / 71.
pub const rad_to_angle: i64 = 10504;

// --- Weapons (notes: weapons.md, projectiles.md) --------------------------

pub const WeaponDef = struct {
    /// Ticks between trigger pulls while fire is held.
    cooldown: u16,
    /// Damage per projectile to a player's ped, and to anyone else.
    damage_player: u16,
    damage_other: u16,
    /// Raw damage to a car (before anti-strength).
    damage_car: u16,
    speed: Fx,
    /// Lifetime of a projectile in ticks (range = speed x ttl).
    ttl: u16,
    /// Projectiles per pull, `spread` angle units apart, centred on the aim.
    pellets: u8,
    spread: u16,
    /// Explodes (a small explosion) on whatever it touches.
    explosive: bool,
    /// Ammo is kept in tenths of a displayed round; each pull spends this.
    tenths_per_pull: u8,
    /// Displayed rounds a pickup gives (ours: the notes leave pickups to a
    /// future note).
    pickup_rounds: u16,
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
/// Most ammo held for any weapon: 99 displayed rounds, in tenths.
pub const max_ammo_tenths: u16 = 990;
/// 6 degrees in angle units.
const deg6: u16 = 1092;

pub const weapons = [weapon_count]WeaponDef{
    // Pistol: the player's own bullet, twice the damage of others.
    .{ .cooldown = 20, .damage_player = 20, .damage_other = 50, .damage_car = 1600, .speed = fx.ratio(2, 10), .ttl = 25, .pellets = 1, .spread = 0, .explosive = false, .tenths_per_pull = 10, .pickup_rounds = 0 },
    // Machine gun: a bullet every 2 ticks; a displayed round is 10 shots.
    .{ .cooldown = 2, .damage_player = 10, .damage_other = 25, .damage_car = 800, .speed = fx.ratio(2, 10), .ttl = 25, .pellets = 1, .spread = 0, .explosive = false, .tenths_per_pull = 1, .pickup_rounds = 30 },
    // Shotgun: five pellets at 0, +-6 and +-12 degrees, short range.
    .{ .cooldown = 40, .damage_player = 10, .damage_other = 25, .damage_car = 800, .speed = fx.ratio(4, 10), .ttl = 8, .pellets = 5, .spread = deg6, .explosive = false, .tenths_per_pull = 10, .pickup_rounds = 15 },
    // Rocket launcher: wrecks a car outright, small explosion on contact.
    .{ .cooldown = 50, .damage_player = 10, .damage_other = 25, .damage_car = 32000, .speed = fx.ratio(4, 10), .ttl = 50, .pellets = 1, .spread = 0, .explosive = true, .tenths_per_pull = 10, .pickup_rounds = 6 },
};

/// Shots start this far in front of the shooter; the point halfway there
/// must be clear of walls or the shot is not fired.
pub const muzzle_ahead = fx.ratio(1, 4);
/// Added to a body's radius when a projectile is tested against it (ours:
/// a bullet's own size).
pub const shot_radius = fx.ratio(1, 16);
/// Shots fly this far above the shooter's feet (ours: about a ped's middle).
pub const shot_height = fx.ratio(1, 8);

// --- Explosions (notes: explosions-and-damage.md) ---------------------------

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

// --- Car damage (notes: car-collision.md, explosions-and-damage.md) --------

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
/// Closing speeds below this do no damage (ours: so a car pushing on a wall
/// or another car is not ground down; the notes' dent threshold for walls).
pub const impact_min_speed = fx.ratio(3, 100);
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
/// Health pickups restore full health (power-ups-death-and-arrest.md).
/// Odds of each pickup kind, out of 100: machine gun, shotgun, rockets, health.
pub const pickup_odds = [pickup_kinds]u32{ 0, 35, 25, 15, 25 };

// --- Wrecks -----------------------------------------------------------------

/// A burnt-out wreck stays for this many ticks (10 s), then a new traffic
/// car appears elsewhere.
pub const wreck_ticks: u16 = 300;
/// `Appearance.remap` of a burnt-out wreck (a dark palette in the style).
pub const wreck_remap: u16 = 0;

// --- Traffic (notes: traffic-and-car-ai.md) --------------------------------

/// Of the ambient cars, this many in 8 drive (the rest are parked; ours).
pub const traffic_8ths: u32 = 5;
/// Speed setting: default target 0.1 a tick, rising 0.01 a tick, falling
/// 0.08 a tick when above the target.
pub const traffic_speed = fx.ratio(1, 10);
pub const traffic_accel = fx.ratio(1, 100);
pub const traffic_decel = fx.ratio(8, 100);
/// Look-ahead: 1.75 blocks ahead (1 while turning), then 1.
pub const traffic_look = fx.ratio(175, 100);
pub const traffic_look_turning = fx.one;
pub const traffic_look_side = fx.ratio(45, 100);
/// Above this speed a car braking for something ahead also uses the
/// handbrake.
pub const traffic_handbrake_speed = fx.ratio(4, 10);
/// Ticks an AI driver stops for after hitting a pedestrian.
pub const traffic_hit_stop: u16 = 100;
/// Junction probe: how far ahead the straight-on check looks.
pub const traffic_junction_probe = fx.ratio(8, 10);
/// Ticks spent backing out once blocked at a standstill (the notes back out
/// until reversing speed reaches the setting; ours bounds it).
pub const traffic_reverse_ticks: u16 = 25;
pub const traffic_stuck_ticks: u16 = 10;

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

/// The "wasted" countdown before respawning (power-ups-death-and-arrest.md).
pub const respawn_ticks: u32 = 70;
/// A player (joining or respawning) appears on pavement within this many
/// blocks of another active player, and at least `spawn_near_min` away,
/// when such a spot exists; otherwise anywhere on pavement.
pub const spawn_near_radius: i32 = 12;
pub const spawn_near_min: i32 = 3;

