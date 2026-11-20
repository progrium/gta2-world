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
    _ = @import("test/bodies_void.zig");
    _ = @import("test/police_wanted.zig");
    _ = @import("test/career.zig");
    _ = @import("test/script_world_cmds.zig");
}
