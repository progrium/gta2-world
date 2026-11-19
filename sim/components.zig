//! Component types shared by entity kinds. Every component is an extern struct
//! of fixed-size integers so its layout is identical on wasm32 and native.

const fx = @import("fixed.zig");
const ecs = @import("ecs.zig");
const input = @import("input.zig");
const Fx = fx.Fx;
const EntityId = ecs.EntityId;

pub const Transform = extern struct {
    pub const name = "transform";
    x: Fx,
    y: Fx,
    z: Fx,
    heading: u16,
    _pad: u16 = 0,
};

pub const Velocity = extern struct {
    pub const name = "velocity";
    vx: Fx,
    vy: Fx,
    vz: Fx,
    /// Angular velocity, binary angle units per tick.
    spin: i32,
};

pub const Collider = extern struct {
    pub const name = "collider";
    pub const flag_disabled: u32 = 1;
    radius: Fx,
    mass: i32,
    flags: u32,
};

pub const Health = extern struct {
    pub const name = "health";
    hp: i32,
    last_hit_by: EntityId,
};

pub const Controller = extern struct {
    pub const name = "controller";
    pub const no_player: u32 = 0xFFFF_FFFF;
    player: u32,
    prev_buttons: u32,
    in: input.Frame,
};

pub const Vehicle = extern struct {
    pub const name = "vehicle";
    driver: EntityId,
    model: u32,
    /// Lateral grip, 0..1: fraction of sideways velocity removed per tick.
    grip: Fx,
    accel: Fx,
    max_speed: Fx,
};

pub const Pedestrian = extern struct {
    pub const name = "pedestrian";
    ai_timer: u32,
    ai_heading: u16,
    _pad: u16 = 0,
};

/// Set on a pedestrian that is inside a vehicle. Entities never change kind,
/// so entering a car is just this field.
pub const Riding = extern struct {
    pub const name = "riding";
    vehicle: EntityId,
};

pub const Weapon = extern struct {
    pub const name = "weapon";
    cooldown: u32,
    ammo: u32,
};

pub const Projectile = extern struct {
    pub const name = "projectile";
    owner: EntityId,
    ttl: u32,
    damage: i32,
};

/// Which entities a client predicts (rewinds and replays). Tag-like; nonzero
/// `on` means predicted. Systems do not read it in this spike.
pub const Predicted = extern struct {
    pub const name = "predicted";
    on: u32,
};
