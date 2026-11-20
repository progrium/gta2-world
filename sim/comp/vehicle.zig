//! The `Vehicle` component. Re-exported from `components.zig`.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Vehicle = extern struct {
    pub const id = abi.ComponentId.vehicle;
    /// The ped driving, or none.
    driver: EntityId,
    /// Index into `tuning.car_models`.
    model: u8,
    /// Gas pedal in quarters, 0-20 (car-handling.md step 2).
    pedal: i8,
    /// Steering input this tick, -127..127.
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
    /// Foot brake pressure in quarters, 0-4.
    brake: u8,
    /// Ticks the handbrake has been held, 0-128.
    handbrake_n: u8,
    /// What drove the car last tick: `drive_*`.
    drive: u8,
    /// Ticks spent sinking in deep water (car-height.md 3.5).
    sink: u8 = 0,
    /// Ticks left spinning on an oil slick (car-handling.md, Oil slick).
    oil: u8 = 0,
    /// The oil spin's direction: 0 or 1.
    oil_dir: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },

    pub const drive_none: u8 = 0;
    pub const drive_forward: u8 = 1;
    pub const drive_reverse: u8 = 2;

    pub const flag_horn: u8 = 1;
    pub const flag_handbrake: u8 = 2;
    /// Driven by the traffic AI (no ped inside).
    pub const flag_ai: u8 = 4;
    /// On fire (16000 damage or more); from 25000 it burns on by itself
    /// until it explodes.
    pub const flag_burning: u8 = 8;
    /// Burnt out: cannot be driven or entered.
    pub const flag_wrecked: u8 = 16;
    /// Fully over deep water: no engine and no brakes.
    pub const flag_in_water: u8 = 32;

    pub const reverse_base: u16 = 1000;
    pub const plan_in_junction: u8 = 0x80;
};
