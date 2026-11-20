//! Objects and city furniture: phones, doors, generators, crushers,
//! conveyors, oil and mines. Owner: workstream B (crushers-and-garages.md,
//! script-objects.md, script-declarations.md). W0 stub; B may split it
//! into doors.zig, generators.zig, crusher.zig.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        /// Place an object (`ids.ObjectKind`, `model` is the object type).
        pub fn spawnObject(self: *Self, kind: ids.ObjectKind, model: u8, x: Fx, y: Fx, z: Fx, heading: u16) ?EntityId {
            _ = .{ self, kind, model, x, y, z, heading };
            return null;
        }
        pub fn removeObject(self: *Self, id: EntityId) void {
            _ = .{ self, id };
        }
        pub const DoorMode = enum(u8) { closed, open, auto };
        pub fn setDoor(self: *Self, door: EntityId, mode: DoorMode) void {
            _ = .{ self, door, mode };
        }
        pub fn ringPhone(self: *Self, phone: EntityId, on: bool) void {
            _ = .{ self, phone, on };
        }
        pub fn phoneAnswered(self: *const Self, phone: EntityId) bool {
            _ = .{ self, phone };
            return false;
        }
        pub fn setGenerator(self: *Self, gen: EntityId, on: bool) void {
            _ = .{ self, gen, on };
        }
        /// Start a crusher's cycle on the car on it, if any.
        pub fn runCrusher(self: *Self, crusher: EntityId) void {
            _ = .{ self, crusher };
        }
        /// Doors, generators, crushers, conveyors, oil and mines, once a tick.
        pub fn sysObjects(self: *Self) void {
            _ = self;
        }
    };
}
