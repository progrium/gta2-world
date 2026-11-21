//! The server's session code as a module, for hosts other than
//! `gta2-server` (the browser host in host/, built for wasm32-freestanding).
//!
//! Everything here builds without libc when the target is freestanding:
//! util.zig then takes time and entropy from its embedder and the
//! file/socket helpers are refused at run time. Imports needed: "interfaces"
//! and "formats" (no "c", no transports).

pub const net = @import("net.zig");
pub const util = @import("util.zig");
pub const maps = @import("maps.zig");
pub const replay = @import("replay.zig");
pub const snapshot = @import("snapshot.zig");
pub const session = @import("session.zig");
pub const manager = @import("manager.zig");
