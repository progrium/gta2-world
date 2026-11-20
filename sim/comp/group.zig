//! The `Group` component (single player only, W0): a ped's group and place
//! in its formation. Owned by workstream D2 (gangs, groups, getting in
//! cars).

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Group = extern struct {
    pub const id = abi.ComponentId.group;
    /// The group's leader, or none.
    leader: EntityId = .none,
    /// `ids.gang_none` or a gang index.
    gang: u8 = 0xFF,
    /// Place in the formation.
    slot: u8 = 0,
    flags: u16 = 0,
};
