//! Tyre marks: dark streaks left on the ground where a car's wheels slide
//! sideways, lock under hard braking or drag under the handbrake, fading
//! over a while. Drawing only (the sim knows nothing of them); every
//! number here is ours until the skid-marks note exists (behaviour
//! README item 7).
//!
//! `track` is fed each frame with every car's drawn pose and velocity and
//! keeps where each rear wheel (all four under hard braking) was last
//! frame; while a wheel skids it lays a segment from there to here into a
//! ring. `build` turns the ring into triangles for the renderer's mark
//! pass: x, y, z (blocks) and an opacity per vertex.

const std = @import("std");

/// Sideways speed, blocks a tick, over which the tyres slide and mark.
pub const slip_threshold: f32 = 0.045;
/// Speed, blocks a tick, over which a full foot brake locks the wheels.
pub const brake_speed: f32 = 0.12;
/// Speed over which the handbrake drags the rear wheels.
pub const handbrake_speed: f32 = 0.06;
/// Marks fade out over this long.
pub const fade_ms: f64 = 25_000;
/// Width of one wheel's mark, blocks (about 6 px).
pub const width: f32 = 0.1;
/// How dark a fresh mark is (0-1).
pub const strength: f32 = 0.8;

pub const max_segments = 4096;
pub const max_cars = 512;
pub const floats_per_vertex = 4;
pub const vertices_per_segment = 6;

const Segment = struct { x0: f32, y0: f32, x1: f32, y1: f32, z: f32, t0: f64, a: f32 };

var ring: [max_segments]Segment = undefined;
var ring_next: usize = 0;
var ring_len: usize = 0;

/// Per car slot: last frame's wheel positions (rear left, rear right,
/// front left, front right) and whether it was marking.
const Wheels = struct { p: [4][2]f32 = @splat(.{ 0, 0 }), z: f32 = 0, seen: u32 = 0, gen: u32 = 0 };
var cars: [max_cars]Wheels = @splat(.{});
var frame: u32 = 0;

/// The verts handed to the renderer.
var verts: [max_segments * vertices_per_segment * floats_per_vertex]f32 = undefined;

pub fn clear() void {
    ring_len = 0;
    ring_next = 0;
    cars = @splat(.{});
}

/// Starts a frame: cars not tracked this frame lose their last position.
pub fn beginFrame() void {
    frame +%= 1;
}

pub const Car = struct {
    /// Car slot (stable while the car lives) and its generation.
    slot: u32,
    gen: u32,
    x: f32,
    y: f32,
    z: f32,
    /// Heading, radians (0 along +x, toward +y).
    angle: f32,
    /// Velocity, blocks a tick.
    vx: f32,
    vy: f32,
    half_len: f32,
    half_wid: f32,
    /// Foot brake 0-4, handbrake held.
    brake: u8,
    handbrake: bool,
    /// On the ground (not airborne, not sinking, not wrecked).
    grounded: bool,
    /// Driven by traffic AI: its routine stops at lights and junctions
    /// leave no marks, only real slides do.
    ai: bool = false,
};

/// Feeds one car's pose this frame; lays marks for skidding wheels.
pub fn track(c: Car, now_ms: f64) void {
    if (c.slot >= max_cars) return;
    const w = &cars[c.slot];
    const fx = @cos(c.angle);
    const fy = @sin(c.angle);
    // Right of the car (+y side when heading +x).
    const rx = -fy;
    const ry = fx;
    const along = c.vx * fx + c.vy * fy;
    const side = c.vx * rx + c.vy * ry;
    const speed = @sqrt(c.vx * c.vx + c.vy * c.vy);
    const axle = c.half_len * 0.62;
    const track_half = c.half_wid * 0.78;
    var now: [4][2]f32 = undefined;
    for (0..4) |k| {
        const back: f32 = if (k < 2) -axle else axle;
        const right: f32 = if (k % 2 == 0) -track_half else track_half;
        now[k] = .{ c.x + fx * back + rx * right, c.y + fy * back + ry * right };
    }
    const sliding = @abs(side) > slip_threshold;
    const locked = !c.ai and c.brake >= 4 and @abs(along) > brake_speed;
    const dragging = c.handbrake and speed > handbrake_speed;
    const continuous = w.seen == frame -% 1 and w.gen == c.gen and @abs(w.z - c.z) < 0.25 and
        @abs(now[0][0] - w.p[0][0]) + @abs(now[0][1] - w.p[0][1]) < 1.0;
    if (continuous and c.grounded and (sliding or locked or dragging)) {
        // Darker the harder it slides.
        const a = strength * @min(1.0, 0.65 + @max(@abs(side) - slip_threshold, 0) * 8 + @as(f32, if (locked) 0.3 else 0));
        const wheels: usize = if (locked) 4 else 2;
        for (0..wheels) |k| add(w.p[k], now[k], c.z, now_ms, a);
    }
    w.p = now;
    w.z = c.z;
    w.gen = c.gen;
    w.seen = frame;
}

fn add(p0: [2]f32, p1: [2]f32, z: f32, t0: f64, a: f32) void {
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    if (dx * dx + dy * dy < 1e-6) return;
    ring[ring_next] = .{ .x0 = p0[0], .y0 = p0[1], .x1 = p1[0], .y1 = p1[1], .z = z, .t0 = t0, .a = a };
    ring_next = (ring_next + 1) % max_segments;
    ring_len = @min(ring_len + 1, max_segments);
}

/// Triangles for every mark still visible at `now_ms`; the vertex count.
pub fn build(now_ms: f64) usize {
    var n: usize = 0;
    for (ring[0..ring_len]) |s| {
        const age = now_ms - s.t0;
        if (age < 0 or age >= fade_ms) continue;
        const a: f32 = s.a * @as(f32, @floatCast(1.0 - age / fade_ms));
        const dx = s.x1 - s.x0;
        const dy = s.y1 - s.y0;
        const len = @sqrt(dx * dx + dy * dy);
        // Half the width across the segment.
        const ox = -dy / len * width * 0.5;
        const oy = dx / len * width * 0.5;
        // Just above the road so it never sinks into it.
        const z = s.z + 0.004;
        const q = [4][2]f32{ .{ s.x0 - ox, s.y0 - oy }, .{ s.x0 + ox, s.y0 + oy }, .{ s.x1 + ox, s.y1 + oy }, .{ s.x1 - ox, s.y1 - oy } };
        for ([6]usize{ 0, 1, 2, 0, 2, 3 }) |k| {
            const o = n * floats_per_vertex;
            verts[o..][0..4].* = .{ q[k][0], q[k][1], z, a };
            n += 1;
        }
    }
    return n;
}

pub fn ptr() [*]const f32 {
    return &verts;
}

test "a sideways slide marks the rear wheels; driving straight does not" {
    clear();
    var c: Car = .{ .slot = 3, .gen = 1, .x = 10, .y = 10, .z = 2, .angle = 0, .vx = 0.2, .vy = 0, .half_len = 0.9, .half_wid = 0.4, .brake = 0, .handbrake = false, .grounded = true };
    for (0..5) |i| {
        beginFrame();
        c.x += 0.2;
        track(c, @floatFromInt(i * 16));
    }
    try std.testing.expectEqual(@as(usize, 0), build(100));
    c.vy = 0.1;
    for (0..5) |i| {
        beginFrame();
        c.x += 0.2;
        c.y += 0.1;
        track(c, @floatFromInt(100 + i * 16));
    }
    // Four frames after the first slide frame, two wheels each.
    try std.testing.expectEqual(@as(usize, 5 * 2 * vertices_per_segment), build(200));
    try std.testing.expectEqual(@as(usize, 0), build(200 + fade_ms));
}

test "locked brakes mark all four wheels" {
    clear();
    var c: Car = .{ .slot = 0, .gen = 1, .x = 10, .y = 10, .z = 2, .angle = 0, .vx = 0.3, .vy = 0, .half_len = 0.9, .half_wid = 0.4, .brake = 4, .handbrake = false, .grounded = true };
    beginFrame();
    track(c, 0);
    beginFrame();
    c.x += 0.3;
    track(c, 16);
    try std.testing.expectEqual(@as(usize, 4 * vertices_per_segment), build(20));
}
