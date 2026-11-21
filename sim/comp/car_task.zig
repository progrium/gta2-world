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
    /// Ticks until the route is planned again.
    timer: u16 = 0,
    /// Preferred speed (fx blocks a tick); 0 is the task's default.
    speed: u16 = 0,
    /// The routed direction (0 +x, 1 +y, 2 -x, 3 -y), or `no_dir`.
    route_dir: u8 = no_dir,
    /// `flag_*`.
    flags: u8 = 0,
    /// Packed road cell (x | y << 8 | level << 16) the route was planned
    /// from, plus one (0: never planned).
    route_from: u32 = 0,
    /// Packed goal block the route was planned to, plus one.
    route_to: u32 = 0,
    /// Ticks spent off the road (for the snap to the nearest road).
    lost: u16 = 0,
    /// The routed direction out of the next block: a turn coming up when
    /// it differs from `route_dir`.
    next_dir: u8 = no_dir,
    /// And out of the block after that.
    third_dir: u8 = no_dir,

    pub const no_dir: u8 = 0xFF;
    /// Snap to the road after 100 ticks off it, not 300 (a cop car, or any
    /// car once a pursuit is at three stars; police-ai.md 3.1).
    pub const flag_fast_snap: u8 = 1;
    /// The target is a ped to kill: don't slow for it either (3.7).
    pub const flag_kill_target: u8 = 2;
    /// May enter against-the-flow cells heading south (3.7). Set for chase.
    pub const flag_against_flow: u8 = 4;
};
