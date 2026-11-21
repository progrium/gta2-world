//! Tuning: the single-player career (power-ups-death-and-arrest.md,
//! scoring.md, weapons.md 3.7). Owner: workstream G. Imported directly by
//! `sp/career.zig`, `sys/death.zig`, `sys/scoring.zig` and
//! `sys/car_weapons.zig`.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

// --- Lives, multiplier, death and arrest (power-ups-death-and-arrest.md)

/// Lives and multiplier cap (5).
pub const lives_max: u8 = 99;
pub const multiplier_max: u8 = 99;
/// Spare lives at the start of a level. Ours: the notes do not give it, and
/// a level's script usually sets them (script-player.md 2.2).
pub const start_lives: u8 = 3;
/// The wasted and busted countdown (3.2 step 4, 3.3).
pub const countdown_ticks: u8 = 70;
/// The double is handed to the police this many ticks before the end of an
/// arrest countdown (3.3 step 3).
pub const police_take_double: u8 = 2;

// --- Power-ups (3.1)

pub const armour_charges: u8 = 10;
pub const invulnerable_ticks: u16 = 1200;
pub const double_damage_ticks: u16 = 1800;
pub const fast_reload_ticks: u16 = 1800;
pub const electro_fingers_ticks: u16 = 2100;
pub const invisible_ticks: u16 = 1800;
pub const respect_max: i8 = 100;
/// Instant gang: up to this many recruits.
pub const instant_gang_recruits: u8 = 4;

// --- Scoring (scoring.md 3.2-3.3)

/// Base points by victim class, for a kill by weapon or explosion.
pub const points_civilian: i32 = 20;
pub const points_criminal: i32 = 40;
pub const points_rival_gang: i32 = 50;
pub const points_elvis: i32 = 100;
pub const points_lawman: i32 = 200;
pub const points_swat: i32 = 300;
pub const points_fbi: i32 = 400;
pub const points_army: i32 = 500;
/// Method factors, in halves: run over x1/2, weapon x1, electrocuted
/// x2 1/2, run over in the victim's own stolen car x5.
pub const halves_run_over: i32 = 1;
pub const halves_weapon: i32 = 2;
pub const halves_electro: i32 = 5;
pub const halves_own_car: i32 = 10;
/// Extra cash for killing an ordinary background driver by destroying his
/// car (times the multiplier).
pub const points_driver_in_wreck: i32 = 20;
/// Bus: stolen, and destroyed while carrying 10 or more.
pub const points_bus_stolen: i32 = 10;
pub const points_full_bus: i32 = 100;
pub const full_bus_riders: u8 = 10;
/// Emergency-vehicle kills: the set of kinds destroyed resets after this
/// many ticks with none (bonus targets read it).
pub const emergency_window: u8 = 150;

/// What a car model is, for scoring and built-in weapons. The model
/// numbers come from the player's `.gci`, which this repository never
/// carries, so every model is `ordinary` until a host that loaded the data
/// (H, A2) fills `model_roles`. Like the car models in `tuning.zig`, every
/// host in a session must set the same table before the first tick.
pub const ModelRole = enum(u8) { ordinary, bus, ambulance, police, swat, fbi, fire_truck, tank, army_jeep, _ };
pub var model_roles: [96]ModelRole = @splat(.ordinary);

/// The standard car numbering: the cars' script names in alphabetical
/// order from 0 (docs/research/public-sources.md 1), which the player's
/// style files follow when their car info has `count` >= 87 models. Fills
/// `model_roles` with it; any other count leaves every model `ordinary`.
/// The army's APC (3) and unarmed jeep (30) stay ordinary (ours: no role
/// fits them yet).
pub const standard_model_count = 87;
pub fn setStandardRoles(count: usize) void {
    model_roles = @splat(.ordinary);
    if (count < standard_model_count) return;
    model_roles[11] = .bus;
    model_roles[12] = .police;
    model_roles[17] = .fire_truck;
    model_roles[22] = .army_jeep;
    model_roles[34] = .ambulance;
    model_roles[52] = .swat;
    model_roles[54] = .tank;
    model_roles[84] = .fbi;
}

pub fn roleOf(model: u8) ModelRole {
    return if (model < model_roles.len) model_roles[model] else .ordinary;
}
pub fn isBus(model: u8) bool {
    return roleOf(model) == .bus;
}
/// The emergency kind (bit 0-4) of a model, or null (scoring.md 3.3).
pub fn emergencyKind(model: u8) ?u3 {
    return switch (roleOf(model)) {
        .ambulance => 0,
        .police => 1,
        .swat => 2,
        .fbi => 3,
        .fire_truck => 4,
        else => null,
    };
}

// --- Vehicle weapons (weapons.md 3.7)


/// Vehicle weapons. Kinds are stored per car in `car_weapons.State`.
pub const CarWeapon = enum(u8) {
    none = 0,
    /// Two bullets from the car's left and right front, every 2 ticks.
    car_guns = 1,
    /// One bullet from the turret, every 2 ticks.
    jeep_gun = 2,
    /// One rocket from the end of the turret barrel, every 50 ticks.
    tank_gun = 3,
    /// Water from the turret, every tick.
    water_cannon = 4,
    /// Flame from the turret, every tick.
    flamethrower = 5,
    /// An oil patch behind the car, every other tick.
    oil = 6,
    /// A mine behind the car.
    mines = 7,
    /// Arms the car's bomb (one use).
    car_bomb = 8,
    _,
};
pub const car_weapon_kinds = 9;

pub const CarWeaponDef = struct {
    /// Ticks between shots while held (weapons.md 3.7); 1 = every tick.
    wait: u8,
    /// Needs a fresh press of fire (car bomb, oil, mines, tank gun).
    fresh_press: bool,
    /// The projectile (`car_shot_base` + kind), if it fires one.
    shoots: bool,
    /// Counts as an armed attack for crime reports.
    armed_attack: bool,
    /// Most ammo, in tenths of a displayed round (99, 1 for the car bomb),
    /// and what one use spends. Ours: a tenth a shot for the streams and
    /// guns, like the hand machine gun; a whole round for the rest.
    max_tenths: u16,
    tenths_per_use: u16,
};

/// Indexed by `CarWeapon`. Oil drops "every other tick of ammo"; ours: a
/// tenth each drop, with a 2-tick wait while held after the fresh press.
pub const car_weapons = [car_weapon_kinds]CarWeaponDef{
    .{ .wait = 0, .fresh_press = false, .shoots = false, .armed_attack = false, .max_tenths = 0, .tenths_per_use = 0 },
    .{ .wait = 2, .fresh_press = false, .shoots = true, .armed_attack = true, .max_tenths = 990, .tenths_per_use = 1 },
    .{ .wait = 2, .fresh_press = false, .shoots = true, .armed_attack = true, .max_tenths = 990, .tenths_per_use = 1 },
    .{ .wait = 50, .fresh_press = true, .shoots = true, .armed_attack = true, .max_tenths = 990, .tenths_per_use = 10 },
    .{ .wait = 1, .fresh_press = false, .shoots = true, .armed_attack = false, .max_tenths = 990, .tenths_per_use = 1 },
    .{ .wait = 1, .fresh_press = false, .shoots = true, .armed_attack = true, .max_tenths = 990, .tenths_per_use = 1 },
    .{ .wait = 2, .fresh_press = true, .shoots = false, .armed_attack = false, .max_tenths = 990, .tenths_per_use = 1 },
    .{ .wait = 1, .fresh_press = true, .shoots = false, .armed_attack = false, .max_tenths = 990, .tenths_per_use = 10 },
    .{ .wait = 1, .fresh_press = true, .shoots = false, .armed_attack = false, .max_tenths = 10, .tenths_per_use = 10 },
};

/// Built-in weapons by model role; they never run out.
pub fn builtinCarWeapon(model: u8) CarWeapon {
    return switch (roleOf(model)) {
        .tank => .tank_gun,
        .army_jeep => .jeep_gun,
        .fire_truck => .water_cannon,
        else => .none,
    };
}

/// The tank's rocket leaves 30/64 of a block out along the turret.
pub const tank_barrel = fx.ratio(30, 64);
/// Ours: turret shots start this far out from the car's centre for the
/// jeep and fire truck, and dropped oil and mines this far behind the
/// car's back end.
pub const turret_reach = fx.ratio(1, 2);
pub const drop_behind = fx.ratio(1, 4);
/// Ours: an armed car bomb goes off this many ticks later. The notes say
/// only that the press arms it.
pub const car_bomb_fuse: u16 = 150;
/// Most cars with weapons at once (the state table).
pub const max_armed_cars = 16;
