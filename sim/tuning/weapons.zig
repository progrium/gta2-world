//! Tuning: Weapons, throwing, fire, electricity and power-ups (weapons.md, projectiles.md, power-ups-death-and-arrest.md 3.1).
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

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
    /// What the projectile is (`shot_*`).
    shot: u8 = shot_bullet,
};

/// Projectile behaviours.
pub const shot_bullet: u8 = 0;
/// A flame: sets a ped on fire as well as hurting him.
pub const shot_flame: u8 = 1;
/// No projectile: chain lightning every tick (weapons.md 3.5).
pub const shot_electro: u8 = 2;
/// Thrown: charged while fire is held, thrown on release (weapons.md 3.4).
pub const shot_grenade: u8 = 3;
pub const shot_molotov: u8 = 4;

pub const weapon_pistol: u8 = 0;
pub const weapon_smg: u8 = 1;
pub const weapon_shotgun: u8 = 2;
pub const weapon_rocket: u8 = 3;
pub const weapon_dual_pistol: u8 = 4;
pub const weapon_silenced: u8 = 5;
pub const weapon_flamethrower: u8 = 6;
pub const weapon_electro: u8 = 7;
pub const weapon_grenade: u8 = 8;
pub const weapon_molotov: u8 = 9;
pub const weapon_count = 10;
/// `Weapon.kind` on a pickup that is not a weapon: health, then the
/// power-ups (power-ups-death-and-arrest.md 3.1).
pub const pickup_health: u8 = 10;
pub const pickup_armour: u8 = 11;
pub const pickup_invulnerable: u8 = 12;
pub const pickup_double_damage: u8 = 13;
pub const pickup_fast_reload: u8 = 14;
pub const pickup_kinds = 15;
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
    // Dual pistols: two of the player's bullets at +-12 degrees, twice as
    // often as the pistol.
    .{ .cooldown = 10, .damage_player = 20, .damage_other = 50, .damage_car = 1600, .speed = fx.ratio(2, 10), .ttl = 25, .pellets = 2, .spread = 4 * deg6, .explosive = false, .tenths_per_pull = 10, .pickup_rounds = 30 },
    // Silenced machine gun: the machine gun without the noise.
    .{ .cooldown = 2, .damage_player = 10, .damage_other = 25, .damage_car = 800, .speed = fx.ratio(2, 10), .ttl = 25, .pellets = 1, .spread = 0, .explosive = false, .tenths_per_pull = 1, .pickup_rounds = 30 },
    // Flamethrower: a flame every tick, a tenth each. The stream's reach is
    // open in the notes; ours: 0.25 a tick for 6 ticks, 1.5 blocks.
    .{ .cooldown = 1, .damage_player = 10, .damage_other = 25, .damage_car = 100, .speed = fx.ratio(1, 4), .ttl = 6, .pellets = 1, .spread = 0, .explosive = false, .tenths_per_pull = 1, .pickup_rounds = 20, .shot = shot_flame },
    // Electro gun: chain lightning every tick while held (ours: a tenth a
    // tick, like the other streams).
    .{ .cooldown = 1, .damage_player = 0, .damage_other = 0, .damage_car = 300, .speed = 0, .ttl = 0, .pellets = 1, .spread = 0, .explosive = false, .tenths_per_pull = 1, .pickup_rounds = 20, .shot = shot_electro },
    // Grenade: thrown, bounces, explodes when its fuse runs out.
    .{ .cooldown = 4, .damage_player = 0, .damage_other = 0, .damage_car = 0, .speed = 0, .ttl = 0, .pellets = 1, .spread = 0, .explosive = true, .tenths_per_pull = 10, .pickup_rounds = 8, .shot = shot_grenade },
    // Molotov: thrown, bursts into fire on any contact.
    .{ .cooldown = 4, .damage_player = 10, .damage_other = 25, .damage_car = 32000, .speed = 0, .ttl = 0, .pellets = 1, .spread = 0, .explosive = true, .tenths_per_pull = 10, .pickup_rounds = 8, .shot = shot_molotov },
};

/// The throw charge counts up a tick at a time while fire is held, to 270;
/// strength is the charge up to 60. A grenade held to 96 goes off in hand.
pub const charge_max: u16 = 270;
pub const throw_strength_max: u16 = 60;
pub const grenade_in_hand: u16 = 96;
/// Thrown objects start half a block above the thrower, rising at 0.1 a
/// tick, with gravity 1/512 a tick squared.
pub const throw_height = fx.half;
pub const throw_rise = fx.ratio(1, 10);
pub const throw_gravity: Fx = fx.one / 512;
/// Horizontal speed: base + strength / 60 x span.
pub const grenade_speed_base = fx.ratio(1, 100);
pub const grenade_speed_span = fx.ratio(12, 100);
pub const molotov_speed_base = fx.ratio(2, 100);
pub const molotov_speed_span = fx.ratio(10, 100);
/// Added to a throw when the thrower is moving forwards.
pub const throw_moving_bonus = fx.ratio(51, 1000);
/// Rolling friction on the ground, per tick.
pub const throw_friction = fx.ratio(1, 100);
/// Grenade fuse in ticks from the charge at release. The notes give
/// (96 - charge) / 8 on the object's own timer, whose rate is open; ours:
/// 60 + 2 x (96 - charge), so a longer hold still means a shorter fuse.
pub fn grenadeFuse(charge: u16) u16 {
    return 60 + 2 * (grenade_in_hand -| @min(charge, grenade_in_hand));
}
/// Ours: how much of its speed a thrown object keeps off a bounce.
pub const bounce_8ths: i32 = 4;

/// Burning is open in the notes; ours: a ped set on fire burns this long,
/// losing `burn_damage_player` (a player) or `burn_damage_other` a tick.
pub const burn_ticks: u16 = 60;
pub const burn_damage_player: i32 = 1;
pub const burn_damage_other: i32 = 4;
/// A molotov's fire on the ground (ours): lasts this long, and sets on fire
/// anyone within `fire_radius` (square distance); cars in it take
/// `fire_car_damage` raw every 8 ticks.
pub const fire_ticks: u16 = 150;
pub const fire_radius = fx.ratio(6, 10);
pub const fire_car_damage: i32 = 100;
/// The explosion kind of a fire on the ground (0 small, 1 car).
pub const explosion_fire: u8 = 2;
/// Shock (explosions-and-damage.md 3.8): +5 a tick from the electro gun,
/// -1 a tick, electrocuted at 100. Ours: electrocution kills.
pub const shock_gun: u8 = 5;
pub const shock_threshold: u8 = 100;
/// Electro gun search: a square 4 blocks across, then 2 from each target;
/// 45 degrees either side; one level up or down.
pub const electro_reach = fx.fromInt(2);
pub const electro_chain_reach = fx.one;
pub const electro_cone: u16 = 8192;
pub const electro_reach_z = fx.one;

/// Armour charges; each soaks a whole hit.
pub const armour_charges: u8 = 10;
pub const invulnerable_ticks: u16 = 1200;
pub const double_damage_ticks: u16 = 1800;
pub const fast_reload_ticks: u16 = 1800;

/// Shots start this far in front of the shooter; the point halfway there
/// must be clear of walls or the shot is not fired.
pub const muzzle_ahead = fx.ratio(1, 4);
/// Added to a body's radius when a projectile is tested against it (ours:
/// a bullet's own size).
pub const shot_radius = fx.ratio(1, 16);
/// Shots fly this far above the shooter's feet (ours: about a ped's middle).
pub const shot_height = fx.ratio(1, 8);
