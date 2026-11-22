//! Car models from the player's files: the style's car info (CARI) joined
//! to the `.gci` handling records by model number (car-handling.md,
//! "`.gci` car record"). The result is one `Spec` per car model number,
//! from 0 to the highest model the style has, so a script's model number
//! (and the standard numbering, docs/research/public-sources.md 1) indexes
//! it directly. A number the style skips gets the fallback, not ambient.
//! The field names match `sim.tuning.CarSpec`, so a host can copy them
//! field by field.

const std = @import("std");
const sty = @import("sty.zig");
const gci = @import("gci.zig");

/// The most model numbers kept (`sim.tuning.max_car_models`).
pub const max_models = 96;

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
    /// The style's `info_flags` in bits 0-7 and `info_flags_2` in bits 8-15
    /// (public STY doc, car_info): see `flag_*`.
    flags: i32 = 0,
    /// The style's door count (0: nobody can get in, as trains and the
    /// container trailers).
    doors: i32 = 2,
};

/// `Spec.flags` bits, from the public style format document.
pub const flag_ped_jump: i32 = 0x01;
pub const flag_emerg_lights: i32 = 0x02;
pub const flag_roof_lights: i32 = 0x04;
/// Can be an articulated cab.
pub const flag_cab: i32 = 0x08;
/// Can be an articulated trailer.
pub const flag_trailer: i32 = 0x10;
pub const flag_forhire_lights: i32 = 0x20;
pub const flag_roof_decal: i32 = 0x40;
pub const flag_rear_emerg_lights: i32 = 0x80;
/// `info_flags_2` bit 0, `collide_over`: can drive over other cars (only
/// the tank in the player's styles; the notes' "heavy").
pub const flag_collide_over: i32 = 0x100;
pub const flag_popup: i32 = 0x200;

/// One spec per car model number, 0 to the style's highest (at most
/// `max_models`). A car with no `.gci` record takes the handling numbers of
/// `fallback` (sizes, wheels and sprite still come from the style). Trains,
/// trams and tanks are marked not ambient: no doors, longer than 120
/// pixels, or flagged in `info_flags` bit 0. A model number the style
/// lacks is the fallback, not ambient, drawn with the first car sprite.
pub fn build(gpa: std.mem.Allocator, style: *const sty.Style, records: []const gci.Record, fallback: Spec) ![]Spec {
    var top: usize = 0;
    for (style.cars) |ci| top = @max(top, @as(usize, ci.model) + 1);
    top = @min(top, max_models);
    const out = try gpa.alloc(Spec, top);
    for (out) |*o| {
        o.* = fallback;
        o.sprite = 0;
        o.ambient = false;
        o.flags = 0;
        o.doors = 0;
    }
    for (style.cars, 0..) |ci, i| {
        if (ci.model >= top) continue;
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
        s.flags = @as(i32, ci.info_flags) | (@as(i32, ci.info_flags_2) << 8);
        s.doors = ci.num_doors;
        out[ci.model] = s;
    }
    return out;
}
