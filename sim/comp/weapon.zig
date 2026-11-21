//! The `Weapon` component. Re-exported from `components.zig`.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

/// On a ped: the weapon in hand and the ammo held for each weapon, in tenths
/// of a displayed round. On a pickup: what it gives (`kind`) and `cooldown`
/// is the ticks left before it disappears.
pub const Weapon = extern struct {
    pub const id = abi.ComponentId.weapon;
    cooldown: u16,
    /// Index into `tuning.weapons`, or `tuning.pickup_health` on a pickup.
    kind: u8,
    _pad: u8 = 0,
    /// Ammo per weapon in tenths (`rounds()`); `tuning.infinite_ammo` never
    /// runs out. Separate fields because the I3 codecs take scalars only.
    a0: u16,
    a1: u16,
    a2: u16,
    a3: u16,
    a4: u16 = 0,
    a5: u16 = 0,
    a6: u16 = 0,
    a7: u16 = 0,
    a8: u16 = 0,
    a9: u16 = 0,

    pub fn rounds(self: *Weapon) *[10]u16 {
        return @ptrCast(&self.a0);
    }
    pub fn roundsConst(self: *const Weapon) *const [10]u16 {
        return @ptrCast(&self.a0);
    }
};
