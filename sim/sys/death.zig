//! Wasted and busted (single player): the body double, lives, losing
//! weapons, jail cards, game over, the nearest restart zone, and the
//! player's power-up timers. Owner: workstream G
//! (power-ups-death-and-arrest.md 3.1-3.4, 4).
//!
//! Per tick, for each player (4): the power-up timers count down; a death
//! or arrest that happened this tick has already started its sequence
//! (`playerDown` from `sysHealth`, `startBusted` from the police); a
//! running sequence counts down and finishes at 0.

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
const level = @import("interfaces").level;
const TC = @import("../tuning/career.zig");
const career = @import("../sp/career.zig");
const CS = career.State;

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.single_player;
        const Event = Self.Event;

        pub fn sysDeath(self: *Self) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            for (&self.state.players, 0..) |*pl, i| {
                if (pl.flags & abi.PlayerRow.flag_active == 0) continue;
                const slot: u8 = @intCast(i);
                Self.career.start(self, slot);
                const cs = &self.state.sp.career[slot];
                powerUpTick(self, slot, cs);
                if (cs.phase == CS.phase_playing or cs.phase == CS.phase_game_over) continue;
                if (cs.countdown > 0) cs.countdown -= 1;
                if (cs.phase == CS.phase_busted and cs.countdown == TC.police_take_double) {
                    // The double is ordered to call a police car and is
                    // driven off (3.3 step 3): the police API (E) has no
                    // call for it yet; E can read `career.bodyDouble`.
                }
                if (cs.countdown == 0) finish(self, slot);
            }
        }

        /// Timers count down once a tick (3.1); the combos' windows too.
        /// Electro-fingers zaps everyone close by (ped-ai.md 3.14).
        fn powerUpTick(self: *Self, slot: u8, cs: *CS) void {
            if (cs.invisible > 0) cs.invisible -= 1;
            if (cs.elvis_timer > 0) cs.elvis_timer -= 1;
            if (cs.emergency_timer > 0) {
                cs.emergency_timer -= 1;
                if (cs.emergency_timer == 0) cs.emergency_kinds = 0;
            }
            const ped = self.state.players[slot].ped;
            if (cs.flags & CS.flag_unlimited_double != 0) {
                if (self.state.world.get(ped, c.Pedestrian)) |p| p.double_damage = TC.double_damage_ticks;
            }
            if (cs.electro_fingers == 0) return;
            cs.electro_fingers -= 1;
            if (cs.phase != CS.phase_playing) return;
            electroFingers(self, ped);
        }

        /// Every ped within half a block of the player, in sight, takes 3
        /// damage credited to him, with a spark drawn (ped-ai.md 3.14).
        /// Ours: only while he is on foot.
        pub fn electroFingers(self: *Self, ped: EntityId) void {
            const w = &self.state.world;
            const t = w.get(ped, c.Transform) orelse return;
            const r = w.get(ped, c.Riding) orelse return;
            if (!r.vehicle.isNone()) return;
            const Ctx = struct { sim: *Self, ped: EntityId, t: c.Transform };
            w.each(.{ c.Pedestrian, c.Transform, c.Collider }, Ctx{ .sim = self, .ped = ped, .t = t.* }, struct {
                fn f(cx: Ctx, id: EntityId, _: *c.Pedestrian, tt: *c.Transform, col: *c.Collider) void {
                    if (eql(id, cx.ped) or col.flags & c.Collider.flag_disabled != 0) return;
                    const sim = cx.sim;
                    if (Self.career.isDouble(sim, id)) return;
                    if (fx.abs(tt.z - cx.t.z) > fx.half) return;
                    const dx = tt.x - cx.t.x;
                    const dy = tt.y - cx.t.y;
                    if (fx.abs(dx) > TC.electro_fingers_radius or fx.abs(dy) > TC.electro_fingers_radius) return;
                    if (fx.length(dx, dy) > TC.electro_fingers_radius) return;
                    if (map.moveHitsWall(sim.grid, cx.t.x, cx.t.y, tt.x, tt.y, cx.t.z + T.shot_height, map.bullet)) return;
                    sim.hurt(id, TC.electro_fingers_damage, cx.ped);
                    sim.spark(tt.x, tt.y, tt.z, cx.ped);
                }
            }.f);
        }

        /// The player's ped `ped` has died (called by `sysHealth` instead of
        /// despawning it). Starts the wasted sequence (3.2); returns false
        /// outside `sp`, where the deathmatch respawn runs instead.
        /// `cause` uses the kill event's weapon numbering.
        pub fn playerDown(self: *Self, slot: u8, ped: EntityId, cause: u8) bool {
            if (comptime !sp) return false;
            if (self.predicting()) return false;
            const cs = Self.career.row(self, slot) orelse return false;
            Self.career.start(self, slot);
            // Killed again during a countdown (he respawned at once): the
            // first sequence ends now.
            if (cs.phase == CS.phase_wasted or cs.phase == CS.phase_busted) finish(self, slot);
            if (cs.phase == CS.phase_game_over) {
                self.state.world.despawn(ped);
                return true;
            }
            const pl = &self.state.players[slot];
            pl.deaths += 1;
            cs.flags |= CS.flag_was_out;
            cs.cause = cause;
            cs.death_car = pl.car;
            // 1-2: a life goes, with the message and voice; with none to
            // lose, game over instead.
            const game_over = cs.lives == 0;
            if (!game_over) cs.lives -= 1;
            self.pushEvent(.{ .kind = if (game_over) .game_over else .wasted, .a = slot, .b = cause });
            // 3: the body stays as the double; the player is moved to the
            // respawn point straight away.
            const t = (self.state.world.get(ped, c.Transform) orelse return true).*;
            makeDouble(self, cs, ped, c.Pedestrian.state_down, c.Pedestrian.anim_lie);
            cs.phase = CS.phase_wasted;
            cs.countdown = TC.countdown_ticks;
            if (game_over) {
                pl.ped = .none;
                pl.car = .none;
                // Keep the deathmatch respawn off this slot.
                pl.respawn_timer = std.math.maxInt(u32);
                return true;
            }
            respawnNear(self, slot, ped, t, false);
            return true;
        }

        /// Start the busted sequence (3.3). Nothing if the player is not on
        /// the street.
        pub fn startBusted(self: *Self, slot: u8, by: EntityId) void {
            _ = by;
            if (comptime !sp) return;
            if (self.predicting()) return;
            const cs = Self.career.row(self, slot) orelse return;
            Self.career.start(self, slot);
            if (cs.phase != CS.phase_playing) return;
            const pl = &self.state.players[slot];
            const w = &self.state.world;
            const ped = pl.ped;
            const t = (w.get(ped, c.Transform) orelse return).*;
            if (w.get(ped, c.Riding)) |r| {
                if (!r.vehicle.isNone()) {
                    self.releaseCar(r.vehicle);
                    r.vehicle = .none;
                }
            }
            // 1: no life lost; the message, the countdown, the double (the
            // one the police take). Breaking up the player's gang is D2's
            // group code, which has no API yet.
            cs.flags |= CS.flag_was_out;
            cs.cause = Event.weapon_car; // unused for an arrest
            cs.death_car = pl.car;
            pl.car = .none;
            self.pushEvent(.{ .kind = .busted, .a = slot });
            makeDouble(self, cs, ped, c.Pedestrian.state_arrested, c.Pedestrian.anim_stand);
            if (w.get(ped, c.Health)) |h| {
                if (h.hp <= 0) h.hp = 1; // a living double
            }
            cs.phase = CS.phase_busted;
            cs.countdown = TC.countdown_ticks;
            // 2: moved to the respawn point at once; shock and wanted
            // level cleared (a fresh ped has no shock).
            Self.wanted.clear(self, slot);
            respawnNear(self, slot, ped, t, true);
        }

        /// Leave `ped` as the body double: no longer the player's, out of
        /// every contact and movement, drawn lying down or standing.
        fn makeDouble(self: *Self, cs: *CS, ped: EntityId, state: u8, anim: u8) void {
            const w = &self.state.world;
            if (!cs.double.isNone()) w.despawn(cs.double);
            cs.double = ped;
            if (w.get(ped, c.Controller)) |ctl| ctl.* = .{ .player = c.Controller.no_player, .prev_buttons = 0, .in = prelude.Frame.neutral(0) };
            if (w.get(ped, c.Collider)) |col| col.flags = c.Collider.flag_disabled;
            if (w.get(ped, c.Velocity)) |v| v.* = std.mem.zeroes(c.Velocity);
            if (w.get(ped, c.Riding)) |r| r.vehicle = .none;
            if (w.get(ped, c.Pedestrian)) |p| {
                p.state = state;
                p.anim = anim;
                p.burn = 0;
                p.shock = 0;
            }
        }

        /// A fresh player ped at the restart zone nearest `t` (3.4), with
        /// the weapons and power-ups the double had: they go, or not, when
        /// the countdown ends.
        fn respawnNear(self: *Self, slot: u8, old: EntityId, t: c.Transform, arrest: bool) void {
            const pl = &self.state.players[slot];
            const hint = restartHint(self, fx.toInt(t.x), fx.toInt(t.y), arrest);
            self.spawnPlayer(slot, hint);
            pl.respawn_timer = 0;
            const w = &self.state.world;
            const fresh = pl.ped;
            if (w.get(old, c.Weapon)) |ow| {
                if (w.get(fresh, c.Weapon)) |nw| nw.* = ow.*;
                ow.* = std.mem.zeroes(c.Weapon);
            }
            if (w.get(old, c.Pedestrian)) |op| {
                if (w.get(fresh, c.Pedestrian)) |np| {
                    np.armour = op.armour;
                    np.invulnerable = op.invulnerable;
                    np.double_damage = op.double_damage;
                    np.fast_reload = op.fast_reload;
                }
            }
        }

        /// Spawn hint for the restart zone nearest block (bx, by): the
        /// zone's middle. After an arrest an "arrest restart" zone of the
        /// map format is preferred when the map has one (ours: the note
        /// names only restart zones). 0 (the sim chooses) with none.
        pub fn restartHint(self: *const Self, bx: i32, by: i32, arrest: bool) u32 {
            const l = self.level orelse return 0;
            var best: ?level.Zone = null;
            var best_d: i64 = std.math.maxInt(i64);
            var pass: u8 = if (arrest) 0 else 1;
            while (pass < 2) : (pass += 1) {
                const kind: level.ZoneKind = if (pass == 0) .arrest_restart else .restart;
                for (l.zones) |z| {
                    if (z.kind != kind) continue;
                    const cx: i64 = @as(i64, z.x) * 2 + z.w;
                    const cy: i64 = @as(i64, z.y) * 2 + z.h;
                    const dx = cx - 2 * @as(i64, bx);
                    const dy = cy - 2 * @as(i64, by);
                    const d = dx * dx + dy * dy;
                    if (d < best_d) {
                        best_d = d;
                        best = z;
                    }
                }
                if (best != null) break;
            }
            const z = best orelse return 0;
            const cx: u32 = @as(u32, z.x) + z.w / 2;
            const cy: u32 = @as(u32, z.y) + z.h / 2;
            return cx | (cy << 8) | (1 << 31);
        }

        /// The countdown has ended (3.2 step 4-5, 3.3 step 4-5).
        fn finish(self: *Self, slot: u8) void {
            const cs = &self.state.sp.career[slot];
            const w = &self.state.world;
            const pl = &self.state.players[slot];
            const wasted = cs.phase == CS.phase_wasted;
            cs.countdown = 0;
            if (!cs.double.isNone()) w.despawn(cs.double);
            cs.double = .none;
            const game_over = if (wasted) pl.ped.isNone() else cs.lives == 0 or cs.flags & CS.flag_bonus_stage != 0;
            if (game_over) {
                if (!wasted) self.pushEvent(.{ .kind = .game_over, .a = slot });
                cs.phase = CS.phase_game_over;
                return;
            }
            cs.phase = CS.phase_playing;
            if (wasted) {
                setFrenzyNone(self, slot, cs);
                if (cs.flags & CS.flag_keep_weapons == 0) strip(self, slot, cs);
            } else if (cs.jail_cards > 0) {
                if (cs.flags & CS.flag_unlimited_jail == 0) cs.jail_cards -= 1;
            } else {
                if (cs.flags & CS.flag_keep_weapons == 0) strip(self, slot, cs);
                cs.multiplier = @max(1, cs.multiplier / 2);
            }
            cs.death_car = .none;
        }

        fn setFrenzyNone(self: *Self, slot: u8, cs: *CS) void {
            if (cs.frenzy_weapon == CS.no_weapon) return;
            Self.career.setFrenzyWeapon(self, slot, CS.no_weapon);
        }

        /// Lose all weapons, vehicle weapons and power-ups except the jail
        /// card.
        fn strip(self: *Self, slot: u8, cs: *CS) void {
            const w = &self.state.world;
            const ped = self.state.players[slot].ped;
            if (w.get(ped, c.Weapon)) |wpn| {
                for (wpn.rounds()) |*r| r.* = 0;
                wpn.kind = T.weapon_pistol;
            }
            if (w.get(ped, c.Pedestrian)) |p| {
                p.armour = 0;
                p.invulnerable = 0;
                p.double_damage = 0;
                p.fast_reload = 0;
            }
            cs.electro_fingers = 0;
            cs.invisible = 0;
            Self.car_weapons.disarm(self, cs.death_car);
        }
    };
}
