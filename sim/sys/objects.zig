//! Objects and city furniture (workstream B): the objects API other
//! workstreams call, and `sysObjects`, once a tick. Phones, script and
//! generator pickups, oil, mines, conveyors, destructors and the map's own
//! objects are here; doors, generators and crushers have their own files
//! (`doors.zig`, `generators.zig`, `crusher.zig`) and are re-exported.
//!
//! Notes: script-objects.md, script-declarations.md 2.4 and 2.8-2.10,
//! crushers-and-garages.md, weapons.md 3.7 and projectiles.md (oil and
//! mines), traffic-and-car-ai.md 3.6 (crossing markers, in `lights.zig`).
//! The objects-behaviour note is not written yet; where a rule below is
//! ours it says so, and docs/coverage/ lists it.
//!
//! Single player only: the `Object` component and `state.sp` exist only in
//! `sp` configurations, so every entry point does nothing (or returns the
//! default) elsewhere, and `dm16` is unchanged.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const OT = @import("../tuning/objects.zig");
const st = @import("objects_state.zig");

pub const State = st.State;
pub const OpenRule = st.OpenRule;
pub const CloseRule = st.CloseRule;
pub const DoorState = st.DoorState;
pub const Face = st.Face;
pub const AreaKind = st.AreaKind;

/// `Object.state` bits for a phone.
pub const phone_ringing: u8 = 1;
pub const phone_answered: u8 = 2;
pub const phone_timed_out: u8 = 4;
pub const phone_dead: u8 = 8;
/// A phone trigger names it (script-declarations.md 2.10, type 213).
pub const phone_spoken_for: u8 = 16;
/// Someone was touching it last tick (edge detection for the hook).
pub const phone_touched: u8 = 32;

/// Is `model` one of the pickup object models (script-objects.md 4)?
pub fn isPickupModel(model: u8) bool {
    return (model >= OT.pickup_model_lo and model <= OT.pickup_model_hi) or
        (model >= OT.weapon_model_lo and model <= OT.weapon_model_hi);
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.single_player;
        const MapObject = Self.MapObject;
        const doors = @import("doors.zig").Sys(Self);
        const gens = @import("generators.zig").Sys(Self);
        const crusher = @import("crusher.zig").Sys(Self);

        /// Script height sentinel: a `z` at or above the top of the map
        /// means "on the ground here" (script-declarations.md 2, 255.0).
        pub const ground_z: Fx = fx.fromInt(map.size_z);

        // ------------------------------------------------------------------
        // Doors, generators, crushers (their own files)

        pub const DoorMode = enum(u8) { closed, open, auto, manual };
        pub const DoorDecl = doors.DoorDecl;
        pub const addDoorAnim = doors.addDoorAnim;
        pub const addDoor = doors.addDoor;
        pub const setDoorTarget = doors.setDoorTarget;
        pub const doorState = doors.doorState;
        pub const doorBlocks = doors.doorBlocks;

        /// Script door control: open (177), close (178), automatic (179),
        /// manual (180).
        pub fn setDoor(self: *Self, door: EntityId, mode: DoorMode) void {
            doors.setDoor(self, door, switch (mode) {
                .open => 0,
                .closed => 1,
                .auto => 2,
                .manual => 3,
            });
        }

        pub const GeneratorDecl = gens.GeneratorDecl;
        pub const addGenerator = gens.addGenerator;
        pub const setGenerator = gens.setGenerator;
        pub const startGenerator = gens.startGenerator;
        pub const setCarList = gens.setCarList;
        pub const decidePowerUp = gens.decidePowerUp;

        pub const addCrusher = crusher.addCrusher;
        pub const runCrusher = crusher.runCrusher;
        pub const beingCrushed = crusher.beingCrushed;
        pub const crusherPistons = crusher.crusherPistons;

        // ------------------------------------------------------------------
        // Spawning and removing

        /// Place an object (`ids.ObjectKind`, `model` is the object type).
        /// `z` at or above `ground_z` puts it on the ground at (x, y).
        /// Authoritative `sp` only.
        pub fn spawnObject(self: *Self, kind: ids.ObjectKind, model: u8, x: Fx, y: Fx, z: Fx, heading: u16) ?EntityId {
            if (comptime !sp) return null;
            if (self.predicting()) return null;
            const w = &self.state.world;
            const id = w.spawn(MapObject) orelse return null;
            const zz = if (z >= ground_z) groundAt(self, x, y) else z;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = zz, .heading = heading };
            const o = w.get(id, c.Object).?;
            o.* = .{ .kind = @intFromEnum(kind), .model = model };
            switch (kind) {
                .oil => o.timer = OT.oil_life,
                .mine => {
                    o.timer = OT.mine_life;
                    o.aux = OT.mine_arm_ticks;
                },
                else => {},
            }
            return id;
        }

        /// Set an object's value byte (a pickup's value, a shop's type:
        /// script-declarations.md 2.4, types 17-20).
        pub fn setObjectValue(self: *Self, id: EntityId, value: u8) void {
            if (comptime !sp) return;
            const o = objectOf(self, id) orelse return;
            o.value = value;
        }

        /// The object's model, or null if `id` is not a live object (the
        /// type 362 test).
        pub fn objectModel(self: *Self, id: EntityId) ?u8 {
            if (comptime !sp) return null;
            const o = objectOf(self, id) orelse return null;
            return o.model;
        }

        /// Remove an object (type 140 for objects). A door, generator or
        /// area also frees its table entry.
        pub fn removeObject(self: *Self, id: EntityId) void {
            if (comptime !sp) return;
            const o = objectOf(self, id) orelse return;
            const s = &self.state.sp.objects;
            switch (kindOf(o)) {
                .door => if (o.value < s.doors.len and eql(s.doors[o.value].obj, id)) {
                    s.doors[o.value] = .{};
                },
                .generator => if (o.value < s.gens.len and eql(s.gens[o.value].obj, id)) {
                    s.gens[o.value] = .{};
                },
                .conveyor, .destructor => if (o.value < s.areas.len and eql(s.areas[o.value].obj, id)) {
                    s.areas[o.value] = .{};
                },
                else => {},
            }
            self.state.world.despawn(id);
        }

        /// Oil dropped by a car (weapons.md 3.7), credited to `by`.
        pub fn dropOil(self: *Self, x: Fx, y: Fx, z: Fx, by: EntityId) ?EntityId {
            if (comptime !sp) return null;
            const id = spawnObject(self, .oil, 0, x, y, z, 0) orelse return null;
            self.state.world.get(id, c.Object).?.owner = by;
            return id;
        }

        /// A mine dropped by a car (weapons.md 3.7), credited to `by`.
        pub fn dropMine(self: *Self, x: Fx, y: Fx, z: Fx, by: EntityId) ?EntityId {
            if (comptime !sp) return null;
            const id = spawnObject(self, .mine, 0, x, y, z, 0) orelse return null;
            self.state.world.get(id, c.Object).?.owner = by;
            return id;
        }

        // ------------------------------------------------------------------
        // Phones (script-objects.md 2.6)

        /// Ring a phone for any player with no timeout, or cancel its ring
        /// (229) with `on` false.
        pub fn ringPhone(self: *Self, phone: EntityId, on: bool) void {
            if (comptime !sp) return;
            if (on) return ringPhoneFor(self, phone, .none, 0);
            const o = phoneOf(self, phone) orelse return;
            const was = o.state & phone_ringing != 0;
            o.state &= ~(phone_ringing | phone_answered | phone_timed_out);
            o.timer = 0;
            if (was) phoneEvent(self, phone, 0);
        }

        /// Type 168: ring `phone` for `ped` (none: any player), timing out
        /// after `timeout` ticks (0: never).
        pub fn ringPhoneFor(self: *Self, phone: EntityId, ped: EntityId, timeout: u16) void {
            if (comptime !sp) return;
            const o = phoneOf(self, phone) orelse return;
            if (o.state & phone_dead != 0) return;
            o.state = (o.state & ~(phone_answered | phone_timed_out)) | phone_ringing | phone_spoken_for;
            o.owner = ped;
            o.timer = timeout;
            phoneEvent(self, phone, 1);
        }

        /// Has the phone been answered (and not yet consumed)?
        pub fn phoneAnswered(self: *const Self, phone: EntityId) bool {
            if (comptime !sp) return false;
            const o = @constCast(&self.state.world).get(phone, c.Object) orelse return false;
            return kindOf(o) == .phone and o.state & phone_answered != 0;
        }

        /// Type 227: true once the phone has been answered, and clears it
        /// so it fires once.
        pub fn consumeAnswer(self: *Self, phone: EntityId) bool {
            if (comptime !sp) return false;
            const o = phoneOf(self, phone) orelse return false;
            if (o.state & phone_answered == 0) return false;
            o.state &= ~phone_answered;
            return true;
        }

        /// Type 228: the ring timed out before it was answered.
        pub fn phoneTimedOut(self: *Self, phone: EntityId) bool {
            if (comptime !sp) return false;
            const o = phoneOf(self, phone) orelse return false;
            return o.state & phone_timed_out != 0;
        }

        /// Type 213: a phone trigger names this phone.
        pub fn markPhoneSpokenFor(self: *Self, phone: EntityId) void {
            if (comptime !sp) return;
            const o = phoneOf(self, phone) orelse return;
            o.state |= phone_spoken_for;
        }

        /// Type 245: out of order for good, remembered in the level's dead
        /// phone list (31).
        pub fn killPhone(self: *Self, phone: EntityId) void {
            if (comptime !sp) return;
            const o = phoneOf(self, phone) orelse return;
            if (o.state & phone_dead != 0) return;
            if (o.state & phone_ringing != 0) phoneEvent(self, phone, 0);
            o.state = phone_dead;
            o.timer = 0;
            const s = &self.state.sp.objects;
            if (s.dead_len < s.dead_phones.len) {
                s.dead_phones[s.dead_len] = phone;
                s.dead_len += 1;
            }
        }

        pub fn isPhoneDead(self: *Self, phone: EntityId) bool {
            if (comptime !sp) return false;
            const o = phoneOf(self, phone) orelse return false;
            return o.state & phone_dead != 0;
        }

        // ------------------------------------------------------------------
        // Conveyors and destructors (script-declarations.md 2.8)

        /// Declare a conveyor (26/27) or destructor (34/35) area: corner
        /// (x, y), size (w, h), on the floor at `z` (or the ground with
        /// `ground_z`, read at the area's centre); conveyors push (vx, vy)
        /// blocks per tick.
        pub fn addArea(self: *Self, kind: AreaKind, x: Fx, y: Fx, z: Fx, w_: Fx, h_: Fx, vx: Fx, vy: Fx) ?EntityId {
            if (comptime !sp) return null;
            const s = &self.state.sp.objects;
            const okind: ids.ObjectKind = switch (kind) {
                .conveyor => .conveyor,
                .destructor => .destructor,
                else => return null,
            };
            const i = freeSlot(self, s.areas[0..]) orelse return null;
            const cx = x + @divTrunc(w_, 2);
            const cy = y + @divTrunc(h_, 2);
            const id = spawnObject(self, okind, 0, cx, cy, z, 0) orelse return null;
            self.state.world.get(id, c.Object).?.value = @intCast(i);
            const zz = self.state.world.get(id, c.Transform).?.z;
            s.areas[i] = .{ .obj = id, .x = x, .y = y, .z = zz, .w = w_, .h = h_, .vx = vx, .vy = vy, .kind = @intFromEnum(kind) };
            return id;
        }

        /// The conveyor push at (x, y, z), for car handling's conveyor
        /// steps (car-handling.md 4, steps 1 and 11; workstream C).
        pub fn conveyorPush(self: *Self, x: Fx, y: Fx, z: Fx) ?struct { vx: Fx, vy: Fx } {
            if (comptime !sp) return null;
            const s = &self.state.sp.objects;
            for (&s.areas) |*a| {
                if (a.kind != @intFromEnum(AreaKind.conveyor) or !slotUsed(self, a.obj)) continue;
                if (inArea(a, x, y, z)) return .{ .vx = a.vx, .vy = a.vy };
            }
            return null;
        }

        /// Is there an oil patch under (x, y, z)? For car handling's oil
        /// spin (car-handling.md "Oil slick"; workstream C applies it).
        pub fn oilAt(self: *Self, x: Fx, y: Fx, z: Fx) bool {
            if (comptime !sp) return false;
            const Ctx = struct { x: Fx, y: Fx, z: Fx, hit: bool = false };
            var ctx = Ctx{ .x = x, .y = y, .z = z };
            self.state.world.each(.{ c.Object, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, _: EntityId, o: *c.Object, t: *c.Transform) void {
                    if (cx.hit or kindOf(o) != .oil) return;
                    if (fx.abs(t.z - cx.z) > fx.half) return;
                    if (fx.length(t.x - cx.x, t.y - cx.y) <= OT.oil_radius) cx.hit = true;
                }
            }.f);
            return ctx.hit;
        }

        // ------------------------------------------------------------------
        // The tick

        /// Doors, generators, crushers, phones, pickups, oil, mines and
        /// destructors, once a tick (after contacts and hits).
        pub fn sysObjects(self: *Self) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            placeMapObjects(self);
            doors.sysDoors(self);
            gens.sysGenerators(self);
            crusher.sysCrushers(self);
            sysPhones(self);
            sysObjectPickups(self);
            sysOilAndMines(self);
            sysDestructors(self);
            sysBarriers(self);
        }

        /// The map's own objects (`Level.objects`), once, as decorations
        /// (ours: the map-object kinds are not in any note yet).
        fn placeMapObjects(self: *Self) void {
            const s = &self.state.sp.objects;
            if (s.flags & State.flag_placed != 0) return;
            const l = self.level orelse return;
            s.flags |= State.flag_placed;
            for (l.objects) |mo| {
                _ = spawnObject(self, .decoration, mo.object_type, mo.x, mo.y, ground_z, mo.heading);
            }
        }

        fn sysPhones(self: *Self) void {
            self.state.world.each(.{ c.Object, c.Transform }, self, struct {
                fn f(sim: *Self, id: EntityId, o: *c.Object, t: *c.Transform) void {
                    if (kindOf(o) != .phone or o.state & phone_dead != 0) return;
                    // Ringing with a timeout counts down (228).
                    if (o.state & phone_ringing != 0 and o.timer > 0) {
                        o.timer -= 1;
                        if (o.timer == 0) {
                            o.state = (o.state & ~phone_ringing) | phone_timed_out;
                            phoneEvent(sim, id, 0);
                            return;
                        }
                    }
                    const toucher = phoneToucher(sim, o, t);
                    if (toucher.isNone()) {
                        o.state &= ~phone_touched;
                        return;
                    }
                    if (o.state & phone_touched != 0) return; // still there
                    o.state |= phone_touched;
                    if (o.state & phone_ringing != 0 and (o.owner.isNone() or eql(o.owner, toucher))) {
                        o.state = (o.state & ~phone_ringing) | phone_answered;
                        o.timer = 0;
                        phoneEvent(sim, id, 0);
                    }
                    Self.hooks.phoneTouched(sim, id, toucher);
                }
            }.f);
        }

        /// Who is touching the phone: a player's ped on foot, or the ped
        /// it is ringing for (ours: phone_reach, same level).
        fn phoneToucher(self: *Self, o: *const c.Object, t: *const c.Transform) EntityId {
            const w = &self.state.world;
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                if (touchingOnFoot(self, row.ped, t)) return row.ped;
            }
            if (!o.owner.isNone() and w.get(o.owner, c.Controller) != null and touchingOnFoot(self, o.owner, t)) return o.owner;
            return .none;
        }

        fn touchingOnFoot(self: *Self, ped: EntityId, t: *const c.Transform) bool {
            const w = &self.state.world;
            const r = w.get(ped, c.Riding) orelse return false;
            if (!r.vehicle.isNone()) return false;
            const h = w.get(ped, c.Health) orelse return false;
            if (h.hp <= 0) return false;
            const pt = w.get(ped, c.Transform) orelse return false;
            if (fx.abs(pt.z - t.z) > fx.half) return false;
            return fx.length(pt.x - t.x, pt.y - t.y) <= OT.phone_reach;
        }

        /// Script and generator pickups: a player walking or driving over
        /// one takes it (ours, as the deathmatch pickups). What a model
        /// gives is `givePickupModel`.
        fn sysObjectPickups(self: *Self) void {
            self.state.world.each(.{ c.Object, c.Transform }, self, struct {
                fn f(sim: *Self, id: EntityId, o: *c.Object, t: *c.Transform) void {
                    if (kindOf(o) != .pickup) return;
                    const ww = &sim.state.world;
                    for (&sim.state.players, 0..) |*row, slot| {
                        if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                        const pt = ww.get(row.car, c.Transform) orelse ww.get(row.ped, c.Transform) orelse continue;
                        if (ww.get(row.car, c.Transform) == null) {
                            const h = ww.get(row.ped, c.Health) orelse continue;
                            if (h.hp <= 0) continue;
                        }
                        if (fx.abs(pt.z - t.z) > fx.half) continue;
                        if (fx.length(pt.x - t.x, pt.y - t.y) > OT.object_pickup_reach) continue;
                        if (!givePickupModel(sim, @intCast(slot), row.ped, o)) continue;
                        sim.scratch.stats.pickups_taken += 1;
                        // c = 1: b is an object model, not a weapon index.
                        sim.pushEvent(.{ .kind = .pickup, .a = @intCast(slot), .b = o.model, .c = 1, .x = t.x, .y = t.y, .z = t.z });
                        ww.despawn(id);
                        return;
                    }
                }
            }.f);
        }

        /// Apply a pickup object to player `slot` (ped `ped`). False if it
        /// is refused (the pickup stays). Ours until the objects note lists
        /// the object models: weapon models 200 + n give hand weapon n
        /// (rounds: the value byte, else the weapon's pickup rounds), and
        /// power-up models 64 + n give `career.PowerUp` n (`OT.powerup_ticks`
        /// for the timed ones). Other models in the ranges give nothing and
        /// are taken.
        fn givePickupModel(self: *Self, slot: u8, ped: EntityId, o: *const c.Object) bool {
            if (o.model >= OT.weapon_model_lo and o.model <= OT.weapon_model_hi) {
                const k = o.model - OT.weapon_model_lo;
                if (k >= T.weapon_count) return true;
                const rounds: u16 = if (o.value != 0) o.value else T.weapons[k].pickup_rounds;
                var give: c.Weapon = std.mem.zeroes(c.Weapon);
                give.kind = k;
                give.a0 = rounds * 10;
                return self.givePickup(ped, &give);
            }
            const n = o.model -% OT.pickup_model_lo;
            if (n < OT.powerup_kinds) Self.career.givePowerUp(self, slot, n, OT.powerup_ticks);
            return true;
        }

        /// Oil patches age away; mines lie still until a car or a ped
        /// touches them, then blow up, credited to whoever dropped them
        /// (projectiles.md 3.1-3.3). Only one mine goes off a tick.
        fn sysOilAndMines(self: *Self) void {
            const Ctx = struct { sim: *Self, blasted: bool = false };
            var ctx = Ctx{ .sim = self };
            self.state.world.each(.{ c.Object, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, o: *c.Object, t: *c.Transform) void {
                    const sim = cx.sim;
                    const k = kindOf(o);
                    if (k != .oil and k != .mine) return;
                    if (o.timer == 0) return sim.state.world.despawn(id);
                    o.timer -= 1;
                    if (k != .mine) return;
                    if (o.aux > 0) {
                        o.aux -= 1;
                        return;
                    }
                    if (cx.blasted) return;
                    const victim = mineVictim(sim, t);
                    if (victim.isNone()) return;
                    cx.blasted = true;
                    if (sim.state.world.get(victim, c.Vehicle) != null) {
                        sim.damageCar(victim, OT.mine_car_damage << fx.frac_bits, o.owner);
                    }
                    sim.explodeAt(t.x, t.y, t.z, o.owner, 0);
                    sim.state.world.despawn(id);
                }
            }.f);
        }

        /// The first car whose box, or ped whose circle, covers the mine.
        fn mineVictim(self: *Self, t: *const c.Transform) EntityId {
            const Ctx = struct { t: c.Transform, hit: EntityId = .none };
            var ctx = Ctx{ .t = t.* };
            const w = &self.state.world;
            w.each(.{ c.Vehicle, c.Transform }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, v: *c.Vehicle, ct: *c.Transform) void {
                    if (!cx.hit.isNone()) return;
                    if (fx.abs(ct.z - cx.t.z) > fx.half) return;
                    const m = T.carModel(v.model);
                    const dx = cx.t.x - ct.x;
                    const dy = cx.t.y - ct.y;
                    const cs = fx.cos(ct.heading);
                    const sn = fx.sin(ct.heading);
                    const u = fx.mul(dx, cs) + fx.mul(dy, sn);
                    const vv = fx.mul(dy, cs) - fx.mul(dx, sn);
                    if (fx.abs(u) < m.half_len + OT.mine_radius and fx.abs(vv) < m.half_wid + OT.mine_radius) cx.hit = id;
                }
            }.f);
            if (!ctx.hit.isNone()) return ctx.hit;
            w.each(.{ c.Pedestrian, c.Transform, c.Riding, c.Health }, &ctx, struct {
                fn f(cx: *Ctx, id: EntityId, _: *c.Pedestrian, pt: *c.Transform, r: *c.Riding, h: *c.Health) void {
                    if (!cx.hit.isNone() or !r.vehicle.isNone() or h.hp <= 0) return;
                    if (fx.abs(pt.z - cx.t.z) > fx.half) return;
                    if (fx.length(pt.x - cx.t.x, pt.y - cx.t.y) <= T.ped_radius + OT.mine_radius) cx.hit = id;
                }
            }.f);
            return ctx.hit;
        }

        /// Destructor areas (ours: the note leaves "what touching it does"
        /// to the objects note): a car with no player in it whose centre is
        /// inside is removed, with anyone riding in it.
        fn sysDestructors(self: *Self) void {
            const s = &self.state.sp.objects;
            var any = false;
            for (&s.areas) |*a| {
                if (a.kind == @intFromEnum(AreaKind.destructor) and slotUsed(self, a.obj)) any = true;
            }
            if (!any) return;
            self.state.world.each(.{ c.Vehicle, c.Transform }, self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, t: *c.Transform) void {
                    const ss = &sim.state.sp.objects;
                    const ww = &sim.state.world;
                    for (&ss.areas) |*a| {
                        if (a.kind != @intFromEnum(AreaKind.destructor) or !slotUsed(sim, a.obj)) continue;
                        if (!inArea(a, t.x, t.y, t.z)) continue;
                        if (ww.get(v.driver, c.Controller)) |dc| {
                            if (dc.player != c.Controller.no_player) return;
                        }
                        if (ww.isAlive(v.driver)) ww.despawn(v.driver);
                        sim.releaseCar(id);
                        ww.despawn(id);
                        return;
                    }
                }
            }.f);
        }

        /// Barriers are solid boxes (ours: the objects note is not written).
        /// After contacts, a ped (a circle) or a car (three circles along
        /// its length, its half width across) overlapping one is pushed out
        /// along the shallower axis and loses its speed into the barrier.
        fn sysBarriers(self: *Self) void {
            self.state.world.each(.{ c.Object, c.Transform }, self, struct {
                fn f(sim: *Self, _: EntityId, o: *c.Object, bt: *c.Transform) void {
                    if (kindOf(o) != .barrier) return;
                    const m = @min(o.model, OT.barrier_half_len.len - 1);
                    const box = Box{ .t = bt.*, .hl = OT.barrier_half_len[m], .hw = OT.barrier_half_wid[m] };
                    sim.state.world.each(.{ c.Transform, c.Velocity, c.Collider }, box, struct {
                        fn g(b: Box, id: EntityId, t: *c.Transform, v: *c.Velocity, col: *c.Collider) void {
                            _ = id;
                            if (col.flags & c.Collider.flag_disabled != 0) return;
                            if (fx.abs(t.z - b.t.z) > fx.half) return;
                            if (fx.abs(t.x - b.t.x) > 4 * fx.one or fx.abs(t.y - b.t.y) > 4 * fx.one) return;
                            b.pushOut(t, v, 0, T.ped_radius);
                        }
                    }.g);
                    sim.state.world.each(.{ c.Vehicle, c.Transform, c.Velocity, c.Collider }, box, struct {
                        fn g(b: Box, _: EntityId, veh: *c.Vehicle, t: *c.Transform, v: *c.Velocity, col: *c.Collider) void {
                            if (col.flags & c.Collider.flag_disabled != 0) return;
                            if (fx.abs(t.z - b.t.z) > fx.half) return;
                            if (fx.abs(t.x - b.t.x) > 4 * fx.one or fx.abs(t.y - b.t.y) > 4 * fx.one) return;
                            const cm = T.carModel(veh.model);
                            const off = cm.half_len - cm.half_wid;
                            for ([_]Fx{ off, 0, -off }) |along| b.pushOut(t, v, along, cm.half_wid);
                        }
                    }.g);
                }
            }.f);
        }

        const Box = struct {
            t: c.Transform,
            hl: Fx,
            hw: Fx,

            /// Push the circle `r` at `along` on the body's heading out of
            /// the box, moving the whole body.
            fn pushOut(b: Box, t: *c.Transform, v: *c.Velocity, along: Fx, r: Fx) void {
                const px = t.x + fx.mul(along, fx.cos(t.heading));
                const py = t.y + fx.mul(along, fx.sin(t.heading));
                const cs = fx.cos(b.t.heading);
                const sn = fx.sin(b.t.heading);
                const dx = px - b.t.x;
                const dy = py - b.t.y;
                const u = fx.mul(dx, cs) + fx.mul(dy, sn);
                const w = fx.mul(dy, cs) - fx.mul(dx, sn);
                const pu = b.hl + r - fx.abs(u);
                const pw = b.hw + r - fx.abs(w);
                if (pu <= 0 or pw <= 0) return;
                // Unit normal out of the box (world), and the depth.
                var nx: Fx = undefined;
                var ny: Fx = undefined;
                var depth: Fx = undefined;
                if (pw <= pu) {
                    const s: Fx = if (w < 0) -fx.one else fx.one;
                    nx = fx.mul(-sn, s);
                    ny = fx.mul(cs, s);
                    depth = pw;
                } else {
                    const s: Fx = if (u < 0) -fx.one else fx.one;
                    nx = fx.mul(cs, s);
                    ny = fx.mul(sn, s);
                    depth = pu;
                }
                t.x += fx.mul(nx, depth);
                t.y += fx.mul(ny, depth);
                const into = fx.mul(v.vx, nx) + fx.mul(v.vy, ny);
                if (into < 0) {
                    v.vx -= fx.mul(into, nx);
                    v.vy -= fx.mul(into, ny);
                }
            }
        };

        // ------------------------------------------------------------------
        // Helpers (shared with doors.zig, generators.zig, crusher.zig)

        pub fn objectOf(self: *Self, id: EntityId) ?*c.Object {
            if (comptime !sp) return null;
            return self.state.world.get(id, c.Object);
        }

        fn phoneOf(self: *Self, id: EntityId) ?*c.Object {
            const o = objectOf(self, id) orelse return null;
            return if (kindOf(o) == .phone) o else null;
        }

        pub fn kindOf(o: *const c.Object) ids.ObjectKind {
            return @enumFromInt(o.kind);
        }

        /// Is a table entry's object a live map object? (A zeroed entry's
        /// `obj` is a car handle, so the kind check matters.)
        pub fn slotUsed(self: *Self, obj: EntityId) bool {
            if (obj.isNone() or obj.kind() != @intFromEnum(abi.Kind.map_object)) return false;
            return self.state.world.get(obj, c.Object) != null;
        }

        pub fn freeSlot(self: *Self, slots: anytype) ?usize {
            for (slots, 0..) |*e, i| {
                if (!slotUsed(self, e.obj)) return i;
            }
            return null;
        }

        pub fn groundAt(self: *Self, x: Fx, y: Fx) Fx {
            return map.floorAt(self.grid, x, y, fx.fromInt(map.size_z - 1), T.ped_step);
        }

        fn inArea(a: *const st.Area, x: Fx, y: Fx, z: Fx) bool {
            if (fx.abs(z - a.z) > fx.half) return false;
            return x >= a.x and y >= a.y and x < a.x + a.w and y < a.y + a.h;
        }

        fn phoneEvent(self: *Self, phone: EntityId, on: u8) void {
            const t = self.state.world.get(phone, c.Transform) orelse return;
            self.pushEvent(.{ .kind = .phone_ring, .a = on, .x = t.x, .y = t.y, .z = t.z });
        }
    };
}
