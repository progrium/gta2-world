//! The three frozen interfaces, importable as one module.
pub const abi = @import("abi.zig");
pub const input = @import("input.zig");
pub const wire = @import("wire.zig");
/// Static level data for the sim (not frozen; owned by `sim/`).
pub const level = @import("level.zig");

test {
    _ = abi;
    _ = input;
    _ = wire;
    _ = level;
    _ = @import("stub.zig");
    _ = @import("vectors.zig");
}
