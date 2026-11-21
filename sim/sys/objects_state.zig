//! The objects sub-struct of the SP state block (`state.sp.objects`).
//! Owner: workstream B. Tables for the things that carry more data than
//! the `Object` component holds: doors, generators, conveyor and
//! destructor areas, plus the level-wide door animations, dead phones and
//! car list. Every table entry points back at the map object that stands
//! for it (`obj`), and that object's `Object.value` is the entry's index,
//! so scripts hold ordinary entity handles. No implicit padding anywhere:
//! the state is hashed byte for byte.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;
const Fx = abi.Fx;
const OT = @import("../tuning/objects.zig");

/// One shared door animation (script-declarations.md 2.9, type 230).
pub const DoorAnim = extern struct {
    /// Frame numbers (levels use values above 255).
    start: u16 = 0,
    end: u16 = 0,
    /// Ticks per frame (ours: the note says "playback speed").
    speed: u8 = 0,
    used: u8 = 0,
    _pad: u16 = 0,
};

/// Door open rules, in the order script-declarations.md 2.9 lists them
/// (the numbering is ours until the script values are confirmed; levels
/// use 0, 2, 4 and 6).
pub const OpenRule = enum(u8) {
    any_player = 0,
    any_car = 1,
    one_car = 2,
    car_model = 3,
    one_char_on_foot = 4,
    player_plus_car = 5,
    unknown = 6,
    _,
};

/// Door close rules, in the note's order (numbering ours).
pub const CloseRule = enum(u8) {
    never = 0,
    after_delay = 1,
    area_clear = 2,
    rule_false = 3,
    _,
};

pub const DoorState = enum(u8) { closed = 0, opening = 1, open = 2, closing = 3, _ };

/// A face of a block: the wall line the door fills.
pub const Face = enum(u8) { west = 0, east = 1, north = 2, south = 3, _ };

pub const Door = extern struct {
    /// The door's map object, or none for a free slot.
    obj: EntityId = .none,
    /// The car or character an open rule needs (one car, one character,
    /// player plus car).
    target: EntityId = .none,
    bx: u8 = 0,
    by: u8 = 0,
    bz: u8 = 0,
    face: u8 = 0,
    anim: u8 = 0,
    open_rule: u8 = 0,
    close_rule: u8 = 0,
    flags: u8 = 0,
    state: u8 = 0,
    /// Ticks into the current frame.
    frame_tick: u8 = 0,
    /// The car model for the `car_model` rule.
    target_model: u8 = 0,
    _pad: u8 = 0,
    /// The current animation frame (between the animation's start and end).
    frame: u16 = 0,
    /// Close delay for `after_delay`.
    delay: u16 = 0,
    /// Ticks since fully open.
    timer: u16 = 0,
    _pad2: u16 = 0,
    /// The presence-check area (blocks, fixed point); zero size skips it.
    area_x: Fx = 0,
    area_y: Fx = 0,
    area_w: Fx = 0,
    area_h: Fx = 0,

    pub const flag_flip: u8 = 1;
    pub const flag_reversed: u8 = 2;
    pub const flag_double: u8 = 4;
    /// Script control only (type 180); 179 clears it.
    pub const flag_manual: u8 = 8;
};

pub const Generator = extern struct {
    obj: EntityId = .none,
    /// The last thing it made (for one-at-a-time models).
    child: EntityId = .none,
    x: Fx = 0,
    y: Fx = 0,
    z: Fx = 0,
    heading: u16 = 0,
    min_delay: u16 = 0,
    max_delay: u16 = 0,
    timer: u16 = 0,
    /// Spawns left; `spawns_unlimited` for no limit.
    remaining: u16 = 0,
    /// Ammo override (0: the model's own).
    ammo: u16 = 0,
    model: u16 = 0,
    on: u8 = 0,
    one_at_a_time: u8 = 0,
};

pub const AreaKind = enum(u8) { none = 0, conveyor = 1, destructor = 2, _ };

pub const Area = extern struct {
    obj: EntityId = .none,
    /// Corner and size, blocks (fixed point); z is the floor it lies on.
    x: Fx = 0,
    y: Fx = 0,
    z: Fx = 0,
    w: Fx = 0,
    h: Fx = 0,
    /// Conveyor push, blocks per tick.
    vx: Fx = 0,
    vy: Fx = 0,
    kind: u8 = 0,
    _pad: [3]u8 = @splat(0),
};

pub const State = extern struct {
    flags: u32 = 0,
    anims: [OT.door_anims]DoorAnim = @splat(.{}),
    doors: [OT.max_doors]Door = @splat(.{}),
    gens: [OT.max_generators]Generator = @splat(.{}),
    areas: [OT.max_areas]Area = @splat(.{}),
    dead_phones: [OT.max_dead_phones]EntityId = @splat(.none),
    dead_len: u32 = 0,
    car_list: [OT.car_list_len]u8 = @splat(0),
    car_list_len: u8 = 0,

    /// The map's own objects have been placed.
    pub const flag_placed: u32 = 1;
};

comptime {
    // No implicit padding (hashing reads every byte).
    if (@sizeOf(Door) != 44 or @sizeOf(Generator) != 36 or @sizeOf(Area) != 36) @compileError("objects state padding");
    const sum = 4 + @sizeOf([OT.door_anims]DoorAnim) + @sizeOf([OT.max_doors]Door) + @sizeOf([OT.max_generators]Generator) +
        @sizeOf([OT.max_areas]Area) + @sizeOf([OT.max_dead_phones]EntityId) + 4 + OT.car_list_len + 1;
    if (sum != @sizeOf(State)) @compileError("objects State has implicit padding");
}
