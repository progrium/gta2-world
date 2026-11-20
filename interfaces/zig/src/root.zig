//! The three frozen interfaces, importable as one module.
pub const abi = @import("abi.zig");
pub const input = @import("input.zig");
pub const wire = @import("wire.zig");

test {
    _ = abi;
    _ = input;
    _ = wire;
    _ = @import("stub.zig");
    _ = @import("vectors.zig");
}
