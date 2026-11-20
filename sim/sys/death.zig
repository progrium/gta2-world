//! Wasted and busted (single player): body double, lives, losing weapons,
//! jail cards, game over, nearest restart zone. Owner: workstream G
//! (power-ups-death-and-arrest.md 3.2-3.4). W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        pub fn sysDeath(self: *Self) void {
            _ = self;
        }
    };
}
