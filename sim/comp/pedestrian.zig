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
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// `Health.last_hit_by` as last seen, to notice a new attacker.
    prev_hit: abi.EntityId = .none,

    pub const anim_stand: u8 = 0;
    pub const anim_walk: u8 = 1;
    pub const anim_run: u8 = 2;
    pub const anim_jump: u8 = 3;
    pub const anim_down: u8 = 4;

    pub const state_up: u8 = 0;
    /// Knocked over: slides, then gets straight up.
    pub const state_over: u8 = 1;
    /// Knocked down: lies a while, then gets up.
    pub const state_down: u8 = 2;
    /// Fatally thrown: dies when the body comes to rest.
    pub const state_fatal: u8 = 3;

    /// Jump was pressed this tick (a fresh press, set by the input system).
    pub const flag_jump_pressed: u8 = 1;
    /// Died in deep water (for scoring).
    pub const flag_drowned: u8 = 2;
};
