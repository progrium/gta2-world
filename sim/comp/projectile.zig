//! The `Projectile` component. Re-exported from `components.zig`.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

/// A projectile, or an explosion (`weapon` has `explosion_bit` set; it
/// stays put for its 99-tick timer in `ttl`, and `owner` is credited).
pub const Projectile = extern struct {
    pub const id = abi.ComponentId.projectile;
    owner: EntityId,
    ttl: u16,
    /// Unused (kept for the layout).
    damage: u16,
    /// Index into `tuning.weapons` of the weapon that fired it, or
    /// `explosion_bit` | the explosion kind (0 small, 1 car).
    weapon: u8,
    _pad: u8 = 0,
    _pad2: u16 = 0,

    pub const explosion_bit: u8 = 0x40;
    /// `damage` on a projectile that is only drawn (an electric arc).
    pub const visual: u16 = 1;
};
