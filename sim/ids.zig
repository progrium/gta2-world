//! Reserved shared numbers (W0 of docs/plan-notes.md). Every number two
//! workstreams could both pick is fixed here once, so parallel branches
//! never collide. Add a value only inside your own reserved range; change
//! a used one only through the merge train (workstream Q).
//!
//! Also reserved elsewhere, listed here so there is one place to look:
//!   - component ids 13-17: `abi.ComponentId` (object, objective, car_task,
//!     group, script_tag); the structs are in `comp/`.
//!   - event kinds 7-18: `wire.EventKind` and `Sim.Event.Kind` (message,
//!     brief, wanted, wasted, busted, mission start/pass/fail, phone ring,
//!     siren, game over, level complete).
//!   - `Pedestrian.state_*` 4-11 and `anim_*` 5-13: `comp/pedestrian.zig`.
//!   - `Grid.surface` bits: `abi.SurfaceBits`.

/// What a ped does for a living when it has no objective (ped-ai.md 3.2).
/// Stored in `Objective.occupation`. Owner: D1 (D2 for gang members, E for
/// police, F for drivers).
pub const Occupation = enum(u8) {
    civilian = 0,
    dummy = 1,
    mugger = 2,
    car_thief = 3,
    elvis = 4,
    gang_member = 5,
    police = 6,
    swat = 7,
    fbi = 8,
    army = 9,
    driver = 10,
    passenger = 11,
    emergency = 12,
    guard = 13,
    customer = 14,
    criminal = 15,
    player = 16,
    _,
};

/// `Object.kind` (owner: B; G drops oil and mines).
pub const ObjectKind = enum(u8) {
    none = 0,
    phone = 1,
    door = 2,
    generator = 3,
    crossing_marker = 4,
    lamp = 5,
    traffic_light = 6,
    oil = 7,
    mine = 8,
    crusher = 9,
    conveyor = 10,
    destructor = 11,
    decoration = 12,
    pickup = 13,
    /// A solid roadblock barrier (E places them; B makes them solid).
    barrier = 14,
    _,
};

/// No gang (`Group.gang`).
pub const gang_none: u8 = 0xFF;
/// Gangs a level can declare (script-declarations 2.11).
pub const max_gangs = 8;

/// `abi.rand` salt ranges, one per workstream (see `prelude.zig`). A new
/// call site takes the next unused salt in its range.
pub const salts = struct {
    pub const core = .{ 0x0000, 0x0FFF }; // today's salts, in prelude.zig
    pub const script = .{ 0x1000, 0x10FF }; // A1, A2
    pub const objects = .{ 0x1100, 0x11FF }; // B
    pub const bodies = .{ 0x1200, 0x12FF }; // C
    pub const ped_ai = .{ 0x1300, 0x13FF }; // D1
    pub const gangs = .{ 0x1400, 0x14FF }; // D2
    pub const police = .{ 0x1500, 0x15FF }; // E
    pub const traffic = .{ 0x1600, 0x16FF }; // F
    pub const career = .{ 0x1700, 0x17FF }; // G
};
