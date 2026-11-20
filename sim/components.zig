//! Component types. The ones other workstreams read (`Transform`, `Velocity`,
//! `Health`, `Controller`, `Riding`, `Predicted`) are the frozen I1 types,
//! re-exported. The rest are owned by `sim/` and may change freely; their
//! layout reaches other parties only through `layout_hash` and generated
//! codecs. Every component is an extern struct of fixed-size integers whose
//! size is a multiple of 4, with `pub const id: abi.ComponentId`.
//!
//! Constant per-kind or per-model data (radii, masses, handling) is kept out
//! of components so it costs no snapshot bytes; see `tuning.zig`.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Transform = abi.Transform;
pub const Velocity = abi.Velocity;
pub const Health = abi.Health;
pub const Controller = abi.Controller;
pub const Riding = abi.Riding;
pub const Predicted = abi.Predicted;

/// Dynamic collision state. Shape comes from the kind and model.
pub const Collider = extern struct {
    pub const id = abi.ComponentId.collider;
    /// Not collidable and not moved by physics (a ped riding a car).
    pub const flag_disabled: u32 = 1;
    /// Standing on a floor at the end of the last step.
    pub const flag_grounded: u32 = 2;
    flags: u32,
};

pub const Vehicle = extern struct {
    pub const id = abi.ComponentId.vehicle;
    /// The ped driving, or none.
    driver: EntityId,
    /// Index into `tuning.car_models`.
    model: u8,
    /// Pedal position, -127..127. Follows `throttle` through a ramp so
    /// digital triggers and keys build up instead of slamming (I2).
    pedal: i8,
    /// Front wheel position, -127..127. Follows `steer` through a ramp.
    steer: i8,
    flags: u8,
    /// Wrecked: ticks until the wreck is cleared. Traffic: ticks stuck, or
    /// `reverse_base` + ticks left of backing out.
    timer: u16,
    /// Traffic: lane direction, 0 +x, 1 +y, 2 -x, 3 -y.
    ai_dir: u8,
    /// Traffic: bits 0-1 the plan at the next junction (0 straight, 1 left,
    /// 2 right), bit 7 set while in a junction.
    ai_plan: u8,
    /// Traffic: ticks left stopped after hitting a pedestrian.
    halt: u16,
    /// Traffic: the speed setting, which ramps toward the target (fx, in
    /// 1/65536 blocks per tick).
    ai_speed: u16,

    pub const flag_horn: u8 = 1;
    pub const flag_handbrake: u8 = 2;
    /// Driven by the traffic AI (no ped inside).
    pub const flag_ai: u8 = 4;
    /// On fire (16000 damage or more); from 25000 it burns on by itself
    /// until it explodes.
    pub const flag_burning: u8 = 8;
    /// Burnt out: cannot be driven or entered.
    pub const flag_wrecked: u8 = 16;

    pub const reverse_base: u16 = 1000;
    pub const plan_in_junction: u8 = 0x80;
};

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
};

/// On a ped: the weapon in hand and the ammo held for each weapon, in tenths
/// of a displayed round. On a pickup: what it gives (`kind`) and `cooldown`
/// is the ticks left before it disappears.
pub const Weapon = extern struct {
    pub const id = abi.ComponentId.weapon;
    cooldown: u16,
    /// Index into `tuning.weapons`, or `tuning.pickup_health` on a pickup.
    kind: u8,
    _pad: u8 = 0,
    /// Ammo per weapon in tenths (`rounds()`); `tuning.infinite_ammo` never
    /// runs out. Separate fields because the I3 codecs take scalars only.
    a0: u16,
    a1: u16,
    a2: u16,
    a3: u16,

    pub fn rounds(self: *Weapon) *[4]u16 {
        return @ptrCast(&self.a0);
    }
    pub fn roundsConst(self: *const Weapon) *const [4]u16 {
        return @ptrCast(&self.a0);
    }
};

/// What to draw: I1 component 12, accepted 2026-11-20. The layout is frozen
/// in `abi.Appearance`. `sprite` is the car model for cars and the ped type
/// for peds (0 for now; the walk cycle comes from `Pedestrian.anim` and time
/// on the client, so it costs no snapshot bytes). `remap` is a palette remap,
/// `no_remap` for none.
pub const Appearance = abi.Appearance;

/// A projectile, or an explosion (`weapon` has `explosion_bit` set; it
/// stays put for its 99-tick timer in `ttl`, and `owner` is credited).
pub const Projectile = extern struct {
    pub const id = abi.ComponentId.projectile;
    owner: EntityId,
    ttl: u16,
    /// Unused (kept for the layout).
    damage: u16,
    /// Index into `tuning.weapons` of the weapon that fired it, or
    /// `explosion_bit` | the explosion kind (0 small, 1 car).
    weapon: u8,
    _pad: u8 = 0,
    _pad2: u16 = 0,

    pub const explosion_bit: u8 = 0x40;
};
