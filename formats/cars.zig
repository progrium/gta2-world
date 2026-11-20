//! Car models from the player's files: the style's car info (CARI) joined
//! to the `.gci` handling records by model number (car-handling.md,
//! "`.gci` car record"). The result is one `Spec` per style car entry, in
//! style order; the field names match `sim.tuning.CarSpec`, so a host can
//! copy them field by field.

const std = @import("std");
const sty = @import("sty.zig");
const gci = @import("gci.zig");

pub const Spec = struct {
    mass: i32,
    front_drive_bias: i32,
    front_mass_bias: i32,
    brake_friction: i32,
    turn_in: i32,
    turn_ratio: i32,
    rear_end_stability: i32,
    handbrake_slide: i32,
    thrust: i32,
    max_speed: i32,
    anti_strength: i32,
    gear1: i32,
    gear2: i32,
    gear3: i32,
    gear2_speed: i32,
    gear3_speed: i32,
    turbo: bool,
    w_px: i32,
    h_px: i32,
    front_wheel_px: i32,
    rear_wheel_px: i32,
    sprite: i32,
    ambient: bool,
    /// The `.gci` value byte: points for stealing the car (scoring.md 3.3).
    value: i32,
};

/// One spec per car in `style`. A car with no `.gci` record takes the
/// handling numbers of `fallback` (sizes, wheels and sprite still come from
/// the style). Trains, trams and tanks are marked not ambient: no doors,
/// longer than 120 pixels, or flagged in `info_flags` bit 0.
pub fn build(gpa: std.mem.Allocator, style: *const sty.Style, records: []const gci.Record, fallback: Spec) ![]Spec {
    const out = try gpa.alloc(Spec, style.cars.len);
    for (style.cars, 0..) |ci, i| {
        var s = fallback;
        for (records) |r| {
            if (r.model != ci.model) continue;
            s.mass = r.get(.mass);
            s.front_drive_bias = r.get(.front_drive_bias);
            s.front_mass_bias = r.get(.front_mass_bias);
            s.brake_friction = r.get(.brake_friction);
            s.turn_in = r.get(.turn_in);
            s.turn_ratio = r.get(.turn_ratio);
            s.rear_end_stability = r.get(.rear_end_stability);
            s.handbrake_slide = r.get(.handbrake_slide);
            s.thrust = r.get(.thrust);
            s.max_speed = r.get(.max_speed);
            s.anti_strength = r.get(.anti_strength);
            s.gear1 = r.get(.gear1_multiplier);
            s.gear2 = r.get(.gear2_multiplier);
            s.gear3 = r.get(.gear3_multiplier);
            s.gear2_speed = r.get(.gear2_speed);
            s.gear3_speed = r.get(.gear3_speed);
            s.turbo = r.turbo;
            s.value = r.value;
            break;
        }
        s.w_px = ci.w;
        s.h_px = ci.h;
        s.front_wheel_px = ci.front_wheel;
        s.rear_wheel_px = ci.rear_wheel;
        s.sprite = style.carSprite(i);
        s.ambient = ci.num_doors > 0 and ci.h <= 120 and ci.info_flags & 1 == 0;
        out[i] = s;
    }
    return out;
}
