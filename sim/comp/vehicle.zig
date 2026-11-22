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
    /// Vehicle weapon (`sys/car_weapons.zig`): the fitted `CarWeapon`
    /// (tuning/career.zig), 0 none. Built-in weapons come from the model.
    arm: u8 = 0,
    /// Ticks until the car's weapon, fitted or built in, can fire again.
    arm_wait: u8 = 0,
    /// The fitted weapon's ammo, in tenths of a displayed round.
    arm_ammo: u16 = 0,
    /// An armed car bomb: ticks until it goes off (0 = not armed).
    bomb_fuse: u16 = 0,
    /// Who armed the bomb: player slot + 1 (0 = nobody), credited with
    /// the blast.
    bomb_by: u8 = 0,
    _arm_pad: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    /// Towing (`sys/trailers.zig`): on a cab, the trailer it pulls, as the
    /// entity id + 1 (0 none, so a zeroed car tows nothing); use
    /// `trailerId` and `setTrailer`.
    trailer_ref: u32 = 0,
    /// On a trailer, the car towing it, the same way (`towId`, `setTow`).
    tow_ref: u32 = 0,
    /// Door lock, `lock_*` (script CHANGE_CAR_LOCK).
    lock: u8 = 0,
    /// Script car flags, `xf_*`.
    xflags: u8 = 0,
    /// The number painted on the roof (0 none).
    roof: u8 = 0,
    /// Ticks left of the alarm ringing.
    alarm_n: u8 = 0,
    /// Ticks left of "recently hit": an unhitched trailer is not drawn to a
    /// hitch while it runs (car-collision.md 3.4).
    hit_n: u8 = 0,
    /// Visible damage (car-collision.md 3.5), `dent_*` bits: the four
    /// corner dents and the cracked windscreen, drawn with the style's car
    /// deltas 0-4.
    dents: u8 = 0,
    _pad2: [2]u8 = .{ 0, 0 },

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
    /// Inside a car shop's block (`sys/shops.zig`), so a visit acts once.
    pub const flag_in_shop: u8 = 128;

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
    /// Traffic: taking a bend or a turn this tick; the car's steering lock
    /// is widened (`car_control`, `TF.corner_lock`).
    pub const ai_cornering: u8 = 64;

    /// `lock`: the six lock types, in the public scripting docs' order.
    pub const lock_none: u8 = 0;
    /// Nobody gets in, players included.
    pub const lock_locked: u8 = 1;
    pub const lock_unlocked: u8 = 2;
    /// Locked for everyone, and no other lock type replaces it.
    pub const lock_permanent: u8 = 3;
    /// AI car thieves cannot get in (the default for created cars).
    pub const lock_thief: u8 = 4;
    /// Players cannot get in.
    pub const lock_player: u8 = 5;

    /// `xflags`: no bullet damage.
    pub const xf_bulletproof: u8 = 1;
    /// No damage from rockets, molotovs or explosions short of a car bomb.
    pub const xf_rocketproof: u8 = 2;
    /// No fire damage.
    pub const xf_flameproof: u8 = 4;
    /// Has an alarm (rings when stolen or hit).
    pub const xf_alarm: u8 = 8;
    /// The accelerator is jammed on (a player's car).
    pub const xf_jammed: u8 = 16;
    /// Siren and emergency lights on.
    pub const xf_siren: u8 = 32;
    /// Held by a crane: "zoomed" out of normal play (no driving, no exit).
    pub const xf_lifted: u8 = 64;

    /// `dents`, in the style's car delta order (public style format doc).
    pub const dent_rear_right: u8 = 1;
    pub const dent_rear_left: u8 = 2;
    pub const dent_front_left: u8 = 4;
    pub const dent_front_right: u8 = 8;
    pub const dent_windscreen: u8 = 16;

    pub fn trailerId(v: *const Vehicle) EntityId {
        return if (v.trailer_ref == 0) .none else .{ .raw = v.trailer_ref -% 1 };
    }
    pub fn towId(v: *const Vehicle) EntityId {
        return if (v.tow_ref == 0) .none else .{ .raw = v.tow_ref -% 1 };
    }
    pub fn setTrailer(v: *Vehicle, e: EntityId) void {
        v.trailer_ref = if (e.isNone()) 0 else e.raw +% 1;
    }
    pub fn setTow(v: *Vehicle, e: EntityId) void {
        v.tow_ref = if (e.isNone()) 0 else e.raw +% 1;
    }

    pub const reverse_base: u16 = 1000;
    pub const plan_in_junction: u8 = 0x80;
};
