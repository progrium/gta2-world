//! Component types. The ones other workstreams read (`Transform`, `Velocity`,
//! `Health`, `Controller`, `Riding`, `Predicted`) are the frozen I1 types,
//! re-exported. The rest are owned by `sim/` and may change freely; their
//! layout reaches other parties only through `layout_hash` and generated
//! codecs. Every component is an extern struct of fixed-size integers whose
//! size is a multiple of 4, with `pub const id: abi.ComponentId`.
//!
//! Constant per-kind or per-model data (radii, masses, handling) is kept out
//! of components so it costs no snapshot bytes; see `tuning.zig`.

const abi = @import("interfaces").abi;
const EntityId = abi.EntityId;

pub const Transform = abi.Transform;
pub const Velocity = abi.Velocity;
pub const Health = abi.Health;
pub const Controller = abi.Controller;
pub const Riding = abi.Riding;
pub const Predicted = abi.Predicted;

pub const Collider = @import("comp/collider.zig").Collider;
pub const Vehicle = @import("comp/vehicle.zig").Vehicle;
pub const Pedestrian = @import("comp/pedestrian.zig").Pedestrian;
pub const Weapon = @import("comp/weapon.zig").Weapon;

/// What to draw: I1 component 12, accepted 2026-11-20. The layout is frozen
/// in `abi.Appearance`. `sprite` is the car model for cars and the ped type
/// for peds (0 for now; the walk cycle comes from `Pedestrian.anim` and time
/// on the client, so it costs no snapshot bytes). `remap` is a palette remap,
/// `no_remap` for none.
pub const Appearance = abi.Appearance;

pub const Projectile = @import("comp/projectile.zig").Projectile;
