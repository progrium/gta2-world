//! The mission script VM (single player): threads, one command a tick,
//! triggers, the fail-on-death-or-arrest unwind. Owner: workstream A1
//! (mission-scripts.md, script-flow-control.md, script-counters.md,
//! script-messages.md, script-missions.md). W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

/// In the SP state block (`state.sp.script`). A1 sizes the thread table
/// and the handle table.
pub const State = extern struct {
    /// Live threads.
    threads: u16 = 0,
    /// The mission running (0 = none).
    mission: u16 = 0,
    flags: u32 = 0,
};

pub fn Sys(comptime Self: type) type {
    return struct {
        /// Run every script thread one step.
        pub fn sysScript(self: *Self) void {
            _ = self;
        }
    };
}
