//! Pickups near players (power-ups-death-and-arrest.md 3.1).
//! Methods of `Sim(cfg)`, aliased in `sim.zig`; `step()` there calls the
//! systems in their fixed order.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const input = prelude.input;
const fx = prelude.fx;
const ecs = prelude.ecs;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const Frame = prelude.Frame;
const Button = prelude.Button;
const eql = prelude.eql;
const salt_pickup_kind = prelude.salt_pickup_kind;

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;
        const Pickup = Self.Pickup;

        /// Pickups: taken by a player walking or driving over one, expire
        /// after a while, and are topped up near random players.
        pub fn sysPickups(self: *Self) void {
            if (self.predicting()) return;
            const w = &self.state.world;
            w.each(.{ c.Transform, c.Weapon, c.Appearance }, self, struct {
                fn f(sim: *Self, id: EntityId, t: *c.Transform, give: *c.Weapon, _: *c.Appearance) void {
                    const ww = &sim.state.world;
                    if (ww.get(id, c.Pedestrian) != null) return; // peds carry weapons too
                    if (give.cooldown == 0) return ww.despawn(id);
                    give.cooldown -= 1;
                    for (&sim.state.players, 0..) |*row, slot| {
                        if (row.flags & abi.PlayerRow.flag_active == 0) continue;
                        const ped = row.ped;
                        const pt = ww.get(row.car, c.Transform) orelse ww.get(ped, c.Transform) orelse continue;
                        if (fx.abs(pt.z - t.z) > fx.half) continue;
                        if (fx.abs(pt.x - t.x) > T.pickup_reach or fx.abs(pt.y - t.y) > T.pickup_reach) continue;
                        if (fx.length(pt.x - t.x, pt.y - t.y) > T.pickup_reach) continue;
                        if (!sim.givePickup(ped, give)) continue;
                        sim.scratch.stats.pickups_taken += 1;
                        sim.pushEvent(.{ .kind = .pickup, .a = @intCast(slot), .b = give.kind, .x = t.x, .y = t.y, .z = t.z });
                        give.cooldown = 0;
                        ww.despawn(id);
                        return;
                    }
                }
            }.f);
            // Top up: one new pickup per tick at most. Configurations with
            // fewer than 8 pickup slots (unit tests) place none themselves.
            if (cfg.pickup_capacity < 8) return;
            var active: u32 = 0;
            for (self.state.players) |row| {
                if (row.flags & abi.PlayerRow.flag_active != 0) active += 1;
            }
            if (active == 0) return;
            const want = @min(cfg.pickup_capacity, T.pickups_base + T.pickups_per_player * active);
            if (w.count(Pickup) >= want) return;
            const id = w.spawn(Pickup) orelse return;
            const o = self.randomPlayerBlock(id) orelse return w.despawn(id);
            const spot = self.findSpotNear(id, map.Ground.pavement, T.ped_radius, o.x, o.y, T.pickup_near_radius, T.pickup_near_min) orelse return w.despawn(id);
            var roll = self.randBelow(id, salt_pickup_kind, 100);
            var kind: u8 = 1;
            while (kind < T.pickup_kinds - 1 and roll >= T.pickup_odds[kind]) : (kind += 1) roll -= T.pickup_odds[kind];
            self.initPickup(id, spot.x, spot.y, spot.z, kind);
        }

        pub fn initPickup(self: *Self, id: EntityId, x: Fx, y: Fx, z: Fx, kind: u8) void {
            const w = &self.state.world;
            w.get(id, c.Transform).?.* = .{ .x = x, .y = y, .z = z, .heading = 0 };
            const amount: u16 = if (kind < T.weapon_count) T.weapons[kind].pickup_rounds * 10 else 0;
            w.get(id, c.Weapon).?.* = .{ .cooldown = T.pickup_life, .kind = kind, .a0 = amount, .a1 = 0, .a2 = 0, .a3 = 0 };
            w.get(id, c.Appearance).?.* = .{ .sprite = kind, .remap = c.Appearance.no_remap };
        }

        /// Apply a pickup to `ped`. False if it does not need it.
        pub fn givePickup(self: *Self, ped: EntityId, give: *const c.Weapon) bool {
            const w = &self.state.world;
            if (give.kind == T.pickup_health) {
                const h = w.get(ped, c.Health) orelse return false;
                if (h.hp >= T.ped_hp) return false;
                h.hp = T.ped_hp;
                return true;
            }
            if (give.kind > T.pickup_health) {
                const p = w.get(ped, c.Pedestrian) orelse return false;
                // Refused when already full (power-ups-death-and-arrest.md 3.1).
                switch (give.kind) {
                    T.pickup_armour => {
                        if (p.armour >= T.armour_charges) return false;
                        p.armour = T.armour_charges;
                    },
                    T.pickup_invulnerable => {
                        if (p.invulnerable == T.invulnerable_ticks) return false;
                        p.invulnerable = T.invulnerable_ticks;
                    },
                    T.pickup_double_damage => {
                        if (p.double_damage == T.double_damage_ticks) return false;
                        p.double_damage = T.double_damage_ticks;
                    },
                    T.pickup_fast_reload => {
                        if (p.fast_reload == T.fast_reload_ticks) return false;
                        p.fast_reload = T.fast_reload_ticks;
                    },
                    else => return false,
                }
                return true;
            }
            if (give.kind >= T.weapon_count) return false;
            const wpn = w.get(ped, c.Weapon) orelse return false;
            const have = wpn.rounds()[give.kind];
            if (have == T.infinite_ammo or have >= T.max_ammo_tenths) return false;
            wpn.rounds()[give.kind] = @min(T.max_ammo_tenths, have + give.a0);
            // A weapon you did not have goes straight into your hand.
            if (have == 0) wpn.kind = give.kind;
            return true;
        }
    };
}
