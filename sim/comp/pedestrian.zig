//! The `Pedestrian` component. Re-exported from `components.zig`.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Pedestrian = extern struct {
    pub const id = abi.ComponentId.pedestrian;
    /// AI: ticks until the next wander decision.
    ai_timer: u16,
    /// AI: heading the ped is walking toward.
    ai_heading: u16,
    /// Tank turning speed, angle units per tick; builds up while a turn is
    /// held (ped-movement.md 3.1).
    turn: i16,
    /// Ticks left lying on the ground once a knock-over or knock-down has
    /// come to rest.
    down: u16,
    /// Ticks left in the current jump.
    jump: u8,
    /// What the renderer shows (`anim_*`).
    anim: u8,
    /// `state_*`: on its feet, or knocked over, down, or fatally.
    state: u8,
    /// `flag_*`.
    flags: u8,
    /// Shock counter (explosions-and-damage.md 3.8).
    shock: u8 = 0,
    /// Armour charges left (power-ups-death-and-arrest.md 3.1).
    armour: u8 = 0,
    /// Ticks left burning.
    burn: u16 = 0,
    /// Power-up timers, in ticks.
    invulnerable: u16 = 0,
    double_damage: u16 = 0,
    fast_reload: u16 = 0,
    /// Throw charge while fire is held with a grenade or molotov.
    charge: u16 = 0,
    /// Scoring combos (scoring.md 3.2, 3.3): the next multiplier for a kill
    /// and for a car destroyed, and ticks left in which each still holds.
    combo: u8 = 0,
    combo_timer: u8 = 0,
    car_combo: u8 = 0,
    car_combo_timer: u8 = 0,
    /// Ticks since `Health.last_hit_by` last changed, up to 255: a drowning
    /// is credited only to an attacker within `drown_credit_ticks`.
    hit_age: u8 = 0,
    /// Ticks spent falling (`state_falling`), up to 255: the fall animation
    /// frame, and so fall damage, comes from it (ped-movement.md 3.5).
    fall: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    /// `Health.last_hit_by` as last seen, to notice a new attacker.
    prev_hit: abi.EntityId = .none,

    pub const anim_stand: u8 = 0;
    pub const anim_walk: u8 = 1;
    pub const anim_run: u8 = 2;
    pub const anim_jump: u8 = 3;
    pub const anim_down: u8 = 4;
    // 5-15 reserved by W0 for the knocked-down, falling, drowning and car
    // door animations (C, D1, D2); the renderer draws them (H).
    pub const anim_fall: u8 = 5;
    pub const anim_drown: u8 = 6;
    pub const anim_get_up: u8 = 7;
    pub const anim_electrocuted: u8 = 8;
    pub const anim_enter_car: u8 = 9;
    pub const anim_exit_car: u8 = 10;
    pub const anim_punch: u8 = 11;
    pub const anim_lie: u8 = 12;
    pub const anim_burning: u8 = 13;

    pub const state_up: u8 = 0;
    /// Knocked over: slides, then gets straight up.
    pub const state_over: u8 = 1;
    /// Knocked down: lies a while, then gets up.
    pub const state_down: u8 = 2;
    /// Fatally thrown: dies when the body comes to rest.
    pub const state_fatal: u8 = 3;
    // 4-15 reserved by W0 (owners in brackets).
    /// Falling from a height; frames counted for fall damage (C).
    pub const state_falling: u8 = 4;
    /// Drowning in deep water (C).
    pub const state_drowning: u8 = 5;
    /// Getting up after lying down (C).
    pub const state_getting_up: u8 = 6;
    /// Held by an electric shock (C, G).
    pub const state_electrocuted: u8 = 7;
    /// Walking to a car door, opening it, getting in (D2).
    pub const state_entering: u8 = 8;
    /// Getting out of a car (D2).
    pub const state_exiting: u8 = 9;
    /// Being pulled out of a car by a carjacker (D2).
    pub const state_pulled_out: u8 = 10;
    /// Being arrested (E, G).
    pub const state_arrested: u8 = 11;

    /// Jump was pressed this tick (a fresh press, set by the input system).
    pub const flag_jump_pressed: u8 = 1;
    /// Died in deep water (for scoring).
    pub const flag_drowned: u8 = 2;
};
