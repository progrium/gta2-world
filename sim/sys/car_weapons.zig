//! Vehicle weapons and the electro baton (weapons.md 3.6-3.7). Owner:
//! workstream G (drops B's oil and mine objects). W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        pub fn sysCarWeapons(self: *Self) void {
            _ = self;
        }
    };
}
