//! The `Object` component on the `map_object` kind (single player only,
//! W0). Owned by workstream B (objects and city furniture): phones, doors,
//! generators, crossing markers, lamps, oil patches, mines, crushers.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Object = extern struct {
    pub const id = abi.ComponentId.object;
    /// `ids.ObjectKind`.
    kind: u8 = 0,
    /// The object model (the map or script's object type).
    model: u8 = 0,
    /// Per-kind state (door open/closed, phone ringing, ...).
    state: u8 = 0,
    /// The value byte from the script declaration.
    value: u8 = 0,
    /// Per-kind countdown in ticks.
    timer: u16 = 0,
    /// Per-kind extra (a mine's arming countdown, a crusher's shrink).
    aux: u16 = 0,
    /// Who placed or last used it (a mine's layer, a phone's caller).
    owner: EntityId = .none,
};
