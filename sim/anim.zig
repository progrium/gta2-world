//! Ped animation frame timing (W0 of docs/plan-notes.md 3.9). The notes
//! count some rules in animation frames (fall damage on frames 12-14,
//! door entry, melee) but leave each frame's length open until the
//! animation-timing note lands. These delays are ours, tagged "ours", and
//! every system that counts frames reads them from here so one change
//! re-times them all.

/// Ticks per frame, per animation. Ours.
pub const ticks_per_frame = struct {
    pub const walk: u8 = 2; // ours
    pub const run: u8 = 2; // ours
    pub const jump: u8 = 2; // ours
    pub const fall: u8 = 2; // ours
    pub const enter_car: u8 = 2; // ours
    pub const exit_car: u8 = 2; // ours
    pub const punch: u8 = 2; // ours
    pub const get_up: u8 = 3; // ours
    pub const drown: u8 = 3; // ours
};

/// Frame counts the notes give.
pub const frames = struct {
    /// ped-movement.md 3.5: frames 12 and 13 of a fall deal 4, frame 14 is
    /// lethal.
    pub const fall_hurt_first: u8 = 12;
    pub const fall_lethal: u8 = 14;
};

/// The frame reached after `ticks` in an animation of `per_frame` ticks.
pub fn frameAt(ticks: u16, per_frame: u8) u16 {
    return ticks / @max(per_frame, 1);
}
