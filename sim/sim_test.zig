//! Gameplay and I1 tests, one file per area in test/.

test {
    _ = @import("test/core.zig");
    _ = @import("test/peds.zig");
    _ = @import("test/cars.zig");
    _ = @import("test/weapons.zig");
    _ = @import("test/traffic.zig");
    _ = @import("test/scoring.zig");
    _ = @import("test/surfaces.zig");
    _ = @import("test/sp.zig");
    _ = @import("test/enter_exit_cars.zig");
    _ = @import("test/gangs_respect.zig");
    _ = @import("test/gangs_groups.zig");
    _ = @import("test/bodies_void.zig");
    _ = @import("test/police_wanted.zig");
    _ = @import("test/dm_police.zig");
    _ = @import("test/career.zig");
    _ = @import("test/script_world_cmds.zig");
    _ = @import("test/objects_furniture.zig");
    _ = @import("test/ped_ai_objectives.zig");
    _ = @import("test/ped_ai_threat.zig");
    _ = @import("test/ped_ai_combat.zig");
    _ = @import("test/script_vm.zig");
    _ = @import("test/traffic_rules.zig");
    _ = @import("test/traffic_spawn.zig");
    _ = @import("test/shops.zig");
    _ = @import("test/vehicles.zig");
}
