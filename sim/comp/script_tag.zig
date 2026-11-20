//! The `ScriptTag` component (single player only, W0): marks an entity the
//! mission script holds a handle to, and how the script treats it. Owned by
//! workstream A1 (script engine); A2's commands set it.

const abi = @import("interfaces").abi;

pub const ScriptTag = extern struct {
    pub const id = abi.ComponentId.script_tag;
    /// The script handle number, 0 for none.
    handle: u16 = 0,
    /// `flag_*`.
    flags: u16 = 0,

    /// Not despawned by the ambient recycler.
    pub const flag_keep: u16 = 1;
    /// Cleaned up when its mission ends (script-missions.md, 391).
    pub const flag_mission: u16 = 2;
    /// Refused to everyone but the script (a locked car).
    pub const flag_locked: u16 = 4;
};
