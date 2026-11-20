//! Script hooks: the calls other systems make when something a script may
//! wait on happens. Owner: workstream A1. W0 stub: each records nothing.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        /// A ped walked onto or answered a phone object.
        pub fn phoneTouched(self: *Self, phone: EntityId, ped: EntityId) void {
            _ = .{ self, phone, ped };
        }
        /// A ped got into a car (as driver or passenger).
        pub fn carEntered(self: *Self, car: EntityId, ped: EntityId) void {
            _ = .{ self, car, ped };
        }
        /// `id` was hit by weapon `weapon` (the kill event's numbering)
        /// fired by `by`: the per-entity record scripts test.
        pub fn entityHit(self: *Self, id: EntityId, weapon: u8, by: EntityId) void {
            _ = .{ self, id, weapon, by };
        }
        /// A car of model `model` was destroyed by `by`.
        pub fn carModelDestroyed(self: *Self, model: u8, by: EntityId) void {
            _ = .{ self, model, by };
        }
        /// A ped entered block (bx, by, bz); area triggers are polled by the
        /// VM, so this may stay empty.
        pub fn areaEntered(self: *Self, ped: EntityId, bx: i32, by_: i32, bz: i32) void {
            _ = .{ self, ped, bx, by_, bz };
        }
    };
}
