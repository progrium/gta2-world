//! Parsers for GTA2 data files. Pure functions over byte slices, usable from
//! the sim, the WASM client and native tools. See README.md.

pub const chunk = @import("chunk.zig");
pub const gmp = @import("gmp.zig");
pub const sty = @import("sty.zig");
pub const synth = @import("synth.zig");
pub const grid = @import("grid.zig");
pub const gci = @import("gci.zig");
pub const cars = @import("cars.zig");

test {
    _ = chunk;
    _ = gmp;
    _ = sty;
    _ = synth;
    _ = grid;
}
