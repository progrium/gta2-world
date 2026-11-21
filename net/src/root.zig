//! Workstream C netcode, generic over any I1 sim type.
pub const testsim = @import("testsim.zig");
pub const schema = @import("schema.zig");
pub const encoder = @import("encoder.zig");
pub const decoder = @import("decoder.zig");
pub const inputbuf = @import("inputbuf.zig");
pub const client = @import("client.zig");
pub const link = @import("link.zig");

test {
    _ = testsim;
    _ = schema;
    _ = encoder;
    _ = decoder;
    _ = inputbuf;
    _ = client;
    _ = link;
    _ = @import("tests.zig");
}
