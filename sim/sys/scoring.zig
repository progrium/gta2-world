//! Frags and points (scoring.md).
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

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;
        const Event = Self.Event;

        /// Kill credit for player `victim`'s death, hit last by `by`. A kill
        /// by a car counts for its driver; dying by your own hand costs a
        /// frag (`kills` holds frags). Reaching the frag limit ends the
        /// round. Points are `scoreKill`'s.
        pub fn creditKill(self: *Self, victim: u32, by: EntityId, victim_ped: EntityId) void {
            const w = &self.state.world;
            var killer = by;
            var weapon: u8 = Event.weapon_fire;
            if (w.get(by, c.Vehicle)) |v| {
                killer = v.driver;
                weapon = Event.weapon_car;
            } else if (w.get(by, c.Weapon)) |wp| weapon = wp.kind;
            var killer_slot: u8 = Event.no_slot;
            if (w.get(killer, c.Controller)) |ctl| {
                if (ctl.player != c.Controller.no_player and w.get(killer, c.Pedestrian) != null) killer_slot = @intCast(ctl.player);
            }
            if (eql(killer, victim_ped)) killer_slot = @intCast(victim);
            self.pushEvent(.{ .kind = .kill, .a = killer_slot, .b = @intCast(victim), .c = weapon });
            if (killer_slot == Event.no_slot) return;
            const kp = &self.state.players[killer_slot];
            if (killer_slot == victim) {
                kp.kills -= 1;
                return;
            }
            kp.kills += 1;
            if (kp.kills >= T.frag_limit) {
                self.scratch.stats.rounds += 1;
                self.pushEvent(.{ .kind = .round_end, .a = killer_slot });
                for (&self.state.players) |*pl| {
                    pl.kills = 0;
                    pl.deaths = 0;
                    pl.score = 0;
                }
            }
        }

        /// Points for player `slot` (scoring.md 3.1; the multiplier is 1).
        /// The server's alone: a predicting client takes the rows it is sent.
        pub fn addPoints(self: *Self, slot: u8, points: i32) void {
            if (self.predicting() or slot >= cfg.max_players) return;
            const row = &self.state.players[slot];
            row.score +|= points;
        }

        /// The player slot credited for a hit by `by` (a car counts for its
        /// driver), or `Event.no_slot`.
        pub fn creditSlot(self: *Self, by: EntityId) u8 {
            const w = &self.state.world;
            var killer = by;
            if (w.get(by, c.Vehicle)) |v| killer = v.driver;
            if (w.get(killer, c.Controller)) |ctl| {
                if (ctl.player != c.Controller.no_player and w.get(killer, c.Pedestrian) != null) return @intCast(ctl.player);
            }
            return Event.no_slot;
        }

        /// A combo's multiplier for a scored kill now, then raised: back to 1
        /// once `combo_window` ticks have passed since the last one.
        pub fn nextCombo(n: *u8, timer: *u8) i32 {
            if (timer.* == 0) n.* = 1;
            const k = n.*;
            if (n.* < T.combo_max) n.* += 1;
            timer.* = T.combo_window;
            return k;
        }

        /// Points for ped `victim`'s death, hit last by `by` (scoring.md
        /// 3.2): another player flat by method; anyone else as a civilian,
        /// by method and the killer's combo. Dying by your own hand scores
        /// nothing.
        pub fn scoreKill(self: *Self, victim: EntityId, victim_player: bool, by: EntityId) void {
            const slot = self.creditSlot(by);
            if (slot == Event.no_slot) return;
            const w = &self.state.world;
            const killer = self.state.players[slot].ped;
            if (eql(killer, victim)) return;
            const run_over = w.get(by, c.Vehicle) != null;
            const vp = w.get(victim, c.Pedestrian);
            const shocked = if (vp) |p| p.shock >= T.shock_threshold else false;
            const drowned = if (vp) |p| p.flags & c.Pedestrian.flag_drowned != 0 else false;
            const kp = w.get(killer, c.Pedestrian) orelse return;
            const combo = nextCombo(&kp.combo, &kp.combo_timer);
            if (victim_player) {
                self.addPoints(slot, if (shocked or drowned) T.points_player_electro else if (run_over) T.points_player_run_over else T.points_player_weapon);
                return;
            }
            if (drowned) return; // drowned civilians score nothing (scoring.md 3.2)
            const base = T.points_civilian * combo;
            self.addPoints(slot, if (shocked) @divTrunc(base * 5, 2) else if (run_over) @divTrunc(base, 2) else base);
        }

        /// Points for destroying car `v`, hit last by `by`: its value x 5 x
        /// the car combo (scoring.md 3.3). Not for the car you are in.
        pub fn scoreWreck(self: *Self, v: *const c.Vehicle, by: EntityId) void {
            const slot = self.creditSlot(by);
            if (slot == Event.no_slot) return;
            const killer = self.state.players[slot].ped;
            if (eql(killer, v.driver)) return;
            const kp = self.state.world.get(killer, c.Pedestrian) orelse return;
            const combo = nextCombo(&kp.car_combo, &kp.car_combo_timer);
            self.addPoints(slot, T.carModel(v.model).value * T.destroy_value_factor * combo);
        }
    };
}
