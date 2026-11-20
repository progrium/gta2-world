//! The `Objective` component (single player only, W0). Owned by
//! workstream D1 (ped AI core); others set objectives through the
//! `objectives` API (`ai/objectives.zig`), never by writing this.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Objective = extern struct {
    pub const id = abi.ComponentId.objective;
    /// Target of the main objective: a ped, a car or an object, or none.
    main_target: EntityId = .none,
    /// Target of the internal (reactive) objective.
    internal_target: EntityId = .none,
    /// Point target of the main objective, in fx blocks.
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    /// Ticks left before the main objective gives up (0 = no timeout).
    timeout: u16 = 0,
    internal_timeout: u16 = 0,
    /// `ai/objectives.zig` `Kind` of each layer.
    main: u8 = 0,
    internal: u8 = 0,
    /// `ai/objectives.zig` `Status` of the main objective.
    status: u8 = 0,
    /// `ids.Occupation`.
    occupation: u8 = 0,
};
