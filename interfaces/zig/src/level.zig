//! Static level data handed to the sim next to the `Grid`, outside the saved
//! state (W0 of docs/plan-notes.md). Not part of I1: owned by `sim/`,
//! built by `formats/` (or by tests and tools by hand), read only by the sim
//! through `Sim.attachLevel`. Every host in a session must attach the same
//! level, like the grid. The slices are owned by the host and must outlive
//! the sim.
//!
//! Zone types follow the public GTA2 map format document.

const abi = @import("abi.zig");
const Fx = abi.Fx;

pub const ZoneKind = enum(u8) {
    general_purpose = 0,
    navigation = 1,
    traffic_light = 2,
    arrow_blocker = 5,
    railway_station = 6,
    bus_stop = 7,
    general_trigger = 8,
    information = 10,
    railway_station_entry = 11,
    railway_station_exit = 12,
    railway_stop = 13,
    gang = 14,
    local_navigation = 15,
    restart = 16,
    arrest_restart = 20,
    _,
};

/// A map zone, in blocks.
pub const Zone = struct {
    kind: ZoneKind,
    x: u8,
    y: u8,
    w: u8,
    h: u8,
    /// The zone's name, as in the map (scripts and gang info refer to it).
    name: []const u8,

    pub fn contains(z: Zone, bx: i32, by: i32) bool {
        return bx >= z.x and by >= z.y and bx < @as(i32, z.x) + z.w and by < @as(i32, z.y) + z.h;
    }
};

/// A map object placed by the map itself (not the script).
pub const MapObject = struct {
    /// Position in blocks (fixed point, as the sim's).
    x: Fx,
    y: Fx,
    /// Binary angle, as `Transform.heading`.
    heading: u16,
    object_type: u8,
};

/// A map light (drawn by the client; the sim's light cycle may switch it).
pub const Light = struct {
    argb: u32,
    x: Fx,
    y: Fx,
    z: Fx,
    radius: Fx,
    intensity: u8,
    shape: u8,
    on_time: u8,
    off_time: u8,
};

/// A compiled mission script (`.scr`) as loaded by `formats/scr.zig`
/// (workstream A1). W0 fixes only the container; A1 defines how the bytes
/// are read.
pub const Script = struct {
    /// The command area (up to 64 KB).
    code: []const u8 = &.{},
    /// Offsets of numbered commands into `code`, indexed by command number.
    pointers: []const u16 = &.{},
    /// The script's own string table (names, not the `.gxt` text).
    strings: []const u8 = &.{},
};

pub const Level = struct {
    /// The main script; empty when the level has none (deathmatch).
    script: Script = .{},
    /// Mission sub-scripts, indexed by mission number.
    missions: []const Script = &.{},
    zones: []const Zone = &.{},
    objects: []const MapObject = &.{},
    lights: []const Light = &.{},

    pub const empty: Level = .{};

    /// The first zone of `kind` containing block (bx, by), if any.
    pub fn zoneAt(l: *const Level, kind: ZoneKind, bx: i32, by: i32) ?*const Zone {
        for (l.zones) |*z| if (z.kind == kind and z.contains(bx, by)) return z;
        return null;
    }
};
