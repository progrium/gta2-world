//! Names shared by `sim.zig` and every file in `sys/`: the imports, the
//! fixed-point and id types, and the numbers that must never collide
//! between files (the `abi.rand` salts and the scratch buffer sizes).
//!
//! Salts: one per call site. A new call site takes a new salt from the
//! range reserved for its workstream (see `ids.zig`), never a used one,
//! so adding a system never changes the random numbers of another.

const ifaces = @import("interfaces");
pub const abi = ifaces.abi;
pub const input = ifaces.input;
pub const fx = @import("fixed.zig");
pub const ecs = @import("ecs.zig");
pub const map = @import("map.zig");
pub const c = @import("components.zig");
pub const T = @import("tuning.zig");

pub const Fx = fx.Fx;
pub const EntityId = abi.EntityId;
pub const Frame = input.Frame;
pub const Button = input.Button;
pub const eql = ecs.eql;

// Salts for abi.rand, one per call site.
pub const salt_spawn_x: u32 = 0x100;
pub const salt_spawn_y: u32 = 0x200;
pub const salt_near_x: u32 = 0x500;
pub const salt_near_y: u32 = 0x580;
pub const salt_ai_timer: u32 = 0x300;
pub const salt_ai_turn: u32 = 0x301;
pub const salt_car_model: u32 = 0x400;
pub const salt_jitter: u32 = 0x600;
pub const salt_pickup_kind: u32 = 0x700;
pub const salt_pickup_player: u32 = 0x701;
pub const salt_ai_plan: u32 = 0x800;
pub const salt_ambient_player: u32 = 0x900;

pub const max_intents = 64;
pub const max_events = 32;
