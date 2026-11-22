//! Generators (script-declarations.md 2.8 types 29-32, script-objects.md
//! 2.3). Owner: workstream B. A generator produces its object model at
//! random intervals between its two delays. Pickup and weapon models
//! (script-objects.md 4) spawn one at a time: the next waits until the
//! last is taken. Any other model spawns every cycle.
//!
//! Ours until the objects note lands: a declared generator starts on with
//! unlimited spawns and makes its first object straight away; the
//! one-at-a-time wait starts the delay when the last object goes; the
//! per-car-model power-up table (every entry is the fallback, 65).

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const OT = @import("../tuning/objects.zig");
const st = @import("objects_state.zig");
const objects_mod = @import("objects.zig");

/// `abi.rand` salt (workstream B's range, ids.salts.objects).
const salt_gen_delay: u32 = 0x1100;

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.city;
        const objects = Self.objects;

        pub const GeneratorDecl = struct {
            x: Fx,
            y: Fx,
            /// `objects.ground_z` for the ground (the 2D forms).
            z: Fx,
            heading: u16 = 0,
            model: u16,
            min_delay: u16,
            max_delay: u16,
            /// 0: the model's own ammo.
            ammo: u16 = 0,
        };

        /// Types 29-32: declare a generator. Returns its object.
        pub fn addGenerator(self: *Self, d: GeneratorDecl) ?EntityId {
            if (comptime !sp) return null;
            const s = &self.state.sp.objects;
            const i = objects.freeSlot(self, s.gens[0..]) orelse return null;
            const id = objects.spawnObject(self, .generator, d.model, d.x, d.y, d.z, d.heading) orelse return null;
            self.state.world.get(id, c.Object).?.value = @intCast(i);
            const t = self.state.world.get(id, c.Transform).?;
            s.gens[i] = .{
                .obj = id,
                .x = t.x,
                .y = t.y,
                .z = t.z,
                .heading = d.heading,
                .min_delay = d.min_delay,
                .max_delay = @max(d.min_delay, d.max_delay),
                .timer = 0,
                .remaining = OT.spawns_unlimited,
                .ammo = d.ammo,
                .model = d.model,
                .on = 1,
                .one_at_a_time = @intFromBool(objects_mod.isPickupModel(d.model)),
            };
            return id;
        }

        /// Switch a generator on or off (keeps its count and model).
        pub fn setGenerator(self: *Self, gen: EntityId, on: bool) void {
            if (comptime !sp) return;
            const g = genOf(self, gen) orelse return;
            g.on = @intFromBool(on);
        }

        /// Types 268/269 (`model` null) and 351/352: turn it on for `count`
        /// more spawns, optionally retasked to `model`; the spawn pattern
        /// follows the (new) current model.
        pub fn startGenerator(self: *Self, gen: EntityId, count: u16, model: ?u16) void {
            if (comptime !sp) return;
            const g = genOf(self, gen) orelse return;
            if (model) |m| {
                g.model = m;
                if (self.state.world.get(gen, c.Object)) |o| o.model = m;
            }
            g.one_at_a_time = @intFromBool(objects_mod.isPickupModel(g.model));
            g.remaining = count;
            g.on = 1;
        }

        /// Type 353: the level's car-model list (up to 19).
        pub fn setCarList(self: *Self, models: []const u8) void {
            if (comptime !sp) return;
            const s = &self.state.sp.objects;
            const n = @min(models.len, s.car_list.len);
            @memcpy(s.car_list[0..n], models[0..n]);
            s.car_list_len = @intCast(n);
        }

        /// Type 354: set `gen` to the power-up for `car_model` from the
        /// car list, and start it with 3 spawns below type 91, else 1; an
        /// unlisted model gives type 65 with 3 spawns.
        pub fn decidePowerUp(self: *Self, gen: EntityId, car_model: u8) void {
            if (comptime !sp) return;
            const s = &self.state.sp.objects;
            var kind = OT.powerup_fallback;
            var count = OT.powerup_count_low;
            for (s.car_list[0..s.car_list_len], 0..) |m, i| {
                if (m != car_model) continue;
                kind = OT.car_list_powerups[i];
                count = if (kind < OT.powerup_count_threshold) OT.powerup_count_low else OT.powerup_count_high;
                break;
            }
            startGenerator(self, gen, count, kind);
        }

        pub fn sysGenerators(self: *Self) void {
            if (comptime !sp) return;
            const s = &self.state.sp.objects;
            const w = &self.state.world;
            for (&s.gens) |*g| {
                if (!objects.slotUsed(self, g.obj)) continue;
                if (g.on == 0 or g.remaining == 0) continue;
                if (g.one_at_a_time != 0 and w.isAlive(g.child)) continue;
                if (g.timer > 0) {
                    g.timer -= 1;
                    continue;
                }
                const kind: ids.ObjectKind = if (objects_mod.isPickupModel(g.model)) .pickup else .decoration;
                const id = objects.spawnObject(self, kind, g.model, g.x, g.y, g.z, g.heading) orelse continue;
                if (g.ammo != 0) w.get(id, c.Object).?.value = @intCast(@min(g.ammo, 255));
                if (kind == .decoration) objects.markGenerated(self, id);
                w.get(id, c.Object).?.owner = g.obj;
                g.child = id;
                if (g.remaining != OT.spawns_unlimited) g.remaining -= 1;
                const span: u32 = @as(u32, g.max_delay) - g.min_delay + 1;
                g.timer = g.min_delay + @as(u16, @intCast(self.randBelow(g.obj, salt_gen_delay, span)));
            }
        }

        fn genOf(self: *Self, gen: EntityId) ?*st.Generator {
            if (comptime !sp) return null;
            const o = objects.objectOf(self, gen) orelse return null;
            if (objects.kindOf(o) != .generator) return null;
            const s = &self.state.sp.objects;
            if (o.value >= s.gens.len or !eql(s.gens[o.value].obj, gen)) return null;
            return &s.gens[o.value];
        }
    };
}
