//! Car tasks (single player): chase, follow, patrol, go to, park, stop.
//! Owner: workstream F (traffic-and-car-ai.md 3.7); A2 and E call this
//! API. W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

pub const Task = enum(u8) { none = 0, wander = 1, chase = 2, follow = 3, patrol = 4, go_to = 5, park_in_garage = 6, stop = 7, _ };

pub fn Sys(comptime Self: type) type {
    return struct {
        /// Give a car a task toward `target` (an entity) or (x, y).
        pub fn setCarTask(self: *Self, car: EntityId, task: Task, target: EntityId, x: Fx, y: Fx) void {
            _ = .{ self, car, task, target, x, y };
        }
        pub fn carTaskOf(self: *const Self, car: EntityId) Task {
            _ = .{ self, car };
            return .none;
        }
        pub fn carArrived(self: *const Self, car: EntityId) bool {
            _ = .{ self, car };
            return false;
        }
        /// Car tasks, once a tick, after the traffic AI.
        pub fn sysCarTasks(self: *Self) void {
            _ = self;
        }
    };
}
