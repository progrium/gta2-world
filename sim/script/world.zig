//! Script world commands (workstream A2): the seam between the mission
//! script VM (A1, `vm.zig`) and the five world families: declarations,
//! cars, characters, objects and the player (script-declarations.md,
//! script-cars.md, script-characters.md, script-objects.md,
//! script-player.md). Each family is a thin layer over the owning
//! workstream's API (plan-notes.md 5); a command whose system has not
//! landed yet calls the stub and reports `stubbed`.
//!
//! The VM calls `exec(self, ctx, cmd)` for every command its own families
//! do not handle. `ctx` is the VM's type (a thread or the declaration
//! pass); A2 calls only these methods on it:
//!   declaring() bool              in the level-start declaration pass
//!   handle(num: u16) EntityId     the by-command-number table
//!   setHandle(num: u16, id: EntityId)
//!   setCond(b: bool)              the thread's condition result
//!   counter(num: u16) ?*i32       a declared counter
//!   addCleanup(id: EntityId)      the mission cleanup list
//!   string(offset: u16) []const u8  a string table entry's text
//!   deathArrestFlag() *bool       443: the last mission failed by death or arrest
//!   notifyDeathArrest() *bool     432: the script asked to be told
//!   setMissionFlag(which: u2, counter: u16)  240, 429-431
//!   player(slot: u8) EntityId     the player's ped
//!
//! Parameter layouts were read from the player's own `.scr` files (the
//! sizes and field positions, never the original code): every handle is
//! the u16 command number of the variable or declaration that holds it;
//! positions are three i32 in 1/16384 of a block; headings are whole
//! degrees.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const ecs = prelude.ecs;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");

pub const decl = @import("cmd_decl.zig");
pub const cars = @import("cmd_cars.zig");
pub const chars = @import("cmd_chars.zig");
pub const objects = @import("cmd_objects.zig");
pub const player = @import("cmd_player.zig");

/// One compiled command: its number, its type, the header's return field
/// and the bytes after the 8-byte header.
pub const Cmd = struct {
    num: u16,
    kind: u16,
    ret: i16 = 0,
    params: []const u8 = &.{},
};

/// What a family did with a command. `stubbed`: decoded and passed to an
/// API that is still a W0 stub, or to no API yet (coverage report).
/// `hold`: do not advance the thread this tick (none of A2's commands
/// holds today; the value exists for the VM's sake).
pub const Outcome = enum(u8) { done, stubbed, unhandled, hold };

// ---------------------------------------------------------------------------
// Parameters

/// Script positions are fixed point with 14 fraction bits; the sim's have 16.
pub const script_frac_bits = 14;
pub const script_one: i32 = 1 << script_frac_bits;
/// A height of 255.0: "read the ground height here" (script-declarations 2).
pub const ground_sentinel: i32 = 255 * script_one;
/// "No trailer" in the car creation forms.
pub const no_model: u16 = 0xFFFF;

pub fn fromScript(v: i32) Fx {
    return v *% (1 << (fx.frac_bits - script_frac_bits));
}

/// Script heading (degrees) to the sim's binary angle (0 = +x, 16384 = +y).
/// Settled from the data (plan-notes A2): in wil, ste and bil, cars the
/// scripts park on single-arrow road cells point 90 = +x, 180 = -y,
/// 270 = -x (11 of 15 along the lane axis; the rest face against it), so
/// script 0 is +y and the angle runs the other way round.
pub fn heading(deg: i32) u16 {
    const a: i64 = @mod(90 - @as(i64, deg), 360);
    return @intCast(@divTrunc(a * 65536, 360));
}

pub const Pos = struct {
    x: Fx,
    y: Fx,
    z: Fx,
    /// 2D form: the height was the sentinel; `z` is the ground there.
    ground: bool,
};

/// A little-endian reader over a command's parameters. Reads past the
/// end give 0, so a short command never traps.
pub const P = struct {
    b: []const u8,

    pub fn u8_(p: P, o: usize) u8 {
        return if (o < p.b.len) p.b[o] else 0;
    }
    pub fn u16_(p: P, o: usize) u16 {
        return @as(u16, p.u8_(o)) | (@as(u16, p.u8_(o + 1)) << 8);
    }
    pub fn i16_(p: P, o: usize) i16 {
        return @bitCast(p.u16_(o));
    }
    pub fn u32_(p: P, o: usize) u32 {
        return @as(u32, p.u16_(o)) | (@as(u32, p.u16_(o + 2)) << 16);
    }
    pub fn i32_(p: P, o: usize) i32 {
        return @bitCast(p.u32_(o));
    }
    /// A script fixed-point value as sim fixed point.
    pub fn fx_(p: P, o: usize) Fx {
        return fromScript(p.i32_(o));
    }
    /// Three i32 at `o`: x, y and height (or the ground sentinel).
    pub fn pos(p: P, o: usize) Pos {
        const z = p.i32_(o + 8);
        return .{ .x = p.fx_(o), .y = p.fx_(o + 4), .z = if (z == ground_sentinel) 0 else fromScript(z), .ground = z == ground_sentinel };
    }
};

pub fn params(cmd: Cmd) P {
    return .{ .b = cmd.params };
}

// ---------------------------------------------------------------------------
// A2's state block (`state.sp.world`): level-wide script bookkeeping no
// other workstream owns.

pub const DoorAnim = extern struct {
    start: u16 = 0,
    end: u16 = 0,
    speed: u16 = 0,
    _pad: u16 = 0,
};

pub const State = extern struct {
    /// 343: the level's finish score.
    finish_score: i32 = 0,
    /// 344, 345, 386-388: missions, secrets, gang 1-3 missions.
    totals: [5]u16 = @splat(0),
    /// 346-349, 389, 390: the counters (by command number) that record
    /// passed, gang 1-3 passed, secrets passed, secrets failed.
    done_flags: [6]u16 = @splat(0),
    /// 240, 429-431: the "mission in progress" counters.
    mission_flags: [4]u16 = @splat(0),
    /// 435-437: per gang, the first death-fail message id.
    fail_base: [3]u16 = @splat(0),
    /// 304, 418: the most stars this level allows (0 = not set).
    max_wanted: u8 = 0,
    flags: u8 = 0,
    car_list_len: u8 = 0,
    door_anim_count: u8 = 0,
    keyframe_count: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// 353: car models for the by-model power-up generator (19).
    car_list: [20]u8 = @splat(0),
    /// 422: basic keyframe ids (25).
    keyframes: [26]u16 = @splat(0),
    /// 230: shared door animations (5).
    door_anims: [5]DoorAnim = @splat(.{}),
    /// 445: the player's respect with every gang.
    respect_snapshot: [ids.max_gangs]i8 = @splat(0),

    /// 400: the player may not get into vehicles.
    pub const flag_no_enter: u8 = 1;
    /// 407: the player's controls are off.
    pub const flag_no_controls: u8 = 2;
    /// 304/418 with 0: police simulation forced on.
    pub const flag_police_forced: u8 = 4;
    /// 445 ran.
    pub const flag_snapshot: u8 = 8;
    /// Every background ped behaves as a mugger (script-characters 2.10).
    pub const flag_all_muggers: u8 = 16;
    /// 370: nobody may get off a bus.
    pub const flag_no_bus_exit: u8 = 32;

    pub const max_car_list = 19;
    pub const max_keyframes = 25;
    pub const max_door_anims = 5;
};

/// Script-only `ScriptTag` flag kept next to A1's: the car was locked
/// permanently (script-cars 2.5, 278). In A2's half of the flag word.
pub const tag_locked_forever: u16 = 0x0100;
/// The entity is a parked car declaration (425-428).
pub const tag_parked: u16 = 0x0200;

// ---------------------------------------------------------------------------
// Dispatch

/// Run `cmd` if it belongs to one of A2's families.
pub fn exec(comptime Self: type, self: *Self, ctx: anytype, cmd: Cmd) Outcome {
    if (comptime !Self.single_player) return .unhandled;
    inline for (.{ decl, cars, chars, objects, player }) |F| {
        const r = F.Sys(Self).exec(self, ctx, cmd);
        if (r != .unhandled) return r;
    }
    return .unhandled;
}

/// What A2 does with a command type today, for the VM's coverage report
/// (`replay scr-coverage`). `done` means the effect reaches the sim;
/// `stubbed` that the command is decoded but its system is not in yet.
pub fn coverage(kind: u16) Outcome {
    inline for (.{ decl, cars, chars, objects, player }) |F| {
        if (std.mem.indexOfScalar(u16, &F.done, kind) != null) return .done;
        if (std.mem.indexOfScalar(u16, &F.stubbed, kind) != null) return .stubbed;
    }
    return .unhandled;
}

// ---------------------------------------------------------------------------
// Helpers shared by the families

pub fn Helpers(comptime Self: type) type {
    return struct {
        pub fn world(self: *Self) *@TypeOf(self.state.world) {
            return &self.state.world;
        }

        pub fn st(self: *Self) *State {
            return &self.state.sp.world;
        }

        pub fn alive(self: *Self, id: EntityId) bool {
            return self.state.world.isAlive(id) or self.state.world.get(id, c.Transform) != null;
        }

        pub fn isCar(id: EntityId) bool {
            return !id.isNone() and id.kind() == @backingInt(abi.Kind.car);
        }
        pub fn isPed(id: EntityId) bool {
            return !id.isNone() and id.kind() == @backingInt(abi.Kind.ped);
        }
        pub fn isObject(id: EntityId) bool {
            return !id.isNone() and id.kind() == @backingInt(abi.Kind.map_object);
        }

        /// The handle a command refers to: `var` names the variable's
        /// command; 0 means the command itself (declarations).
        pub fn target(ctx: anytype, cmd: Cmd, v: u16) u16 {
            _ = ctx;
            return if (v == 0) cmd.num else v;
        }

        /// The ground under (x, y) from the top of the map, or the floor
        /// at or just below an explicit height.
        pub fn place(self: *Self, p: Pos, step: Fx) Pos {
            var q = p;
            const from = if (p.ground) fx.fromInt(map.size_z - 1) else p.z;
            const f = map.floorAt(self.grid, p.x, p.y, from, step);
            q.z = if (f < 0) (if (p.ground) 0 else p.z) else f;
            return q;
        }

        pub fn tag(self: *Self, id: EntityId, num: u16, flags: u16) void {
            if (self.state.world.get(id, c.ScriptTag)) |t| {
                t.handle = num;
                t.flags |= flags;
            }
        }

        /// The slot of the player whose ped is `id`, if any.
        pub fn playerSlot(self: *Self, id: EntityId) ?u8 {
            const ctl = self.state.world.get(id, c.Controller) orelse return null;
            if (ctl.player == c.Controller.no_player) return null;
            return @intCast(ctl.player);
        }

        /// The car a ped is in, or none.
        pub fn carOf(self: *Self, ped: EntityId) EntityId {
            const r = self.state.world.get(ped, c.Riding) orelse return .none;
            return r.vehicle;
        }

        pub fn spawnCar(self: *Self, p: Pos, deg: i32, model: u16, remap: u16) ?EntityId {
            if (self.predicting()) return null;
            const w = &self.state.world;
            const m: u8 = if (model < T.car_model_count) @intCast(model) else 0;
            const id = w.spawn(Self.Car) orelse return null;
            const q = place(self, p, T.car_step);
            self.initCar(id, .{ .x = q.x, .y = q.y, .z = q.z, .heading = heading(deg) }, m);
            if (remap != 0xFFFF and remap != 0xFF) w.get(id, c.Appearance).?.remap = remap;
            return id;
        }

        pub fn spawnPedAt(self: *Self, p: Pos, deg: i32, remap: u16, slot: u32) ?EntityId {
            if (self.predicting()) return null;
            const w = &self.state.world;
            const id = w.spawn(Self.Ped) orelse return null;
            const q = place(self, p, T.ped_step);
            const h = heading(deg);
            w.get(id, c.Transform).?.* = .{ .x = q.x, .y = q.y, .z = q.z, .heading = h };
            w.get(id, c.Collider).?.flags = c.Collider.flag_grounded;
            w.get(id, c.Health).?.* = .{ .hp = T.ped_hp, .last_hit_by = .none };
            w.get(id, c.Riding).?.vehicle = .none;
            w.get(id, c.Controller).?.* = .{ .player = slot, .prev_buttons = 0, .in = prelude.Frame.neutral(0) };
            w.get(id, c.Pedestrian).?.* = .{ .ai_timer = 0, .ai_heading = h, .turn = 0, .down = 0, .jump = 0, .anim = 0, .state = 0, .flags = 0 };
            const is_player = slot != c.Controller.no_player;
            w.get(id, c.Weapon).?.* = .{ .cooldown = 0, .kind = T.weapon_pistol, .a0 = if (is_player) T.infinite_ammo else 0, .a1 = 0, .a2 = 0, .a3 = 0 };
            w.get(id, c.Appearance).?.* = .{ .sprite = 0, .remap = if (remap == 0xFFFF) c.Appearance.no_remap else remap };
            w.get(id, c.Group).?.* = .{};
            return id;
        }

        /// Raw damage a car has taken (the scale `car_damage_max` counts in).
        pub fn carDamage(self: *Self, car: EntityId) i32 {
            const h = self.state.world.get(car, c.Health) orelse return T.car_damage_max;
            return T.car_damage_max - h.hp;
        }

        pub fn wrecked(self: *Self, car: EntityId) bool {
            const w = &self.state.world;
            if (!w.isAlive(car)) return true;
            const v = w.get(car, c.Vehicle) orelse return true;
            if (v.flags & c.Vehicle.flag_wrecked != 0) return true;
            return carDamage(self, car) >= T.car_damage_max;
        }

        pub fn inRect(t: *const c.Transform, x: Fx, y: Fx, w: Fx, h: Fx) bool {
            return t.x >= x - (w >> 1) and t.x <= x + (w >> 1) and t.y >= y - (h >> 1) and t.y <= y + (h >> 1);
        }

        /// Every live ped, as ids.
        pub fn eachPed(self: *Self, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Self, EntityId) void) void {
            const t = self.state.world.table(Self.Ped);
            var i: u32 = 0;
            while (i < t.len) : (i += 1) {
                if (t.slot[i] != ecs.Slot.alive) continue;
                f(ctx, self, EntityId.make(abi.Kind.ped, i, t.gen[i]));
            }
        }
    };
}
