//! The traffic light cycle and lamps (traffic-and-car-ai.md 3.6). Owner:
//! workstream B. W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

/// In the SP state block (`state.sp.lights`).
pub const State = extern struct {
    /// Ticks into the light cycle (526 ticks a cycle, per the note).
    cycle: u16 = 0,
    flags: u16 = 0,
};

/// What a traffic light shows a lane.
pub const Light = enum(u8) { none, green, amber, red };

pub fn Sys(comptime Self: type) type {
    return struct {
        /// The light a car heading `dir` (0 +x, 1 +y, 2 -x, 3 -y) sees at
        /// block (bx, by).
        pub fn lightState(self: *const Self, bx: i32, by: i32, dir: u2) Light {
            _ = .{ self, bx, by, dir };
            return .none;
        }
        pub fn sysLights(self: *Self) void {
            _ = self;
        }
    };
}
