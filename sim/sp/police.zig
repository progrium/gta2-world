//! Police (single player): dispatch, crews, roadblocks, arrests. Owner:
//! workstream E (police-ai.md). W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

/// In the SP state block (`state.sp.police`).
pub const State = extern struct {
    /// Ticks until the next dispatch decision.
    dispatch_timer: u16 = 0,
    crews: u8 = 0,
    flags: u8 = 0,
};

pub fn Sys(comptime Self: type) type {
    return struct {
        pub fn sysPolice(self: *Self) void {
            _ = self;
        }
    };
}
