//! The traffic light cycle, lamps and pedestrian-crossing markers
//! (traffic-and-car-ai.md 3.6). Owner: workstream B.
//!
//! Every light in the city shares one 526-tick cycle: north-south green
//! 100, amber 24, red 24; east-west green 100, amber 24, red 24; all red
//! with pedestrians crossing 150; all red 80. A shared "lights" bit toggles
//! at the end of east-west amber; nothing reads it (as in the note).
//!
//! Each light is a `traffic_light` map zone. Once, when a level is
//! attached, every road block next to a light zone whose green arrows
//! point into it gets a crossing-marker object (traffic's look-ahead
//! brakes for them whatever the phase: workstream F reads `markerAt`), and
//! each side of the zone with an approach gets one lamp object (`value`:
//! 0 north-south lamp, 1 east-west lamp) for the client to animate from
//! `lightState`.

const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const OT = @import("../tuning/objects.zig");

/// In the SP state block (`state.sp.lights`).
pub const State = extern struct {
    /// Ticks into the light cycle (526 ticks a cycle, per the note).
    cycle: u16 = 0,
    flags: u16 = 0,

    /// Markers and lamps have been placed.
    pub const flag_placed: u16 = 1;
    /// The shared bit toggled at the end of east-west amber.
    pub const flag_toggle: u16 = 2;
};

/// What a traffic light shows a lane.
pub const Light = enum(u8) { none, green, amber, red };

/// The phase starts (ticks into the cycle).
const ns_amber: u16 = OT.light_phases[0];
const ns_red: u16 = ns_amber + OT.light_phases[1];
const ew_green: u16 = ns_red + OT.light_phases[2];
const ew_amber: u16 = ew_green + OT.light_phases[3];
const ew_red: u16 = ew_amber + OT.light_phases[4];
const peds_cross: u16 = ew_red + OT.light_phases[5];
const all_red: u16 = peds_cross + OT.light_phases[6];

/// What the north-south (`ns`) or east-west lights show at `cycle`.
pub fn phaseLight(cycle: u16, ns: bool) Light {
    if (ns) {
        if (cycle < ns_amber) return .green;
        if (cycle < ns_red) return .amber;
        return .red;
    }
    if (cycle >= ew_green and cycle < ew_amber) return .green;
    if (cycle >= ew_amber and cycle < ew_red) return .amber;
    return .red;
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.single_player;

        /// The light a car heading `dir` (0 +x, 1 +y, 2 -x, 3 -y) sees at
        /// block (bx, by): `.none` unless the block is in a light zone or
        /// next to one ahead of it.
        pub fn lightState(self: *const Self, bx: i32, by: i32, dir: u2) Light {
            if (comptime !sp) return .none;
            const l = self.level orelse return .none;
            const d = step(dir);
            if (l.zoneAt(.traffic_light, bx, by) == null and l.zoneAt(.traffic_light, bx + d.x, by + d.y) == null) return .none;
            return phaseLight(self.state.sp.lights.cycle, dir & 1 == 1);
        }

        /// The all-red phase in which pedestrians cross.
        pub fn pedestriansCross(self: *const Self) bool {
            if (comptime !sp) return false;
            const cyc = self.state.sp.lights.cycle;
            return cyc >= peds_cross and cyc < all_red;
        }

        /// The crossing marker on block (bx, by) at level `bz`, if any (for
        /// the traffic look-ahead, traffic-and-car-ai.md 3.5-3.6).
        pub fn markerAt(self: *Self, bx: i32, by: i32, bz: i32) ?EntityId {
            if (comptime !sp) return null;
            const Ctx = struct { bx: i32, by: i32, bz: i32, hit: ?EntityId = null };
            var ctx = Ctx{ .bx = bx, .by = by, .bz = bz };
            self.state.world.each(.{ c.Object, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, o: *c.Object, t: *c.Transform) void {
                    if (cx.hit != null or o.kind != @intFromEnum(ids.ObjectKind.crossing_marker)) return;
                    if (fx.toInt(t.x) == cx.bx and fx.toInt(t.y) == cx.by and fx.toInt(t.z - 1) == cx.bz) cx.hit = id;
                }
            }.f);
            return ctx.hit;
        }

        pub fn sysLights(self: *Self) void {
            if (comptime !sp) return;
            const s = &self.state.sp.lights;
            if (s.flags & State.flag_placed == 0 and !self.predicting()) {
                if (self.level != null) {
                    s.flags |= State.flag_placed;
                    placeMarkers(self);
                }
            }
            s.cycle += 1;
            if (s.cycle == ew_red) s.flags ^= State.flag_toggle;
            if (s.cycle >= OT.light_cycle) s.cycle = 0;
        }

        // ------------------------------------------------------------------

        fn step(dir: u2) struct { x: i32, y: i32 } {
            return switch (dir) {
                0 => .{ .x = 1, .y = 0 },
                1 => .{ .x = 0, .y = 1 },
                2 => .{ .x = -1, .y = 0 },
                3 => .{ .x = 0, .y = -1 },
            };
        }

        const dir_arrow = [4]u4{ map.Arrow.pos_x, map.Arrow.pos_y, map.Arrow.neg_x, map.Arrow.neg_y };

        /// For each light zone and each of its four sides, every road block
        /// just outside it whose arrows point into the zone gets a marker;
        /// the side gets a lamp at its first approach.
        fn placeMarkers(self: *Self) void {
            const l = self.level.?;
            for (l.zones) |z| {
                if (z.kind != .traffic_light) continue;
                // dir: the heading of traffic entering across this side.
                for (0..4) |di| {
                    const dir: u2 = @intCast(di);
                    var lamp = false;
                    const along_x = dir & 1 == 1; // entering along y: side runs along x
                    const n: i32 = if (along_x) z.w else z.h;
                    var k: i32 = 0;
                    while (k < n) : (k += 1) {
                        const bx: i32 = switch (dir) {
                            0 => @as(i32, z.x) - 1,
                            2 => @as(i32, z.x) + z.w,
                            else => @as(i32, z.x) + k,
                        };
                        const by: i32 = switch (dir) {
                            1 => @as(i32, z.y) - 1,
                            3 => @as(i32, z.y) + z.h,
                            else => @as(i32, z.y) + k,
                        };
                        const floor = roadFloor(self, bx, by, dir_arrow[dir]) orelse continue;
                        const x = fx.fromInt(bx) + fx.half;
                        const y = fx.fromInt(by) + fx.half;
                        const h = Self.dir_heading[dir];
                        _ = Self.objects.spawnObject(self, .crossing_marker, 0, x, y, floor, h);
                        if (!lamp) {
                            lamp = true;
                            if (Self.objects.spawnObject(self, .lamp, 0, x, y, floor, h)) |id| {
                                self.state.world.get(id, c.Object).?.value = if (along_x) 0 else 1;
                            }
                        }
                    }
                }
            }
        }

        /// The standing height on the highest road block in column (bx, by)
        /// whose arrows include `arrow`.
        fn roadFloor(self: *Self, bx: i32, by: i32, arrow: u4) ?Fx {
            if (bx < 0 or by < 0 or bx >= map.size_x or by >= map.size_y) return null;
            var lv: i32 = map.size_z - 1;
            while (lv >= 0) : (lv -= 1) {
                const cell = map.cellAt(self.grid, bx, by, lv);
                if (map.shapeOf(cell) == map.Shape.air) continue;
                if (map.groundOf(cell) != map.Ground.road or map.arrowsOf(cell) & arrow == 0) return null;
                return fx.fromInt(lv + 1);
            }
            return null;
        }
    };
}
