//! The sim's static `Level` (interfaces `level.zig`) from a parsed map:
//! zones, map objects and lights. The script is added by `formats/scr.zig`
//! (workstream A1) when it lands; until then `Level.script` is empty.
//!
//! The returned slices live in `gpa` allocations owned by `LevelData`.

const std = @import("std");
const ifaces = @import("interfaces");
const lv = ifaces.level;
const gmp = @import("gmp.zig");

pub const LevelData = struct {
    level: lv.Level,
    zones: []lv.Zone,
    objects: []lv.MapObject,
    lights: []lv.Light,

    pub fn deinit(d: *LevelData, gpa: std.mem.Allocator) void {
        gpa.free(d.zones);
        gpa.free(d.objects);
        gpa.free(d.lights);
        d.* = undefined;
    }
};

/// gmp fixed point (128 units a block) to the sim's (65536 a block).
pub fn fixToFx(v: gmp.Fix16) i32 {
    return @as(i32, v) << 9;
}

/// Map object rotation (0-255 a full turn) to a binary angle. Which way
/// is zero is not settled yet (the heading question in plan-notes.md 7;
/// workstream A2 settles it from the data).
pub fn rotationToHeading(r: u8) u16 {
    return @as(u16, r) << 8;
}

/// Zone names point into `map`'s memory, so `map` must outlive the result.
pub fn build(gpa: std.mem.Allocator, map: *const gmp.Map) !LevelData {
    const zones = try gpa.alloc(lv.Zone, map.zones.len);
    errdefer gpa.free(zones);
    for (map.zones, zones) |z, *o| o.* = .{ .kind = @enumFromInt(z.zone_type), .x = z.x, .y = z.y, .w = z.w, .h = z.h, .name = z.name };
    const objects = try gpa.alloc(lv.MapObject, map.objects.len);
    errdefer gpa.free(objects);
    for (map.objects, objects) |m, *o| o.* = .{ .x = fixToFx(m.x), .y = fixToFx(m.y), .heading = rotationToHeading(m.rotation), .object_type = m.object_type };
    const lights = try gpa.alloc(lv.Light, map.lights.len);
    for (map.lights, lights) |l, *o| o.* = .{
        .argb = l.argb,
        .x = fixToFx(l.x),
        .y = fixToFx(l.y),
        .z = fixToFx(l.z),
        .radius = fixToFx(l.radius),
        .intensity = l.intensity,
        .shape = l.shape,
        .on_time = l.on_time,
        .off_time = l.off_time,
    };
    return .{
        .level = .{ .zones = zones, .objects = objects, .lights = lights },
        .zones = zones,
        .objects = objects,
        .lights = lights,
    };
}

test "zones and objects reach the level" {
    const gpa = std.testing.allocator;
    var zones = [_]gmp.Zone{.{ .zone_type = 16, .x = 10, .y = 20, .w = 3, .h = 4, .name = "restart1" }};
    var objects = [_]gmp.MapObject{.{ .x = 128 * 5 + 64, .y = 128 * 6, .rotation = 64, .object_type = 7 }};
    var map: gmp.Map = .{ .arena = std.heap.ArenaAllocator.init(gpa), .version = 500, .compression = .dmap, .blocks = &.{}, .cells = &.{}, .zones = &zones, .objects = &objects };
    defer map.deinit();
    var d = try build(gpa, &map);
    defer d.deinit(gpa);
    try std.testing.expectEqual(lv.ZoneKind.restart, d.level.zones[0].kind);
    try std.testing.expect(d.level.zoneAt(.restart, 12, 23) != null);
    try std.testing.expect(d.level.zoneAt(.restart, 13, 23) == null);
    try std.testing.expectEqual(@as(i32, (5 << 16) + (1 << 15)), d.level.objects[0].x);
    try std.testing.expectEqual(@as(u16, 16384), d.level.objects[0].heading);
}
