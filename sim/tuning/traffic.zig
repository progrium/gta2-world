//! Tuning: Traffic (traffic-and-car-ai.md).
//! Re-exported from `tuning.zig`; see the conventions there.

const std = @import("std");
const fx = @import("../fixed.zig");
const Fx = fx.Fx;

/// Of the ambient cars, this many in 8 drive (the rest are parked; ours).
pub const traffic_8ths: u32 = 5;
/// Speed setting: default target 0.1 a tick, rising 0.01 a tick, falling
/// 0.08 a tick when above the target.
pub const traffic_speed = fx.ratio(1, 10);
pub const traffic_accel = fx.ratio(1, 100);
pub const traffic_decel = fx.ratio(8, 100);
/// Look-ahead: 1.75 blocks ahead (1 while turning), then 1.
pub const traffic_look = fx.ratio(175, 100);
pub const traffic_look_turning = fx.one;
pub const traffic_look_side = fx.ratio(45, 100);
/// Above this speed a car braking for something ahead also uses the
/// handbrake.
pub const traffic_handbrake_speed = fx.ratio(4, 10);
/// Ticks an AI driver stops for after hitting a pedestrian.
pub const traffic_hit_stop: u16 = 100;
/// Junction probe: how far ahead the straight-on check looks.
pub const traffic_junction_probe = fx.ratio(8, 10);
/// Ticks spent backing out once blocked at a standstill (the notes back out
/// until reversing speed reaches the setting; ours bounds it).
pub const traffic_reverse_ticks: u16 = 25;
pub const traffic_stuck_ticks: u16 = 10;
