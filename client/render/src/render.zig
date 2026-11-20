//! Workstream B: everything between the sim's state and WebGL2 that is not
//! TypeScript. See ../README.md.

pub const mesh = @import("mesh.zig");
pub const style = @import("style.zig");
pub const list = @import("list.zig");
pub const stub = @import("stub.zig");

test {
    _ = mesh;
    _ = style;
    _ = list;
    _ = stub;
}
