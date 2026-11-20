//! Tuning: Car models and handling constants (car-handling.md).
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;
const wall_restitution_8ths = @import("damage.zig").wall_restitution_8ths;

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
    /// The `.gci` value: points for stealing it, x5 for destroying it
    /// (scoring.md 3.3). Plain integer.
    value: i32,
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
    value: i32 = default_car_value,
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
        .value = sp.value,
    };
}

/// A car's value without the player's `.gci` (ours, in the range of the
/// ordinary cars' value bytes).
pub const default_car_value = 10;

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
