//! Route planning over the road grid. Owner: workstream F. W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        /// The next road direction (0 +x, 1 +y, 2 -x, 3 -y) from block
        /// (bx, by) at level bz toward (tx, ty), or null if there is none.
        /// Deterministic and bounded per call.
        pub fn nextRoadDir(self: *const Self, bx: i32, by: i32, bz: i32, tx: i32, ty: i32) ?u2 {
            _ = .{ self, bx, by, bz, tx, ty };
            return null;
        }
    };
}
