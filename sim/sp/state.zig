//! The single-player state block (W0 of docs/plan-notes.md 3.6): one
//! sub-struct per workstream, each in its owner's file. Only `sp`
//! configurations carry it, at the end of `State`. A workstream adds
//! fields only to its own sub-struct.

pub const career = @import("career.zig");
pub const wanted = @import("wanted.zig");
pub const police = @import("police.zig");
pub const gangs = @import("gangs.zig");
pub const hud = @import("hud.zig");
pub const script = @import("../script/vm.zig");
pub const lights = @import("../sys/lights.zig");
pub const world = @import("../script/world.zig");
pub const objects = @import("../sys/objects_state.zig");
pub const traffic = @import("../sys/spawn.zig");
pub const vehicles = @import("../sys/cranes.zig");

pub fn SpState(comptime max_players: u16) type {
    return extern struct {
        career: [max_players]career.State, // G
        wanted: [max_players]wanted.State, // E
        hud: [max_players]hud.State, // A1
        police: police.State, // E
        gangs: gangs.State, // D2
        script: script.State, // A1
        lights: lights.State, // B
        world: world.State, // A2
        objects: objects.State, // B
        traffic: traffic.State, // F (zone spawn settings)
        vehicles: vehicles.State, // cranes (trailers, cranes and car flags)
    };
}
