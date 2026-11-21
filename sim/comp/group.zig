//! The `Group` component (single player only, W0): a ped's group and place
//! in its formation. Owned by workstream D2 (gangs, groups, getting in
//! cars); see `ai/groups.zig`.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Group = extern struct {
    pub const id = abi.ComponentId.group;
    /// The group's leader, or none (a leader, or a ped in no group).
    leader: EntityId = .none,
    /// `ids.gang_none` or a gang index.
    gang: u8 = 0xFF,
    /// Place in the formation, 1-8 for a follower (0 for none).
    slot: u8 = 0,
    flags: u16 = 0,

    /// On a leader: followers form a nose-to-tail chain instead of the
    /// normal wedge (ped-ai.md 3.11).
    pub const flag_chain: u16 = 1;
    /// A recruited follower (the "follower" ped type of 3.11).
    pub const flag_follower: u16 = 2;
    /// Cannot jump over obstacles (recruits).
    pub const flag_no_jump: u16 = 4;
    /// Sent into a group-wide attack (3.12): the 4-block check applies.
    pub const flag_fighting: u16 = 8;
    /// Not a gang member: a background ped whose kill counts for the gang
    /// owning the zone it spawned in (3.13). `gang` is that gang.
    pub const flag_turf: u16 = 16;
};
