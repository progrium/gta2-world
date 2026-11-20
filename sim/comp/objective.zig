//! The `Objective` component (single player only, W0). Owned by
//! workstream D1 (ped AI core); others set objectives through the
//! `objectives` API (`ai/objectives.zig`), never by writing this.
//!
//! Every field here is per-ped AI memory that has to survive from one tick
//! to the next (so it is saved state). Not replicated.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Objective = extern struct {
    pub const id = abi.ComponentId.objective;
    /// Target of the main objective: a ped, a car or an object, or none.
    main_target: EntityId = .none,
    /// Target of the internal (reactive) objective.
    internal_target: EntityId = .none,
    /// Whoever hit this ped last and is still remembered (ped-ai.md 3.6).
    attacker: EntityId = .none,
    /// The ped this one last punched, until a script reads and clears it
    /// (script-characters.md 2.7).
    punched: EntityId = .none,
    /// Point target of the main objective, in fx blocks.
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    /// Point of the internal objective: where a flee started, in fx blocks.
    ix: i32 = 0,
    iy: i32 = 0,
    /// Health as last seen, to notice a fresh hit.
    prev_hp: i32 = 0,
    /// Ticks left before the main objective gives up (0 = no timeout).
    timeout: u16 = 0,
    internal_timeout: u16 = 0,
    /// Handler scratch that lasts across ticks: the follow wait counter,
    /// the test-shot wait, a throw's wind-up.
    wait: u16 = 0,
    /// Ticks until the next threat search or mug (staggers the work).
    think: u16 = 0,
    /// `ai/objectives.zig` `Kind` of each layer.
    main: u8 = 0,
    internal: u8 = 0,
    /// `ai/objectives.zig` `Status` of the main objective.
    status: u8 = 0,
    /// `ids.Occupation`.
    occupation: u8 = 0,
    /// `ai/threat.zig` `Search` and `Reaction`.
    search: u8 = 0,
    reaction: u8 = 0,
    /// `flag_*`.
    flags: u16 = 0,
    /// Successful mugs (a mugger retires after more than 9).
    mugs: u8 = 0,
    /// Ticks the remembered attacker has been out of sight (5 drops it for
    /// a player-led group member).
    unseen: u8 = 0,
    /// Peds currently attacking this one, and ever (each capped at 255).
    attackers: u8 = 0,
    attackers_ever: u8 = 0,
    /// Aim offset for the next shot (angle units / 64, signed).
    jitter: i8 = 0,
    /// Ticks left retreating after landing a hit (hit-and-run).
    retreat: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },

    /// Set by the objectives system on a tick it wrote this ped's
    /// controls; the ambient wanderer leaves such a ped alone.
    pub const flag_steered: u16 = 1 << 0;
    /// The component has been given its defaults (zeroed spawns).
    pub const flag_init: u16 = 1 << 1;
    /// Invisibility power-up (ped-ai.md 3.15).
    pub const flag_invisible: u16 = 1 << 2;
    /// Electro-fingers power-up (ped-ai.md 3.14).
    pub const flag_electro_fingers: u16 = 1 << 3;
    /// Has spotted the player (script-characters.md 2.9, type 251).
    pub const flag_spotted_player: u16 = 1 << 4;
    /// Currently attacking someone (fire held or swinging).
    pub const flag_attacking: u16 = 1 << 5;
    /// Panicking: running from danger.
    pub const flag_panic: u16 = 1 << 6;
    /// Firing invisible test shots until one would reach the target
    /// (weapons.md 3.8).
    pub const flag_test_shots: u16 = 1 << 7;
    /// Always accurate: no aim jitter (ped-ai.md 3.8 fire mode).
    pub const flag_accurate: u16 = 1 << 8;
    /// Retreats after landing a hit (ped-ai.md 3.7, per-ped).
    pub const flag_hit_and_run: u16 = 1 << 9;
    /// Holds the police "one firing at a time" turn (ped-ai.md 3.8).
    pub const flag_firing_turn: u16 = 1 << 10;
    /// The internal objective's target was the main objective's own
    /// target (a punch then keeps swinging past a knock-down, 3.9).
    pub const flag_assigned_target: u16 = 1 << 11;
    /// The threat reaction was set explicitly (script), not by occupation.
    pub const flag_reaction_set: u16 = 1 << 12;
};
