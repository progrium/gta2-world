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

// ---------------------------------------------------------------------------
// Car tasks and the route planner (traffic-and-car-ai.md 3.7).

/// A* expansions per route plan (ours; enough for ~60 blocks of the test
/// grid).
pub const route_max_nodes: u32 = 3000;
/// A target off the road routes to the nearest road block within this many
/// blocks (ours).
pub const route_goal_radius: i32 = 8;
/// Route plans per tick across all task cars; the rest keep last tick's
/// direction (ours, for the step budget).
pub const route_plans_per_tick: u32 = 4;
/// A task car re-plans when it enters a new block, when its goal block
/// changes, or after this many ticks (ours).
pub const route_replan_ticks: u16 = 32;
/// Default preferred speeds (ours: the note says it comes from the driver's
/// stat, which no note gives): chase and follow, and go-to and patrol (the
/// ordinary default target).
pub const task_chase_speed = fx.ratio(25, 100);
pub const task_drive_speed = fx.ratio(1, 10);
/// The AI speed setting never exceeds 0.7 a tick.
pub const traffic_speed_max = fx.ratio(7, 10);
/// Off-road wait before a task car snaps to the nearest road point: 100
/// ticks (cop car, or three stars) or 300 (police-ai.md 3.1).
pub const task_snap_fast: u16 = 100;
pub const task_snap_slow: u16 = 300;
/// A snap happens only out of every player's sight: this many blocks
/// (Chebyshev) from each player (ours: about half a screen and a margin).
pub const offscreen_blocks: i32 = 12;
/// Go-to and patrol arrive within this many blocks (Chebyshev) of the
/// point (ours: a lane off the point's block still counts).
pub const task_arrive_blocks: i32 = 1;
/// Chase and follow steer straight at the target within this many blocks
/// on the same level (ours).
pub const task_direct_blocks: i32 = 3;
/// Follow keeps about this far behind its target (ours).
pub const task_follow_gap = fx.ratio(25, 10);
/// Patrol wanders after arriving, and routes back to its point when it is
/// more than this many blocks away (ours: the note gives no patrol beat).
pub const patrol_leash_blocks: i32 = 16;

// ---------------------------------------------------------------------------
// The rest of traffic-and-car-ai.md 3.3-3.5 (workstream F).

/// Off the road this long (seeking a road), an ordinary car gives up and
/// halts for good (3.3); script-created and task cars never do.
pub const traffic_give_up_ticks: u16 = 200;
/// The car-ahead reaction starts this many ticks after the AI takes a car.
pub const traffic_ahead_grace: u8 = 20;
/// While turning, the first probe is 1 block ahead and 8 degrees into the
/// turn (8 / 360 x 65536).
pub const traffic_turn_probe_angle: i32 = 1456;
/// Within about a block, a car ahead at a steep angle (or the player's)
/// gets a honk and coasting instead of the brake; a ped gets a honk.
pub const traffic_close = fx.one;
/// A forced yield at a junction holds this long (~50 ticks).
pub const yield_ticks: u8 = 50;
/// The junction sweep box (ours): centred this far ahead, half sizes along
/// and across the car's heading.
pub const sweep_ahead = fx.ratio(25, 10);
pub const sweep_half_along = fx.fromInt(2);
pub const sweep_half_side = fx.fromInt(4);
/// Settling into the lane ends within the middle 20% of the block (0.4 to
/// 0.6) with the heading within ~3 degrees; a nudge waits for no body
/// within this radius half a block over (ours).
pub const settle_band = fx.ratio(1, 10);
pub const settle_heading: i32 = 546;
pub const settle_gap_radius = fx.ratio(3, 10);
/// Crossing marker stop: ends once the car is below this (ours; the
/// note's handbrake stop would hold the car at the marker for good).
pub const marker_release_speed = fx.ratio(2, 100);
/// Crossing-queue overtake: the car ahead crawls below ~0.04, a marker
/// within 3 blocks, side gaps probed ~0.7 and ~2 blocks over.
pub const overtake_crawl = fx.ratio(4, 100);
pub const overtake_probe = fx.fromInt(3);
pub const overtake_side_near = fx.ratio(7, 10);
pub const overtake_side_far = fx.fromInt(2);
/// The overtake's length and its swing out (ours).
pub const overtake_ticks: u8 = 60;
pub const overtake_swing_ticks: u8 = 12;
pub const overtake_swing: i16 = 3000;
/// The collision wiggle: below this speed and touching a car (circles
/// within 0.9 of the radii, ours), steer toward it for 20 ticks, then away.
pub const wiggle_speed = fx.ratio(2, 100);
pub const wiggle_flip_ticks: u8 = 20;
pub const touch_ratio = fx.ratio(9, 10);
/// The off-road snap looks this far for the nearest road (ours).
pub const snap_radius: i32 = 32;
/// A task car slows to this for a routed turn here or one block on (ours).
pub const task_turn_speed = fx.ratio(1, 10);
/// A task car steers by the next block's route once this point ahead of
/// it is in that block (ours).
pub const task_nose = fx.ratio(8, 10);
/// The wiggle starts after this many ticks stuck to the same car, at this
/// throttle (ours, so a car resting against another doesn't ram it).
pub const wiggle_wait: u8 = 5;
pub const wiggle_throttle: i32 = 60;
