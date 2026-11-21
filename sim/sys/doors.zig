//! Doors (script-declarations.md 2.9, script-objects.md 2.5). Owner:
//! workstream B. A door is a map object on a block face plus an entry in
//! `state.sp.objects.doors`. In automatic mode its open rule opens it and
//! its close rule shuts it; in manual mode only the script moves it. The
//! open and close animation steps through the shared animation's frames.
//!
//! Ours until the objects note lands: what "near the door" means for an
//! open rule (`door_reach`), the animation speed read as ticks per frame,
//! a closing door reopening for someone who satisfies the open rule, and
//! the unconfirmed seventh open rule acting as "any player". Doors do not block bodies by
//! themselves: the map is static, so collision asks `doorBlocks`
//! (workstream C).

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const OT = @import("../tuning/objects.zig");
const st = @import("objects_state.zig");

const OpenRule = st.OpenRule;
const CloseRule = st.CloseRule;
const DoorState = st.DoorState;
const Door = st.Door;

/// Set on a door while its close rule says it should shut (type 178 needs
/// it; script-objects.md 2.5).
const flag_wants_close: u8 = 16;

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.single_player;
        const objects = Self.objects;

        pub const DoorDecl = struct {
            bx: u8,
            by: u8,
            bz: u8,
            face: st.Face,
            /// Index into the shared animations (type 230).
            anim: u8 = 0,
            open_rule: OpenRule = .any_player,
            close_rule: CloseRule = .rule_false,
            delay: u16 = 0,
            area_x: Fx = 0,
            area_y: Fx = 0,
            area_w: Fx = 0,
            area_h: Fx = 0,
            flip: bool = false,
            reversed: bool = false,
            double: bool = false,
            /// The car or character for the one-car, one-character and
            /// player-plus-car rules (types 376/379 resolve it; 375/378
            /// leave it none).
            target: EntityId = .none,
            /// The model for the car-model rule.
            target_model: u8 = 0,
        };

        /// Type 230: add a shared door animation; its index, or null when
        /// all five are taken.
        pub fn addDoorAnim(self: *Self, start: u16, end: u16, speed: u8) ?u8 {
            if (comptime !sp) return null;
            const s = &self.state.sp.objects;
            for (&s.anims, 0..) |*a, i| {
                if (a.used != 0) continue;
                a.* = .{ .start = start, .end = end, .speed = speed, .used = 1 };
                return @intCast(i);
            }
            return null;
        }

        /// Types 375/376/378/379: register a door. Returns its object.
        pub fn addDoor(self: *Self, d: DoorDecl) ?EntityId {
            if (comptime !sp) return null;
            const s = &self.state.sp.objects;
            const i = objects.freeSlot(self, s.doors[0..]) orelse return null;
            const fc = faceCentre(d.bx, d.by, d.face);
            const id = objects.spawnObject(self, .door, d.anim, fc.x, fc.y, fx.fromInt(d.bz), faceHeading(d.face)) orelse return null;
            self.state.world.get(id, c.Object).?.value = @intCast(i);
            var flags: u8 = 0;
            if (d.flip) flags |= Door.flag_flip;
            if (d.reversed) flags |= Door.flag_reversed;
            if (d.double) flags |= Door.flag_double;
            s.doors[i] = .{
                .obj = id,
                .target = d.target,
                .bx = d.bx,
                .by = d.by,
                .bz = d.bz,
                .face = @intFromEnum(d.face),
                .anim = d.anim,
                .open_rule = @intFromEnum(d.open_rule),
                .close_rule = @intFromEnum(d.close_rule),
                .flags = flags,
                .target_model = d.target_model,
                .delay = d.delay,
                .area_x = d.area_x,
                .area_y = d.area_y,
                .area_w = d.area_w,
                .area_h = d.area_h,
            };
            s.doors[i].frame = frames(s, &s.doors[i]).from;
            return id;
        }

        /// Script control: 0 open (177), 1 close (178), 2 auto (179),
        /// 3 manual (180).
        pub fn setDoor(self: *Self, door: EntityId, mode: u8) void {
            if (comptime !sp) return;
            const d = doorOf(self, door) orelse return;
            const s = &self.state.sp.objects;
            switch (mode) {
                0 => {
                    d.state = @intFromEnum(DoorState.open);
                    d.frame = frames(s, d).to;
                    d.frame_tick = 0;
                    d.timer = 0;
                    d.flags &= ~flag_wants_close;
                },
                1 => {
                    // Only a close the door's own rule already wants.
                    if (d.flags & flag_wants_close == 0) return;
                    const now: DoorState = @enumFromInt(d.state);
                    if (now == .open or now == .opening) d.state = @intFromEnum(DoorState.closing);
                },
                2 => d.flags &= ~Door.flag_manual,
                3 => d.flags |= Door.flag_manual,
                else => {},
            }
        }

        /// Type 265: change the car or character the door opens for, for
        /// the rules that name one.
        pub fn setDoorTarget(self: *Self, door: EntityId, target: EntityId) void {
            if (comptime !sp) return;
            const d = doorOf(self, door) orelse return;
            switch (@as(OpenRule, @enumFromInt(d.open_rule))) {
                .one_car, .one_char_on_foot, .player_plus_car => d.target = target,
                else => {},
            }
        }

        pub fn doorState(self: *Self, door: EntityId) ?DoorState {
            if (comptime !sp) return null;
            const d = doorOf(self, door) orelse return null;
            return @enumFromInt(d.state);
        }

        /// Does a door that is not fully open fill this block face? Faces
        /// are shared: block (x, y)'s east face is (x + 1, y)'s west face.
        pub fn doorBlocks(self: *Self, bx: i32, by: i32, bz: i32, face: st.Face) bool {
            if (comptime !sp) return false;
            const s = &self.state.sp.objects;
            const line = faceLine(bx, by, face);
            for (&s.doors) |*d| {
                if (!objects.slotUsed(self, d.obj)) continue;
                if (d.bz != bz) continue;
                const dl = faceLine(d.bx, d.by, @enumFromInt(d.face));
                if (dl.vertical != line.vertical or dl.a != line.a or dl.b != line.b) continue;
                if (d.state != @intFromEnum(DoorState.open)) return true;
            }
            return false;
        }

        pub fn sysDoors(self: *Self) void {
            if (comptime !sp) return;
            const s = &self.state.sp.objects;
            for (&s.doors) |*d| {
                if (!objects.slotUsed(self, d.obj)) continue;
                const want_open = openRuleHolds(self, d);
                if (d.state == @intFromEnum(DoorState.open) and d.timer < 0xFFFF) d.timer += 1;
                if (closeRuleHolds(self, d, want_open)) d.flags |= flag_wants_close else d.flags &= ~flag_wants_close;
                const manual = d.flags & Door.flag_manual != 0;
                const now: DoorState = @enumFromInt(d.state);
                if (!manual) switch (now) {
                    .closed => if (want_open) {
                        d.state = @intFromEnum(DoorState.opening);
                    },
                    .open => if (d.flags & flag_wants_close != 0) {
                        d.state = @intFromEnum(DoorState.closing);
                    },
                    .closing => if (want_open) {
                        d.state = @intFromEnum(DoorState.opening);
                    },
                    else => {},
                };
                animate(s, d);
                if (self.state.world.get(d.obj, c.Object)) |o| o.state = d.state;
            }
        }

        // ------------------------------------------------------------------

        fn doorOf(self: *Self, door: EntityId) ?*Door {
            if (comptime !sp) return null;
            const o = objects.objectOf(self, door) orelse return null;
            if (objects.kindOf(o) != .door) return null;
            const s = &self.state.sp.objects;
            if (o.value >= s.doors.len or !eql(s.doors[o.value].obj, door)) return null;
            return &s.doors[o.value];
        }

        const Frames = struct { from: u16, to: u16, speed: u8 };

        fn frames(s: *const st.State, d: *const Door) Frames {
            const a = if (d.anim < s.anims.len) s.anims[d.anim] else st.DoorAnim{};
            const speed = @max(a.speed, 1);
            if (d.flags & Door.flag_reversed != 0) return .{ .from = a.end, .to = a.start, .speed = speed };
            return .{ .from = a.start, .to = a.end, .speed = speed };
        }

        /// One tick of the open or close animation.
        fn animate(s: *const st.State, d: *Door) void {
            const f = frames(s, d);
            const now: DoorState = @enumFromInt(d.state);
            const goal = switch (now) {
                .opening => f.to,
                .closing => f.from,
                else => return,
            };
            if (d.frame != goal) {
                d.frame_tick += 1;
                if (d.frame_tick >= f.speed) {
                    d.frame_tick = 0;
                    if (d.frame < goal) d.frame += 1 else d.frame -= 1;
                }
            }
            if (d.frame == goal) {
                d.frame_tick = 0;
                d.state = @intFromEnum(if (now == .opening) DoorState.open else DoorState.closed);
                d.timer = 0;
            }
        }

        fn openRuleHolds(self: *Self, d: *const Door) bool {
            const w = &self.state.world;
            const rule: OpenRule = @enumFromInt(d.open_rule);
            switch (rule) {
                // Ours: the unconfirmed seventh rule (levels use it) acts
                // as any player until a note says otherwise.
                .any_player, .unknown => {
                    for (self.state.players) |row| {
                        if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                        const t = w.get(row.car, c.Transform) orelse w.get(row.ped, c.Transform) orelse continue;
                        if (near(d, t)) return true;
                    }
                    return false;
                },
                .any_car, .car_model => {
                    const Ctx = struct { d: *const Door, model: ?u8, hit: bool = false };
                    var ctx = Ctx{ .d = d, .model = if (rule == .car_model) d.target_model else null };
                    w.each(.{ c.Vehicle, c.Transform }, &ctx, struct {
                        fn f(cx: *Ctx, _: EntityId, v: *c.Vehicle, t: *c.Transform) void {
                            if (cx.hit or v.flags & c.Vehicle.flag_wrecked != 0) return;
                            if (cx.model) |m| {
                                if (v.model != m) return;
                            }
                            if (near(cx.d, t)) cx.hit = true;
                        }
                    }.f);
                    return ctx.hit;
                },
                .one_car => {
                    const t = w.get(d.target, c.Transform) orelse return false;
                    if (w.get(d.target, c.Vehicle) == null) return false;
                    return near(d, t);
                },
                .one_char_on_foot => {
                    const r = w.get(d.target, c.Riding) orelse return false;
                    if (!r.vehicle.isNone()) return false;
                    return near(d, w.get(d.target, c.Transform).?);
                },
                .player_plus_car => {
                    // Ours: the named car, driven by a player.
                    const v = w.get(d.target, c.Vehicle) orelse return false;
                    const dc = w.get(v.driver, c.Controller) orelse return false;
                    if (dc.player == c.Controller.no_player) return false;
                    return near(d, w.get(d.target, c.Transform).?);
                },
                else => return false,
            }
        }

        fn closeRuleHolds(self: *Self, d: *const Door, want_open: bool) bool {
            return switch (@as(CloseRule, @enumFromInt(d.close_rule))) {
                .never => false,
                .after_delay => d.state == @intFromEnum(DoorState.open) and d.timer >= d.delay,
                .area_clear => areaClear(self, d),
                .rule_false => !want_open,
                else => false,
            };
        }

        /// No ped or car centre in the presence area; a zero-size area
        /// skips the test.
        fn areaClear(self: *Self, d: *const Door) bool {
            if (d.area_w == 0 or d.area_h == 0) return true;
            const Ctx = struct { d: *const Door, hit: bool = false };
            var ctx = Ctx{ .d = d };
            self.state.world.each(.{ c.Transform, c.Health, c.Collider }, &ctx, struct {
                fn f(cx: *Ctx, _: EntityId, t: *c.Transform, h: *c.Health, col: *c.Collider) void {
                    if (cx.hit or h.hp <= 0 or col.flags & c.Collider.flag_disabled != 0) return;
                    if (fx.abs(t.z - fx.fromInt(cx.d.bz)) >= fx.one) return;
                    if (t.x >= cx.d.area_x and t.y >= cx.d.area_y and t.x < cx.d.area_x + cx.d.area_w and t.y < cx.d.area_y + cx.d.area_h) cx.hit = true;
                }
            }.f);
            return !ctx.hit;
        }

        /// Is `t` near the door face (ours: `door_reach` across it, half a
        /// block along it, on its level)?
        fn near(d: *const Door, t: *const c.Transform) bool {
            if (fx.abs(t.z - fx.fromInt(d.bz)) >= fx.one) return false;
            const fc = faceCentre(d.bx, d.by, @enumFromInt(d.face));
            const dx = fx.abs(t.x - fc.x);
            const dy = fx.abs(t.y - fc.y);
            return switch (@as(st.Face, @enumFromInt(d.face))) {
                .west, .east => dx <= OT.door_reach and dy <= fx.half,
                else => dy <= OT.door_reach and dx <= fx.half,
            };
        }

        fn faceCentre(bx: u8, by: u8, face: st.Face) struct { x: Fx, y: Fx } {
            const x = fx.fromInt(bx);
            const y = fx.fromInt(by);
            return switch (face) {
                .west => .{ .x = x, .y = y + fx.half },
                .east => .{ .x = x + fx.one, .y = y + fx.half },
                .north => .{ .x = x + fx.half, .y = y },
                else => .{ .x = x + fx.half, .y = y + fx.one },
            };
        }

        fn faceHeading(face: st.Face) u16 {
            return switch (face) {
                .west, .east => 16384,
                else => 0,
            };
        }

        const Line = struct { vertical: bool, a: i32, b: i32 };

        /// A face as a wall line: vertical x = a between y = b and b + 1,
        /// or horizontal y = b between x = a and a + 1.
        fn faceLine(bx: i32, by: i32, face: st.Face) Line {
            return switch (face) {
                .west => .{ .vertical = true, .a = bx, .b = by },
                .east => .{ .vertical = true, .a = bx + 1, .b = by },
                .north => .{ .vertical = false, .a = bx, .b = by },
                else => .{ .vertical = false, .a = bx, .b = by + 1 },
            };
        }
    };
}
