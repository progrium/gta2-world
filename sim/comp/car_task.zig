//! The `CarTask` component (single player only, W0). Owned by workstream F
//! (traffic, car tasks and spawning); others give cars tasks through the
//! `car_tasks` API (`ai/car_tasks.zig`).

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const CarTask = extern struct {
    pub const id = abi.ComponentId.car_task;
    /// The car or ped to chase or follow, or none.
    target: EntityId = .none,
    /// Point target, in fx blocks.
    x: i32 = 0,
    y: i32 = 0,
    /// `ai/car_tasks.zig` `Task`.
    task: u8 = 0,
    /// Set once the task's target is reached.
    arrived: u8 = 0,
    timer: u16 = 0,
};
