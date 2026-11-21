//! Tuning: ped AI (ped-ai.md, weapons.md 3.8). Owner: workstream D1.
//! Not re-exported from `tuning.zig`; the AI files import it directly.
//!
//! Numbers the note gives are tagged with its section. Numbers it leaves
//! open are tagged "ours" and listed in the D1 hand-off.

const fx = @import("../fixed.zig");
const Fx = fx.Fx;

// --- Chasing (3.7) ---------------------------------------------------------

/// A chaser stops within 1/8 block of its target (3.7).
pub const chase_stop = fx.ratio(1, 8);
/// Ours: our ped bodies (0.2 across) touch before their centres are 1/8
/// apart, and a chaser walking on into its target shoves it (off a roof
/// edge, for one). So a chaser stops just short of touching: 0.2 + 1/32.
/// A punch (0.25) still reaches from there.
pub const chase_stop_at = fx.ratio(1, 5) + fx.ratio(1, 32);
/// Below these gaps the chaser drops to three slower fixed speeds (3.7).
pub const chase_tier1 = fx.ratio(1, 2);
pub const chase_tier2 = fx.ratio(3, 8);
pub const chase_tier3 = fx.ratio(5, 16);
/// Throttle (of 127) for each tier: the note gives the breakpoints but not
/// the speeds. Ours.
pub const chase_throttle = [4]i8{ 127, 95, 64, 40 };

// --- Ranged attack ranges (3.7), blocks ------------------------------------

/// Fire range and back-off range per weapon (`tuning.weapons` index).
/// 0 back-off: none. `close_in`: the weapon tries to get inside this range
/// before firing (shotgun, electro), 0 for none.
pub const Range = struct { fire: Fx, back_off: Fx = 0, close_in: Fx = 0 };
pub const unarmed_range = fx.fromInt(2);
pub const ranges = [10]Range{
    .{ .fire = fx.fromInt(4) }, // pistol
    .{ .fire = fx.fromInt(4) }, // machine gun
    .{ .fire = fx.fromInt(1), .close_in = fx.ratio(1, 2) }, // shotgun
    .{ .fire = fx.fromInt(4) }, // rocket
    .{ .fire = fx.fromInt(4) }, // dual pistols
    .{ .fire = fx.fromInt(4) }, // silenced machine gun
    .{ .fire = fx.fromInt(2), .back_off = fx.one }, // flamethrower
    // The note's row is the electro baton (2, close in to 0.5); our hand
    // electro gun reaches 2 blocks, so it uses the same row. Ours.
    .{ .fire = fx.fromInt(2), .close_in = fx.ratio(1, 2) }, // electro gun
    .{ .fire = fx.ratio(5, 2), .back_off = fx.fromInt(2) }, // grenade
    .{ .fire = fx.fromInt(4), .back_off = fx.ratio(3, 2) }, // molotov
};
/// Against a car, or a ped in a nearly stationary car, "roughly 2-3
/// blocks" (3.7): ours 3 to fire, backing off inside 2.
pub const car_fire_range = fx.fromInt(3);
pub const car_back_off = fx.fromInt(2);
/// "Nearly stationary" car: ours.
pub const car_still_speed = fx.ratio(2, 100);
/// FBI peds and group leaders close within 0.5 block before firing (3.7).
pub const leader_close_in = fx.ratio(1, 2);
/// An explosive weapon is not fired at a target this close (inside its own
/// blast). The small blast is 0.5; ours: 1 block for margin.
pub const explosive_min_range = fx.one;
/// Hit-and-run: ticks spent retreating at full speed after landing a hit.
/// Ours.
pub const hit_and_run_ticks: u8 = 40;
/// A gun keeps firing while it closes in, up to this far past its fire
/// range. Ours.
pub const run_and_gun = fx.one;
/// The facing error within which a ranged shooter pulls the trigger. Ours
/// (about 11 degrees).
pub const fire_cone: u16 = 2048;

// --- Aim jitter (3.8) ------------------------------------------------------

/// Chance in 256 that a stationary shooter's roll misses; a moving shooter
/// re-rolls once if the first roll was dead accurate. Ours.
pub const miss_chance_256: u32 = 80;
/// Chance in 256 that a miss is the large one. Ours.
pub const big_miss_256: u32 = 64;
/// About 10 and 16 degrees, in angle units (3.8).
pub const miss_small: u16 = 1820;
pub const miss_big: u16 = 2913;

// --- Test shots (weapons.md 3.8) --------------------------------------------

/// Ticks between test shots: 5, or 1 for machine guns.
pub const test_wait: u16 = 5;
pub const test_wait_mg: u16 = 1;
/// A body closer than this to the line of fire blocks a test shot. Ours
/// (the ped radius plus a bullet's width).
pub const line_clearance = fx.ratio(3, 20);
/// Shotgun test shots spread at 0, +-12 and +-24 degrees.
pub const shotgun_test_spread: u16 = 2185;

// --- Melee (3.9) -----------------------------------------------------------

/// A punch lands within 0.25 block.
pub const punch_reach = fx.ratio(1, 4);
pub const punch_damage: i32 = 10;
/// Below this health a punch knocks the target down instead.
pub const punch_knockdown_hp: i32 = 20;
/// Score a mugger takes from the player per mug.
pub const mug_score: i32 = 10;
/// A mugger retires after more than this many mugs.
pub const mug_retire: u8 = 9;
/// Ticks a mugger rests after a mug before picking another victim. Ours.
pub const mug_rest: u16 = 120;
/// Punch animation frames, and the frame the fist lands on. The note says
/// "on specific animation frames"; ours.
pub const punch_frames: u16 = 6;
pub const punch_hit_frame: u16 = 3;
/// Same height for a punch: within this. Ours.
pub const same_height = fx.ratio(1, 2);
/// The car must be slower than this for an attacker to pull its driver
/// out, and slower still for law enforcement (3.9). Ours.
pub const pull_out_speed = fx.ratio(5, 100);
pub const pull_out_speed_law = fx.ratio(2, 100);

// --- Following (3.10) --------------------------------------------------------

/// Close enough to stop: 3/16 block at the same height. Ours: measured
/// between the two bodies' edges, since our ped bodies (0.2 across) push
/// each other apart before their centres get that close.
pub const follow_stop = fx.ratio(3, 16);
/// Run beyond 0.5 block, walk inside it.
pub const follow_walk = fx.ratio(1, 2);
/// The follow wait counter resets after 200 ticks.
pub const follow_wait_reset: u16 = 200;

// --- Fleeing (3.5) ------------------------------------------------------------

/// Undirected flee and flee-a-ped pass beyond 6 blocks, on safe ground.
pub const flee_safe = fx.fromInt(6);
/// The passive trigger: a dangerous ped within 4 blocks.
pub const panic_range = fx.fromInt(4);
/// A driven car counts as dangerous above this speed. Ours.
pub const dangerous_car_speed = fx.ratio(8, 100);
/// Internal flee objectives give up after this long if nothing else ends
/// them (the note has a timeout per objective, values unstated). Ours.
pub const flee_timeout: u16 = 600;

// --- Threat search (3.3, 3.4) ---------------------------------------------------

/// Best-target search and the fallback dangerous-list distance cap.
pub const search_range = fx.fromInt(4);
/// The short plain-radius check of the player-only search mode. Ours.
pub const search_short = fx.ratio(3, 2);
/// Line-of-sight cone half-angles, narrow and wide. The note confirms two
/// values exist but not what they are. Ours: 30 and 60 degrees.
pub const cone_narrow: u16 = 5461;
pub const cone_wide: u16 = 10923;
/// Ticks between threat searches for one ped, staggered by index. Ours.
pub const search_every: u16 = 8;
/// "On screen": a box around the player's ped, half-width and
/// half-height in blocks. The camera note does not give the visible area
/// at street level; ours.
pub const screen_half_w = fx.fromInt(6);
pub const screen_half_h = fx.fromInt(5);
/// Same level for the search: within this height. Ours.
pub const same_level = fx.one;
/// The crowd cap: a rival gang member skips a target with this many
/// current or total attackers (3.3).
pub const crowd_cap: u8 = 4;
/// Gang respect at or above which a gang fights police for the player.
pub const high_respect: i8 = 80;
/// Attacked within this distance counts as "attacked within 1 block".
pub const near_attack = fx.one;
/// A player-led group member drops an attacker out of sight this long.
pub const unseen_drop: u8 = 5;
/// Internal attack objectives give up after this long if nothing else ends
/// them. Ours.
pub const attack_timeout: u16 = 1200;

// --- Police fire rationing (3.8) --------------------------------------------------

/// At least this many police on screen before any fires at a player on
/// foot, and this many firing at once.
pub const police_min_present: u8 = 2;
pub const police_max_firing: u8 = 1;
/// FBI and roadblock cops switch to the sidearm this close to a ped on
/// foot.
pub const fbi_sidearm_range = fx.ratio(1, 2);

// --- Electro-fingers (3.14) ---------------------------------------------------------

pub const electro_fingers_radius = fx.ratio(1, 2);
pub const electro_fingers_damage: i32 = 3;

// --- Movement ------------------------------------------------------------------------

/// Arrived at a point target: within this. Ours.
pub const arrive = fx.ratio(1, 4);
/// How far ahead a walker probes for walls, and the detour angles it
/// tries when blocked (45 and 90 degrees either side). Ours.
pub const probe = fx.ratio(4, 10);
pub const detours = [4]i32{ 8192, -8192, 16384, -16384 };
/// Guard: attack threats within this of the guard point, return when
/// further than this from it. Ours.
pub const guard_range = fx.fromInt(4);
