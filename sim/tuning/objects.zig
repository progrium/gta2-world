//! Tuning: objects and city furniture (workstream B): crushers, doors,
//! phones, generators, oil, mines and the traffic light cycle.
//! Imported directly by `sys/objects.zig`, `sys/doors.zig`,
//! `sys/generators.zig`, `sys/crusher.zig` and `sys/lights.zig`; see the
//! conventions in `tuning.zig`. Numbers marked "notes" come from the named
//! behaviour note; "ours" are our own until a note settles them (each is
//! listed in docs/coverage/).

const fx = @import("../fixed.zig");
const Fx = fx.Fx;

// --- Car shops (ours: no behaviour note covers them yet; sys/shops.zig)

/// The `CAR_SHOP` object model in the level scripts (the player's data:
/// every main script declares its shops with this model).
pub const car_shop_model: u16 = 130;
/// Declaration values from here up are the weapon shops' codes (250-254
/// in the data); below it the value is a spray shop's paint remap.
pub const first_weapon_shop: u8 = 250;
/// Ours: a car is in a shop when its centre is in the shop's block and
/// within a block of the shop's floor height.
pub const shop_reach_z = fx.one;
/// Ours: the price of losing the wanted level at a spray shop, in career
/// cash (single player) and in points (a police room, where a player kill
/// is 2000). The repaint itself is free.
pub const shop_price_sp: i32 = 5000;
pub const shop_price_mp: i32 = 2000;

// --- Crushers (notes: crushers-and-garages.md 3.1-3.2, 4)

/// Piston distance from the centre when open and when closed.
pub const piston_open = fx.ratio(15, 16); // 0.9375
pub const piston_closed = fx.ratio(9, 16); // 0.5625
/// Where the piston base blocks sit (drawn by the client).
pub const piston_base = fx.ratio(9, 8); // 1.125
/// Pistons move 1/64 block a tick.
pub const piston_speed = fx.ratio(1, 64);
/// The piston face offset used in the shrink test.
pub const piston_face = fx.ratio(7, 16); // 0.4375
/// A crushed car's sprite and collision shrink 2 px a tick (64 px a block).
pub const crush_shrink_px: u8 = 2;
/// Ours: a car "touches the centre marker" when its centre is within this
/// distance of the crusher centre on both axes, and within half a block of
/// height.
pub const crusher_reach = fx.ratio(1, 4);
/// Ours: the smallest width or length a crushed sprite keeps, in px.
pub const crush_min_px: u8 = 4;

// --- Doors (notes: script-declarations.md 2.9, script-objects.md 2.5)

/// Shared door-animation definitions (notes: 5).
pub const door_anims = 5;
/// Ours: doors a level may register.
pub const max_doors = 32;
/// Ours: a body counts for a door's open rule when its centre is within
/// this distance of the door face (across it) and within half a block of
/// the face's span along it, on the door's level.
pub const door_reach = fx.ratio(3, 2);
/// Ours: an animation's playback speed is ticks per frame; a speed of 0
/// counts as 1.

// --- Phones (notes: script-objects.md 2.6, 4)

/// Dead phones remembered per level (notes: 31).
pub const max_dead_phones = 31;
/// Ours: a ped answers or touches a phone when its centre is within this
/// distance of the phone, on its level.
pub const phone_reach = fx.ratio(1, 2);

// --- Generators (notes: script-declarations.md 2.8, script-objects.md 2.3, 4)

/// Ours: generators a level may declare.
pub const max_generators = 48;
/// Object models treated as pickups (notes: 64-108 and 200-244).
pub const pickup_model_lo = 64;
pub const pickup_model_hi = 108;
pub const weapon_model_lo = 200;
pub const weapon_model_hi = 244;
/// "Decide power-up" (type 354): below this type, 3 spawns, else 1
/// (notes: 91, 3, 1).
pub const powerup_count_threshold: u8 = 91;
pub const powerup_count_low: u16 = 3;
pub const powerup_count_high: u16 = 1;
/// The fallback power-up type when the car model is not listed (notes: 65,
/// with 3 spawns).
pub const powerup_fallback: u8 = 65;
/// Car models in the level's car list (notes: 19).
pub const car_list_len = 19;
/// Ours: the per-entry power-up type for a listed car model. The real table
/// is a game constant the notes do not give, so every entry uses the
/// fallback until a note lists it.
pub const car_list_powerups = [car_list_len]u8{
    65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
};
/// Ours: power-up model 64 + n gives `career.PowerUp` n for the first
/// `powerup_kinds` models (workstream G's numbering), timed ones for 60 s.
pub const powerup_kinds: u8 = 13;
pub const powerup_ticks: u16 = 1800;
/// Unlimited spawns (a declared generator's default; notes: "effectively
/// unlimited").
pub const spawns_unlimited: u16 = 0xFFFF;
/// Ours: a pickup made by a generator or placed by the script is taken by a
/// player within this distance (as the deathmatch pickups).
pub const object_pickup_reach = fx.ratio(6, 10);

// --- Conveyors and destructors (notes: script-declarations.md 2.8)

/// Ours: conveyor and destructor areas a level may declare.
pub const max_areas = 16;

// --- Oil and mines (notes: weapons.md 3.7, projectiles.md 3.1-3.3)

/// Ours: an oil patch lasts 30 s.
pub const oil_life: u16 = 900;
/// Ours: an oil patch's radius.
pub const oil_radius = fx.ratio(3, 8);
/// Ours: a mine cannot go off for this many ticks after it is dropped, so
/// the car dropping it gets clear.
pub const mine_arm_ticks: u16 = 30;
/// Ours: a mine's touch radius (added to a ped's radius; for a car, the
/// mine's centre inside the car's box grown by this).
pub const mine_radius = fx.ratio(1, 8);
/// Ours: an unexploded mine lasts 3 minutes.
pub const mine_life: u16 = 5400;
/// A mine hitting a car: 32000 raw damage plus a small explosion (notes:
/// projectiles.md 3.3).
pub const mine_car_damage: i64 = 32000;

// --- Barriers (police roadblocks, police-ai.md 3.4; workstream E places them)

/// Ours: barrier sizes by model, half extents along and across its
/// heading. Model 0 is the roadblock barrier, a block long and a quarter
/// block thick.
pub const barrier_half_len = [_]Fx{fx.half};
pub const barrier_half_wid = [_]Fx{fx.ratio(1, 8)};

// --- Traffic lights (notes: traffic-and-car-ai.md 3.6)

/// Phase lengths in ticks: north-south green, amber, red; east-west green,
/// amber, red; all red with pedestrians crossing; all red.
pub const light_phases = [8]u16{ 100, 24, 24, 100, 24, 24, 150, 80 };
pub const light_cycle: u16 = blk: {
    var s: u16 = 0;
    for (light_phases) |p| s += p;
    break :blk s;
};
comptime {
    if (light_cycle != 526) @compileError("the light cycle is 526 ticks");
}
