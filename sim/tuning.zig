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

const t_peds = @import("tuning/peds.zig");
const t_bodies = @import("tuning/bodies.zig");
const t_cars = @import("tuning/cars.zig");
const t_weapons = @import("tuning/weapons.zig");
const t_explosions = @import("tuning/explosions.zig");
const t_damage = @import("tuning/damage.zig");
const t_pickups = @import("tuning/pickups.zig");
const t_traffic = @import("tuning/traffic.zig");
const t_ambient = @import("tuning/ambient.zig");
const t_scoring = @import("tuning/scoring.zig");
const t_respawn = @import("tuning/respawn.zig");

// --- peds.zig
pub const ped_radius = t_peds.ped_radius;
pub const ped_height = t_peds.ped_height;
pub const ped_mass = t_peds.ped_mass;
pub const ped_hp = t_peds.ped_hp;
pub const ped_turn_aim = t_peds.ped_turn_aim;
pub const ped_turn_max = t_peds.ped_turn_max;
pub const ped_turn_jump = t_peds.ped_turn_jump;
pub const ped_turn_jump_max = t_peds.ped_turn_jump_max;
pub const ped_jump_ticks = t_peds.ped_jump_ticks;
pub const ped_jump_cooldown = t_peds.ped_jump_cooldown;
pub const ped_slide_shift = t_peds.ped_slide_shift;
pub const ped_gravity = t_peds.ped_gravity;
pub const ped_max_fall = t_peds.ped_max_fall;
pub const fall_damage = t_peds.fall_damage;
pub const knock_over_ticks = t_peds.knock_over_ticks;
pub const knock_down_ticks = t_peds.knock_down_ticks;
pub const thrown_gravity = t_peds.thrown_gravity;
pub const thrown_friction = t_peds.thrown_friction;
pub const enter_reach = t_peds.enter_reach;
pub const enter_ahead = t_peds.enter_ahead;
pub const enter_max_speed = t_peds.enter_max_speed;
pub const exit_max_speed = t_peds.exit_max_speed;

// --- bodies.zig
pub const gravity = t_bodies.gravity;
pub const max_fall = t_bodies.max_fall;
pub const car_gravity = t_bodies.car_gravity;
pub const car_max_fall = t_bodies.car_max_fall;
pub const car_drop = t_bodies.car_drop;
pub const car_tip_div = t_bodies.car_tip_div;
pub const sink_speed = t_bodies.sink_speed;
pub const sink_px_per_tick = t_bodies.sink_px_per_tick;
pub const drown_credit_ticks = t_bodies.drown_credit_ticks;
pub const electric_floor_shock = t_bodies.electric_floor_shock;
pub const oil_ticks = t_bodies.oil_ticks;
pub const oil_damage = t_bodies.oil_damage;
pub const oil_axle_angle = t_bodies.oil_axle_angle;
pub const slope_rollback = t_bodies.slope_rollback;
pub const car_ceiling = t_bodies.car_ceiling;
pub const snap_down = t_bodies.snap_down;
pub const ped_step = t_bodies.ped_step;
pub const car_step = t_bodies.car_step;
pub const max_substep = t_bodies.max_substep;

// --- cars.zig
pub const CarModel = t_cars.CarModel;
pub const CarSpec = t_cars.CarSpec;
pub const deriveModel = t_cars.deriveModel;
pub const default_car_value = t_cars.default_car_value;
pub const default_spec = t_cars.default_spec;
pub const max_car_models = t_cars.max_car_models;
pub const default_car_models = t_cars.default_car_models;
pub const pedal_quarters_max = t_cars.pedal_quarters_max;
pub const turbo_quarters = t_cars.turbo_quarters;
pub const brake_quarters_max = t_cars.brake_quarters_max;
pub const handbrake_ramp = t_cars.handbrake_ramp;
pub const steer_speed_ref = t_cars.steer_speed_ref;
pub const steer_speed_min = t_cars.steer_speed_min;
pub const steer_div = t_cars.steer_div;
pub const rear_steer_div = t_cars.rear_steer_div;
pub const rolling_drag = t_cars.rolling_drag;
pub const front_brake_share = t_cars.front_brake_share;
pub const rear_brake_share = t_cars.rear_brake_share;
pub const dead_zone = t_cars.dead_zone;
pub const slow_zone = t_cars.slow_zone;
pub const damp_lateral = t_cars.damp_lateral;
pub const damp_long = t_cars.damp_long;
pub const damp_spin = t_cars.damp_spin;
pub const damp_lateral_air = t_cars.damp_lateral_air;
pub const damp_long_air = t_cars.damp_long_air;
pub const damp_spin_air = t_cars.damp_spin_air;
pub const player_mass = t_cars.player_mass;
pub const snap_window = t_cars.snap_window;
pub const snap_rate = t_cars.snap_rate;
pub const rad_to_angle = t_cars.rad_to_angle;

// --- weapons.zig
pub const WeaponDef = t_weapons.WeaponDef;
pub const shot_bullet = t_weapons.shot_bullet;
pub const shot_flame = t_weapons.shot_flame;
pub const shot_electro = t_weapons.shot_electro;
pub const shot_grenade = t_weapons.shot_grenade;
pub const shot_molotov = t_weapons.shot_molotov;
pub const weapon_pistol = t_weapons.weapon_pistol;
pub const weapon_smg = t_weapons.weapon_smg;
pub const weapon_shotgun = t_weapons.weapon_shotgun;
pub const weapon_rocket = t_weapons.weapon_rocket;
pub const weapon_dual_pistol = t_weapons.weapon_dual_pistol;
pub const weapon_silenced = t_weapons.weapon_silenced;
pub const weapon_flamethrower = t_weapons.weapon_flamethrower;
pub const weapon_electro = t_weapons.weapon_electro;
pub const weapon_grenade = t_weapons.weapon_grenade;
pub const weapon_molotov = t_weapons.weapon_molotov;
pub const weapon_count = t_weapons.weapon_count;
pub const pickup_health = t_weapons.pickup_health;
pub const pickup_armour = t_weapons.pickup_armour;
pub const pickup_invulnerable = t_weapons.pickup_invulnerable;
pub const pickup_double_damage = t_weapons.pickup_double_damage;
pub const pickup_fast_reload = t_weapons.pickup_fast_reload;
pub const pickup_kinds = t_weapons.pickup_kinds;
pub const infinite_ammo = t_weapons.infinite_ammo;
pub const max_ammo_tenths = t_weapons.max_ammo_tenths;
pub const weapons = t_weapons.weapons;
pub const charge_max = t_weapons.charge_max;
pub const throw_strength_max = t_weapons.throw_strength_max;
pub const grenade_in_hand = t_weapons.grenade_in_hand;
pub const throw_height = t_weapons.throw_height;
pub const throw_rise = t_weapons.throw_rise;
pub const throw_gravity = t_weapons.throw_gravity;
pub const grenade_speed_base = t_weapons.grenade_speed_base;
pub const grenade_speed_span = t_weapons.grenade_speed_span;
pub const molotov_speed_base = t_weapons.molotov_speed_base;
pub const molotov_speed_span = t_weapons.molotov_speed_span;
pub const throw_moving_bonus = t_weapons.throw_moving_bonus;
pub const throw_friction = t_weapons.throw_friction;
pub const grenadeFuse = t_weapons.grenadeFuse;
pub const bounce_8ths = t_weapons.bounce_8ths;
pub const burn_ticks = t_weapons.burn_ticks;
pub const burn_damage_player = t_weapons.burn_damage_player;
pub const burn_damage_other = t_weapons.burn_damage_other;
pub const fire_ticks = t_weapons.fire_ticks;
pub const fire_radius = t_weapons.fire_radius;
pub const fire_car_damage = t_weapons.fire_car_damage;
pub const explosion_fire = t_weapons.explosion_fire;
pub const shock_gun = t_weapons.shock_gun;
pub const shock_threshold = t_weapons.shock_threshold;
pub const electro_reach = t_weapons.electro_reach;
pub const electro_chain_reach = t_weapons.electro_chain_reach;
pub const electro_cone = t_weapons.electro_cone;
pub const electro_reach_z = t_weapons.electro_reach_z;
pub const armour_charges = t_weapons.armour_charges;
pub const invulnerable_ticks = t_weapons.invulnerable_ticks;
pub const double_damage_ticks = t_weapons.double_damage_ticks;
pub const fast_reload_ticks = t_weapons.fast_reload_ticks;
pub const muzzle_ahead = t_weapons.muzzle_ahead;
pub const shot_radius = t_weapons.shot_radius;
pub const shot_height = t_weapons.shot_height;

// --- explosions.zig
pub const explosion_ticks = t_explosions.explosion_ticks;
pub const explosion_active_above = t_explosions.explosion_active_above;
pub const explosion_small = t_explosions.explosion_small;
pub const explosion_car = t_explosions.explosion_car;
pub const explosion_reach_z = t_explosions.explosion_reach_z;
pub const blast_throw = t_explosions.blast_throw;
pub const blast_lift_close = t_explosions.blast_lift_close;
pub const blast_lift = t_explosions.blast_lift;
pub const blast_knock = t_explosions.blast_knock;
pub const explosion_knock_above = t_explosions.explosion_knock_above;
pub const blast_car_damage = t_explosions.blast_car_damage;

// --- damage.zig
pub const car_damage_max = t_damage.car_damage_max;
pub const car_fire_damage = t_damage.car_fire_damage;
pub const car_fire2_damage = t_damage.car_fire2_damage;
pub const car_burn_rate = t_damage.car_burn_rate;
pub const impact_damage = t_damage.impact_damage;
pub const wall_restitution_8ths = t_damage.wall_restitution_8ths;
pub const car_restitution_8ths = t_damage.car_restitution_8ths;
pub const impulse_min = t_damage.impulse_min;
pub const unstick_turn = t_damage.unstick_turn;
pub const unstick_push = t_damage.unstick_push;
pub const impact_min_speed = t_damage.impact_min_speed;
pub const car_hit_min = t_damage.car_hit_min;
pub const knock_lift_light = t_damage.knock_lift_light;
pub const knock_lift_mid = t_damage.knock_lift_mid;
pub const knock_light = t_damage.knock_light;
pub const knock_mid = t_damage.knock_mid;
pub const knock_hard = t_damage.knock_hard;
pub const wreck_ticks = t_damage.wreck_ticks;
pub const wreck_remap = t_damage.wreck_remap;

// --- pickups.zig
pub const pickups_base = t_pickups.pickups_base;
pub const pickups_per_player = t_pickups.pickups_per_player;
pub const pickup_near_radius = t_pickups.pickup_near_radius;
pub const pickup_near_min = t_pickups.pickup_near_min;
pub const pickup_life = t_pickups.pickup_life;
pub const pickup_reach = t_pickups.pickup_reach;
pub const pickup_odds = t_pickups.pickup_odds;

// --- traffic.zig
pub const traffic_8ths = t_traffic.traffic_8ths;
pub const traffic_speed = t_traffic.traffic_speed;
pub const traffic_accel = t_traffic.traffic_accel;
pub const traffic_decel = t_traffic.traffic_decel;
pub const traffic_look = t_traffic.traffic_look;
pub const traffic_look_turning = t_traffic.traffic_look_turning;
pub const traffic_look_side = t_traffic.traffic_look_side;
pub const traffic_handbrake_speed = t_traffic.traffic_handbrake_speed;
pub const traffic_hit_stop = t_traffic.traffic_hit_stop;
pub const traffic_junction_probe = t_traffic.traffic_junction_probe;
pub const traffic_reverse_ticks = t_traffic.traffic_reverse_ticks;
pub const traffic_stuck_ticks = t_traffic.traffic_stuck_ticks;

// --- ambient.zig
pub const ambient_far = t_ambient.ambient_far;
pub const ambient_near_radius = t_ambient.ambient_near_radius;
pub const ambient_near_min = t_ambient.ambient_near_min;
pub const ambient_moves_per_tick = t_ambient.ambient_moves_per_tick;

// --- scoring.zig
pub const frag_limit = t_scoring.frag_limit;
pub const points_player_weapon = t_scoring.points_player_weapon;
pub const points_player_run_over = t_scoring.points_player_run_over;
pub const points_player_electro = t_scoring.points_player_electro;
pub const points_civilian = t_scoring.points_civilian;
pub const combo_window = t_scoring.combo_window;
pub const combo_max = t_scoring.combo_max;
pub const destroy_value_factor = t_scoring.destroy_value_factor;
pub const damage_band_low = t_scoring.damage_band_low;
pub const damage_band_high = t_scoring.damage_band_high;

// --- respawn.zig
pub const respawn_ticks = t_respawn.respawn_ticks;
pub const spawn_near_radius = t_respawn.spawn_near_radius;
pub const spawn_near_min = t_respawn.spawn_near_min;

// --- Host-tunable values and the installed car models. These stay in this
// file because they are `var`s: an alias would copy them.

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

/// Direct mode (our addition for sticks): turn rate toward the aim heading.
pub var ped_direct_turn: i32 = 4000;

pub var ped_jump_vz = fx.ratio(15, 100);

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
