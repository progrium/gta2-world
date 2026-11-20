//! The `Collider` component. Re-exported from `components.zig`.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

/// Dynamic collision state. Shape comes from the kind and model.
pub const Collider = extern struct {
    pub const id = abi.ComponentId.collider;
    /// Not collidable and not moved by physics (a ped riding a car).
    pub const flag_disabled: u32 = 1;
    /// Standing on a floor at the end of the last step.
    pub const flag_grounded: u32 = 2;
    flags: u32,
};
