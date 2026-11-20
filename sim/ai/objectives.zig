//! Ped objectives (single player): the two-layer objective system
//! (ped-ai.md 3.1). Owner: workstream D1; A2, D2 and E call this API and
//! never write `c.Objective` themselves. W0 stub.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

/// Objective kinds. D1 owns the numbering; append only once others use it.
pub const Kind = enum(u8) {
    none = 0,
    wait = 1,
    go_to = 2,
    wander = 3,
    follow = 4,
    kill_ped = 5,
    kill_car = 6,
    flee_ped = 7,
    flee_till_safe = 8,
    enter_car = 9,
    leave_car = 10,
    guard = 11,
    destroy_car = 12,
    patrol = 13,
    drive_to = 14,
    steal_car = 15,
    _,
};

pub const Status = enum(u8) { none = 0, active = 1, passed = 2, failed = 3 };

pub const Objective = struct {
    kind: Kind = .none,
    target: EntityId = .none,
    x: Fx = 0,
    y: Fx = 0,
    z: Fx = 0,
    /// Give up after this many ticks (0 = never).
    timeout: u16 = 0,
};

pub fn Sys(comptime Self: type) type {
    return struct {
        /// Set a ped's main objective (resets its status to active).
        pub fn setObjective(self: *Self, ped: EntityId, o: Objective) void {
            _ = .{ self, ped, o };
        }
        /// Set a ped's internal (reactive) objective.
        pub fn setInternalObjective(self: *Self, ped: EntityId, o: Objective) void {
            _ = .{ self, ped, o };
        }
        pub fn clearObjective(self: *Self, ped: EntityId) void {
            _ = .{ self, ped };
        }
        pub fn objectiveOf(self: *const Self, ped: EntityId) Objective {
            _ = .{ self, ped };
            return .{};
        }
        pub fn objectiveStatus(self: *const Self, ped: EntityId) Status {
            _ = .{ self, ped };
            return .none;
        }
        pub fn setOccupation(self: *Self, ped: EntityId, o: ids.Occupation) void {
            _ = .{ self, ped, o };
        }
        /// Every ped's objectives, once a tick (ped-ai.md 4).
        pub fn sysObjectives(self: *Self) void {
            _ = self;
        }
    };
}
