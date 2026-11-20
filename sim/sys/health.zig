//! Damage, ped status (burning, power-up timers) and deaths.
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
const TC = @import("../tuning/career.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;
        const Event = Self.Event;

        pub fn hurt(self: *Self, id: EntityId, dmg: i32, by: EntityId) void {
            if (!self.writable(id)) return;
            if (self.state.world.get(id, c.Pedestrian)) |p| {
                if (p.invulnerable > 0) return;
            }
            if (self.state.world.get(id, c.Health)) |h| {
                h.hp -= dmg;
                h.last_hit_by = by;
            }
        }

        /// Add `raw` damage (fixed point, 16 fraction bits) to a car, scaled
        /// by its model's anti-strength: at least 1 unless that is 0, up to
        /// the 32000 cap; a wreck takes none (car-collision.md 3.5).
        pub fn damageCar(self: *Self, id: EntityId, raw: i64, by: EntityId) void {
            if (!self.writable(id)) return;
            const w = &self.state.world;
            const v = w.get(id, c.Vehicle) orelse return;
            if (v.flags & c.Vehicle.flag_wrecked != 0) return;
            const anti: i64 = T.carModel(v.model).anti_strength;
            if (anti == 0) return;
            const dmg: i64 = @max(1, (raw * anti) >> (2 * fx.frac_bits));
            const h = w.get(id, c.Health).?;
            h.hp = @intCast(@max(0, h.hp - @min(dmg, T.car_damage_max)));
            if (!by.isNone()) h.last_hit_by = by;
            Self.wanted.onCarDamaged(self, id, by); // E: crime report
            // Each credited hit scores by how hard it was (scoring.md 3.3);
            // not on the car you are driving.
            const slot = self.creditSlot(by);
            if (slot != Event.no_slot and !eql(self.state.players[slot].ped, v.driver)) {
                self.addPoints(slot, if (dmg < T.damage_band_low) 1 else if (dmg < T.damage_band_high) 10 else 100);
            }
        }

        /// Per ped, per tick: power-up timers run down, burning hurts, and
        /// the shock counter decays by 1; a ped on his feet (not mid-jump)
        /// whose shock reaches 100 is electrocuted (ours: killed).
        pub fn sysPedStatus(self: *Self) void {
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Health, c.Controller }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, p: *c.Pedestrian, h: *c.Health, ctl: *c.Controller) void {
                    if (p.invulnerable > 0) p.invulnerable -= 1;
                    if (p.double_damage > 0) p.double_damage -= 1;
                    if (p.fast_reload > 0) p.fast_reload -= 1;
                    if (p.combo_timer > 0) p.combo_timer -= 1;
                    if (p.car_combo_timer > 0) p.car_combo_timer -= 1;
                    if (!eql(h.last_hit_by, p.prev_hit)) {
                        p.prev_hit = h.last_hit_by;
                        p.hit_age = 0;
                    } else p.hit_age +|= 1;
                    if (sim.predicting()) return; // damage comes from the server
                    // Deep water under a ped on foot drowns him; the fire
                    // goes out (ped-movement.md 3.7).
                    const w = &sim.state.world;
                    const col = w.get(id, c.Collider).?;
                    if (h.hp > 0 and p.jump == 0 and w.get(id, c.Riding).?.vehicle.isNone() and col.flags & c.Collider.flag_grounded != 0) {
                        const t = w.get(id, c.Transform).?;
                        if (map.waterAt(sim.grid, t.x, t.y, t.z)) {
                            p.burn = 0;
                            p.flags |= c.Pedestrian.flag_drowned;
                            if (p.hit_age > T.drown_credit_ticks) h.last_hit_by = .none;
                            h.hp = 0;
                            return;
                        }
                    }
                    if (p.burn > 0) {
                        p.burn -= 1;
                        const player = ctl.player != c.Controller.no_player;
                        sim.hurt(id, if (player) T.burn_damage_player else T.burn_damage_other, h.last_hit_by);
                    }
                    if (p.shock >= T.shock_threshold and p.state == c.Pedestrian.state_up and p.jump == 0) {
                        // A ped killed keeps his shock, so the kill scores
                        // as an electrocution.
                        sim.killPed(id, h.last_hit_by);
                        if (h.hp > 0) p.shock = 0;
                    } else if (p.shock > 0) p.shock -= 1;
                }
            }.f);
        }

        /// How a ped died, in the kill event's weapon numbering (the death
        /// message picks "wasted", "fried", "shocked" from it): electrocuted
        /// as the electro gun, burning or fire as `weapon_fire`, else what
        /// hit him last.
        pub fn deathCause(self: *Self, p: *const c.Pedestrian, h: *const c.Health) u8 {
            if (p.shock >= T.shock_threshold) return T.weapon_electro;
            if (p.burn > 0) return Event.weapon_fire;
            const w = &self.state.world;
            if (w.get(h.last_hit_by, c.Vehicle) != null) return Event.weapon_car;
            if (w.get(h.last_hit_by, c.Weapon)) |wp| return wp.kind;
            return Event.weapon_fire;
        }

        pub fn sysHealth(self: *Self) void {
            // Cars (explosions-and-damage.md 3.5-3.6): on fire from 16000
            // damage, burning on by itself from 25000, exploding at 32000;
            // then a wreck for a while.
            self.state.world.eachFiltered(.{ c.Vehicle, c.Health, c.Transform, c.Appearance }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, h: *c.Health, t: *c.Transform, look: *c.Appearance) void {
                    if (sim.predicting()) return; // fire and wrecks come from the server
                    const w = &sim.state.world;
                    if (v.flags & c.Vehicle.flag_wrecked != 0) {
                        if (v.timer > 0) {
                            v.timer -= 1;
                            return;
                        }
                        w.despawn(id);
                        if (cfg.ambient_cars > 0) _ = sim.spawnAmbientCar(true, sim.randomPlayerBlock(id));
                        return;
                    }
                    const damage = T.car_damage_max - h.hp;
                    if (damage >= T.car_fire_damage) v.flags |= c.Vehicle.flag_burning;
                    // In deep water the fire is held (car-height.md 5).
                    if (damage >= T.car_fire2_damage and v.flags & c.Vehicle.flag_in_water == 0) h.hp -= T.car_burn_rate;
                    if (h.hp > 0) return;
                    // Explodes: everyone inside dies, credited to whoever
                    // destroyed it.
                    const driver = v.driver;
                    if (w.get(driver, c.Riding)) |r| {
                        r.vehicle = .none;
                        w.get(driver, c.Collider).?.flags = c.Collider.flag_grounded;
                        w.get(driver, c.Transform).?.* = t.*;
                        if (w.get(driver, c.Controller)) |dc| {
                            if (dc.player != c.Controller.no_player) sim.state.players[dc.player].car = .none;
                        }
                        const dh = w.get(driver, c.Health).?;
                        dh.hp = 0;
                        dh.last_hit_by = h.last_hit_by;
                        // Single player: an ordinary background driver
                        // killed by destroying his car pays extra cash
                        // (scoring.md 3.3).
                        if (comptime Self.single_player) {
                            const slot = sim.creditSlot(h.last_hit_by);
                            const npc = if (w.get(driver, c.Controller)) |dc| dc.player == c.Controller.no_player else false;
                            if (slot != Event.no_slot and npc) sim.addPoints(slot, TC.points_driver_in_wreck);
                        }
                    }
                    sim.scratch.stats.car_wrecks += 1;
                    sim.scoreWreck(v, h.last_hit_by);
                    sim.releaseCar(id);
                    v.flags = c.Vehicle.flag_wrecked;
                    v.timer = T.wreck_ticks;
                    v.pedal = 0;
                    v.steer = 0;
                    h.hp = 0;
                    look.remap = T.wreck_remap;
                    sim.explodeAt(t.x, t.y, t.z, h.last_hit_by, 1);
                }
            }.f);
            self.state.world.eachFiltered(.{ c.Pedestrian, c.Health, c.Controller, c.Riding }, self.predicting(), self, struct {
                fn f(sim: *Self, id: EntityId, p: *c.Pedestrian, h: *c.Health, ctl: *c.Controller, r: *c.Riding) void {
                    if (h.hp > 0) return;
                    if (sim.predicting()) {
                        sim.kill(id);
                        return;
                    }
                    // A single-player body double lies dead until its
                    // countdown ends (power-ups-death-and-arrest.md 3.2).
                    if (Self.career.isDouble(sim, id)) return;
                    const w = &sim.state.world;
                    if (!r.vehicle.isNone()) sim.releaseCar(r.vehicle);
                    sim.scratch.stats.ped_deaths += 1;
                    sim.scoreKill(id, ctl.player != c.Controller.no_player, h.last_hit_by);
                    if (ctl.player != c.Controller.no_player) {
                        if (comptime Self.single_player) {
                            // Wasted, with a body double and an immediate
                            // respawn (sys/death.zig): the body stays.
                            const slot: u8 = @intCast(ctl.player);
                            sim.creditKill(ctl.player, h.last_hit_by, id);
                            if (Self.death.playerDown(sim, slot, id, deathCause(sim, p, h))) return;
                            w.despawn(id);
                        } else {
                            // Despawned first: a death by your own hand reads
                            // as fire in the kill event.
                            w.despawn(id);
                            sim.creditKill(ctl.player, h.last_hit_by, id);
                        }
                        const pl = &sim.state.players[ctl.player];
                        pl.deaths += 1;
                        pl.ped = .none;
                        pl.car = .none;
                        pl.respawn_timer = T.respawn_ticks;
                    } else {
                        w.despawn(id);
                        _ = sim.spawnPed(c.Controller.no_player, 0);
                    }
                }
            }.f);
        }
    };
}
