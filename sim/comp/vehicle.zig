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
    /// Traffic (workstream F, traffic-and-car-ai.md): `ai_*` bits.
    ai_flags: u8 = 0,
    /// Traffic: ticks since the AI took the car, saturating (the car-ahead
    /// check waits 20).
    ai_age: u8 = 0,
    /// Traffic: ticks left holding because a car crossing a junction made
    /// this one yield.
    ai_yield: u8 = 0,
    /// Traffic: ticks stuck touching the car `ai_touch`.
    ai_wiggle: u8 = 0,
    /// Traffic: ticks spent looking for a road.
    ai_lost: u16 = 0,
    /// Traffic: index + 1 of the car this one is stuck against, or 0.
    ai_touch: u16 = 0,
    /// Traffic: index + 1 of the last crossing marker stopped at, or 0.
    ai_mark: u16 = 0,
    /// Traffic: ticks left of an overtake at a crossing queue.
    ai_pass: u8 = 0,
    /// Traffic: the overtake side, -1 or 1, or 0.
    ai_side: i8 = 0,

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
    /// Squashed flat by a crusher (crushers-and-garages.md 3.2; set by
    /// workstream B's `sys/crusher.zig`).
    pub const flag_crushed: u8 = 64;

    /// `ai_flags`: script-created (never gives up off-road).
    pub const ai_script: u8 = 1;
    /// Gave up off-road: halted for good.
    pub const ai_abandoned: u8 = 2;
    /// Halted by a script or a stop task until released.
    pub const ai_halted: u8 = 4;
    /// Police, SWAT, FBI, army, fire, ambulance or train: always honks.
    pub const ai_emergency: u8 = 8;
    /// A bus: never checks for a car ahead.
    pub const ai_bus: u8 = 16;
    /// Settling into the lane after a turn.
    pub const ai_settling: u8 = 32;

    pub const reverse_base: u16 = 1000;
    pub const plan_in_junction: u8 = 0x80;
};
