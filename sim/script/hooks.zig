//! Script hooks: the calls other systems make when something a script may
//! wait on happens (plan-notes.md 5). Owner: workstream A1. Each forwards
//! to the VM; outside single player they do nothing.

const prelude = @import("../prelude.zig");
const EntityId = prelude.EntityId;

pub fn Sys(comptime Self: type) type {
    return struct {
        /// A ped walked onto or answered a phone object (B). Call it every
        /// tick the ped touches the phone: a phone trigger fires on the
        /// first touch and again only after a tick without one.
        pub fn phoneTouched(self: *Self, phone: EntityId, ped: EntityId) void {
            if (comptime !Self.single_player) return;
            Self.script.onPhone(self, phone, ped);
        }
        /// A ped got into a car (as driver or passenger) (D2).
        pub fn carEntered(self: *Self, car: EntityId, ped: EntityId) void {
            if (comptime !Self.single_player) return;
            Self.script.onCarEntered(self, car, ped);
        }
        /// `id` was hit by weapon `weapon` (the kill event's numbering)
        /// fired by `by`: the per-entity record scripts test
        /// (mission-scripts.md 3.4). Only entities with a `ScriptTag`.
        pub fn entityHit(self: *Self, id: EntityId, weapon: u8, by: EntityId) void {
            if (comptime !Self.single_player) return;
            _ = by;
            Self.script.onEntityHit(self, id, weapon);
        }
        /// A car of model `model` was destroyed by `by` (G, C).
        pub fn carModelDestroyed(self: *Self, model: u8, by: EntityId) void {
            if (comptime !Self.single_player) return;
            Self.script.onCarModelDestroyed(self, model, by);
        }
        /// A ped was killed by `by` with cause `cause` (the kill event's
        /// weapon numbering) (G): counts toward bonus challenges.
        pub fn pedKilled(self: *Self, ped: EntityId, by: EntityId, cause: u8) void {
            if (comptime !Self.single_player) return;
            Self.script.onPedKilled(self, ped, by, cause);
        }
        /// A ped entered block (bx, by, bz); area triggers are polled by the
        /// VM, so this stays empty.
        pub fn areaEntered(self: *Self, ped: EntityId, bx: i32, by_: i32, bz: i32) void {
            _ = .{ self, ped, bx, by_, bz };
        }
    };
}
