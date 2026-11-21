//! Wanted level (single player): points and stars, crime reports, cops
//! noticing, the one-star timeout. Owner: workstream E (wanted-level.md,
//! script-player.md 2.3, script-declarations.md 2.14). The pursuit and
//! crews are in `police.zig`.
//!
//! Every function here is safe to call in any configuration and in predict
//! mode: outside `sp`, or while predicting, it does nothing.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const TP = @import("../tuning/police.zig");
const TC = @import("../tuning/career.zig");

/// Pursuit states (wanted-level.md 3.5, police-ai.md 3.1-3.3).
pub const Pursuit = enum(u8) { idle = 0, responding = 1, active = 2, searching = 3, _ };

/// Per player, in the SP state block (`state.sp.wanted[slot]`).
pub const State = extern struct {
    points: u16 = 0,
    /// Stars cap set by the script, valid when `flag_capped` is set.
    cap: u8 = 0,
    flags: u8 = 0,
    /// Ticks at exactly one star with no crew pursuing (the 900-tick
    /// one-star timeout).
    quiet: u16 = 0,
    /// Ticks left on the "recent crime" timer (wanted-level.md 3.3).
    recent: u16 = 0,
    /// The police's last known position of the player.
    last_x: Fx = 0,
    last_y: Fx = 0,
    last_z: Fx = 0,
    /// The player ped as last seen, to notice a respawn.
    ped: EntityId = .none,
    /// Pursuit (`police.zig` runs it): `Pursuit`, star tier read this tick,
    /// highest crew kind (`ids.Occupation` police..army, 0 none).
    pursuit: u8 = 0,
    tier: u8 = 0,
    top_kind: u8 = 0,
    /// Police car crews the tier wants, and live crews on this pursuit.
    crews_wanted: u8 = 0,
    crews: u8 = 0,
    /// Cap on new police cars spawning for this pursuit.
    new_cars: u8 = 0,
    /// Ticks before the police may shout or talk on the radio again.
    voice_cool: u16 = 0,
    /// "Can still see them" clock (police-ai.md 3.3).
    sight: u16 = 0,
    /// Ticks until the next crew may spawn.
    crew_timer: u16 = 0,

    /// `cap` holds a script cap.
    pub const flag_capped: u8 = 1;
    /// "No police" debug or cheat: cleared every tick.
    pub const flag_no_police: u8 = 2;
};

/// What was done (wanted-level.md 3.2-3.3). Append only.
pub const Crime = enum(u8) { shot_fired, ped_hurt, ped_killed, cop_hurt, cop_killed, car_stolen, car_destroyed, ran_over, rammed_cop, car_damaged, _ };

/// One crime report (`police.State.reports`).
pub const Report = extern struct {
    x: Fx = 0,
    y: Fx = 0,
    z: Fx = 0,
    by: EntityId = .none,
    /// Tick it was filed; reports live for the tick after.
    tick: u32 = 0,
    crime: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

/// Stars for a points total (wanted-level.md 3.1).
pub fn starsOf(points: u16) u8 {
    var s: u8 = 0;
    while (s < TP.max_stars and points >= TP.star_points[s + 1]) s += 1;
    return s;
}

/// Law enforcement for the exempt-shooter rule and the cop witness check:
/// police, SWAT, FBI, army and guards (wanted-level.md 3.3).
pub fn isLaw(o: u8) bool {
    return switch (@as(ids.Occupation, @enumFromInt(o))) {
        .police, .swat, .fbi, .army, .guard => true,
        else => false,
    };
}

/// Emergency workers for the +500 kill: law enforcement and the medics and
/// firefighters (`emergency`). Guards are counted here (ours: the note names
/// police, medics and firefighters; ped-ai.md lists guards as law).
pub fn isEmergency(o: u8) bool {
    return isLaw(o) or o == @intFromEnum(ids.Occupation.emergency);
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;
        const sp = Self.city;

        fn st(self: *Self, slot: u8) ?*State {
            if (comptime !sp) return null;
            if (self.predicting() or slot >= cfg.max_players) return null;
            return &self.state.sp.wanted[slot];
        }

        /// Every change to points goes through here: clamp, cap, and an
        /// event when the stars change.
        fn setPoints(self: *Self, slot: u8, total: i32) void {
            const s = st(self, slot) orelse return;
            var p: i32 = std.math.clamp(total, 0, TP.max_points);
            if (s.flags & State.flag_capped != 0 and starsOf(@intCast(p)) > s.cap) p = TP.star_points[s.cap];
            const before = starsOf(s.points);
            s.points = @intCast(p);
            const now = starsOf(s.points);
            if (now != before) {
                if (now != 1) s.quiet = 0;
                self.pushEvent(.{ .kind = .wanted, .a = slot, .b = now, .c = before });
                // The radio reports a rise.
                if (now > before) voice(self, slot, self.state.players[slot].ped, 1);
            }
        }

        pub fn addPoints(self: *Self, slot: u8, n: i32) void {
            const s = st(self, slot) orelse return;
            setPoints(self, slot, @as(i32, s.points) + n);
        }
        /// At least one star (wanted-level.md 3.1).
        pub fn atLeastOneStar(self: *Self, slot: u8) void {
            raiseToStars(self, slot, 1);
        }
        /// Clear to zero (cop bribe, script 163, respawn).
        pub fn clear(self: *Self, slot: u8) void {
            setPoints(self, slot, 0);
            if (st(self, slot)) |s| {
                s.quiet = 0;
                s.recent = 0;
            }
        }
        /// The script's cap on stars (declaration 304, command 418). 6 or
        /// more lifts it. A cap of 0 holds the level at none.
        pub fn setCap(self: *Self, slot: u8, max_stars: u8) void {
            const s = st(self, slot) orelse return;
            if (max_stars >= TP.max_stars) {
                s.flags &= ~State.flag_capped;
                return;
            }
            s.cap = max_stars;
            s.flags |= State.flag_capped;
            setPoints(self, slot, s.points);
        }
        pub fn stars(self: *const Self, slot: u8) u8 {
            if (comptime !sp) return 0;
            if (slot >= cfg.max_players) return 0;
            return starsOf(self.state.sp.wanted[slot].points);
        }
        pub fn points(self: *const Self, slot: u8) u16 {
            if (comptime !sp) return 0;
            if (slot >= cfg.max_players) return 0;
            return self.state.sp.wanted[slot].points;
        }
        /// Set the level to exactly `n` stars, up or down (script 164); out
        /// of range is ignored.
        pub fn setStars(self: *Self, slot: u8, n: u8) void {
            if (n > TP.max_stars) return;
            setPoints(self, slot, TP.star_points[n]);
        }
        /// Raise to `n` stars if below (script 421, "at least one star");
        /// never lowers. Out of range is ignored.
        pub fn raiseToStars(self: *Self, slot: u8, n: u8) void {
            if (n > TP.max_stars) return;
            const s = st(self, slot) orelse return;
            if (s.points < TP.star_points[n]) setPoints(self, slot, TP.star_points[n]);
        }
        /// "No police" debug or cheat: the level is cleared every tick.
        pub fn setNoPolice(self: *Self, slot: u8, on: bool) void {
            const s = st(self, slot) orelse return;
            if (on) s.flags |= State.flag_no_police else s.flags &= ~State.flag_no_police;
        }

        /// The player slot whose ped is `ped` (not a car), or null.
        fn playerSlotOfPed(self: *Self, ped: EntityId) ?u8 {
            const ctl = self.state.world.get(ped, c.Controller) orelse return null;
            if (ctl.player == c.Controller.no_player or self.state.world.get(ped, c.Pedestrian) == null) return null;
            if (ctl.player >= cfg.max_players) return null;
            return @intCast(ctl.player);
        }

        /// The ped behind `by`: the driver of a car, or `by` itself.
        fn culprit(self: *Self, by: EntityId) EntityId {
            if (self.state.world.get(by, c.Vehicle)) |v| return v.driver;
            return by;
        }

        /// A ped's occupation (`ids.Occupation`), civilian if unknown.
        pub fn occupationOf(self: *Self, ped: EntityId) u8 {
            if (comptime !sp) return 0;
            const o = self.state.world.get(ped, c.Objective) orelse return 0;
            return o.occupation;
        }

        /// File a crime report: `by` did `crime` at (x, y, z) (wanted-level.md
        /// 3.3). Never for law enforcement; shots and car damage only when
        /// one of that kind isn't already waiting. A player's report starts
        /// his recent-crime timer and moves the police's last known position
        /// to where he is.
        pub fn reportCrime(self: *Self, crime: Crime, by: EntityId, x: Fx, y: Fx, z: Fx) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            const who = culprit(self, by);
            if (who.isNone() or isLaw(occupationOf(self, who))) return;
            const pol = &self.state.sp.police;
            if (crime == .shot_fired or crime == .car_damaged) {
                for (0..pol.report_len) |i| {
                    const r = &pol.reports[(pol.report_head + i) % TP.report_ring];
                    if (r.crime == @intFromEnum(crime)) return markPlayer(self, who, x, y, z);
                }
            }
            const at = (pol.report_head + pol.report_len) % TP.report_ring;
            if (pol.report_len == TP.report_ring) {
                pol.report_head = @intCast((pol.report_head + 1) % TP.report_ring);
            } else pol.report_len += 1;
            pol.reports[at] = .{ .x = x, .y = y, .z = z, .by = who, .tick = self.state.tick, .crime = @intFromEnum(crime) };
            markPlayer(self, who, x, y, z);
        }

        fn markPlayer(self: *Self, who: EntityId, x: Fx, y: Fx, z: Fx) void {
            const slot = playerSlotOfPed(self, who) orelse return;
            const s = &self.state.sp.wanted[slot];
            s.recent = TP.recent_crime_ticks;
            s.last_x = x;
            s.last_y = y;
            s.last_z = z;
        }

        /// The crime reports waiting this tick (oldest first), for police
        /// and ped AI to read.
        pub fn reports(self: *const Self, out: []Report) usize {
            if (comptime !sp) return 0;
            const pol = &self.state.sp.police;
            const n = @min(out.len, pol.report_len);
            for (0..n) |i| out[i] = pol.reports[(pol.report_head + i) % TP.report_ring];
            return n;
        }

        /// Report a crime by `by` where its culprit stands.
        fn reportHere(self: *Self, crime: Crime, by: EntityId) void {
            const who = culprit(self, by);
            const t = self.state.world.get(who, c.Transform) orelse (self.state.world.get(by, c.Transform) orelse return);
            reportCrime(self, crime, by, t.x, t.y, t.z);
        }

        /// A shot or throw by `shooter` (weapons.md).
        pub fn onShot(self: *Self, shooter: EntityId) void {
            reportHere(self, .shot_fired, shooter);
        }

        /// Car `car` damaged by `by`.
        pub fn onCarDamaged(self: *Self, car: EntityId, by: EntityId) void {
            _ = car;
            if (by.isNone()) return;
            reportHere(self, .car_damaged, by);
        }

        /// Ped `victim` killed, hit last by `by` (wanted-level.md 3.2):
        /// +100 ordinary, +500 emergency worker, +1 gang member, for a
        /// player's kill.
        pub fn onKill(self: *Self, victim: EntityId, by: EntityId) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            const slot = self.creditSlot(by);
            if (slot == Self.Event.no_slot) return;
            if (eql(self.state.players[slot].ped, victim)) return;
            if (playerSlotOfPed(self, victim) != null) return; // other players: not a crime here
            const o = occupationOf(self, victim);
            const emergency = isEmergency(o);
            // By occupation: `Group.gang` is 0, not `gang_none`, on a freshly
            // spawned ped, so it can't tell members apart yet (D2).
            const gang_member = o == @intFromEnum(ids.Occupation.gang_member);
            addPoints(self, slot, if (emergency) TP.points_emergency else if (gang_member) TP.points_gang else TP.points_civilian);
            reportHere(self, if (emergency) .cop_killed else .ped_killed, by);
        }

        /// Car `v` destroyed, hit last by `by` (wanted-level.md 3.2): at least
        /// one star, or +200 if already wanted. Never while crushed.
        pub fn onCarDestroyed(self: *Self, v: *const c.Vehicle, by: EntityId, crushed: bool) void {
            _ = v;
            if (comptime !sp) return;
            if (crushed or self.predicting()) return;
            const slot = self.creditSlot(by);
            if (slot == Self.Event.no_slot) return;
            if (stars(self, slot) == 0) atLeastOneStar(self, slot) else addPoints(self, slot, TP.points_car_destroyed);
            reportHere(self, .car_destroyed, by);
        }

        /// Is `car` a police, SWAT or FBI vehicle? A car driven by law
        /// enforcement, or one the police own (`police.zig`).
        pub fn isLawCar(self: *Self, car: EntityId) bool {
            if (comptime !sp) return false;
            const v = self.state.world.get(car, c.Vehicle) orelse return false;
            if (Self.police.ownsCar(self, car)) return true;
            switch (TC.roleOf(v.model)) {
                .police, .swat, .fbi => return true,
                else => {},
            }
            if (v.driver.isNone()) return false;
            return switch (@as(ids.Occupation, @enumFromInt(occupationOf(self, v.driver)))) {
                .police, .swat, .fbi => true,
                else => false,
            };
        }

        /// Car `by_car` hit car `hit` with impulse `impact`, or crushed it
        /// (car-collision.md 3.7): a player driving into a police vehicle
        /// over 0.6, or crushing one, gets at least one star.
        pub fn onCarImpact(self: *Self, hit: EntityId, by_car: EntityId, impact: Fx, crushed: bool) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            Self.police.onImpact(self, hit, by_car);
            if (!crushed and impact <= TP.ram_cop_impact) return;
            const v = self.state.world.get(by_car, c.Vehicle) orelse return;
            const slot = playerSlotOfPed(self, v.driver) orelse return;
            if (!isLawCar(self, hit)) return;
            atLeastOneStar(self, slot);
            reportHere(self, .rammed_cop, by_car);
        }

        /// Cop `cop` has player `slot` in view (wanted-level.md 3.3): he
        /// takes the player as a target if the player is attacking with a
        /// weapon, already wanted, attacked this cop, or has the recent-crime
        /// timer running; then the last seen position moves and the player
        /// gets at least one star. Never while the player is mid-jump.
        /// Returns whether the cop took the player as a target.
        pub fn copSees(self: *Self, cop: EntityId, slot: u8) bool {
            const s = st(self, slot) orelse return false;
            const w = &self.state.world;
            const ped = self.state.players[slot].ped;
            const p = w.get(ped, c.Pedestrian) orelse return false;
            if (p.jump > 0) return false;
            const ctl = w.get(ped, c.Controller).?;
            const on_foot = w.get(ped, c.Riding).?.vehicle.isNone();
            // Invisible on foot: not seen (power-ups 3.1, ped-ai.md 3.15).
            if (on_foot and Self.career.invisible(self, slot)) return false;
            const armed = on_foot and ctl.in.buttons & prelude.Button.fire != 0;
            const car = self.state.players[slot].car;
            const attacked = if (w.get(cop, c.Health)) |h| !h.last_hit_by.isNone() and (eql(h.last_hit_by, ped) or eql(h.last_hit_by, car)) else false;
            if (!(armed or starsOf(s.points) > 0 or attacked or s.recent > 0)) return false;
            const t = w.get(ped, c.Transform).?;
            s.last_x = t.x;
            s.last_y = t.y;
            s.last_z = t.z;
            atLeastOneStar(self, slot);
            Self.police.sighted(self, slot);
            // A cop on foot who takes the player on shouts "Freeze!".
            if (w.get(cop, c.Riding)) |r| if (r.vehicle.isNone()) voice(self, slot, cop, 0);
            return true;
        }

        /// A police voice line (`Event.Kind.police_voice`): `what` 0 a shout
        /// by `who`, 1 radio chatter; at most one every `voice_gap` ticks
        /// per pursuit (ours).
        pub fn voice(self: *Self, slot: u8, who: EntityId, what: u8) void {
            const s = st(self, slot) orelse return;
            if (s.voice_cool > 0) return;
            const t = self.state.world.get(who, c.Transform) orelse return;
            s.voice_cool = TP.voice_gap;
            self.pushEvent(.{ .kind = .police_voice, .a = what, .b = slot, .x = t.x, .y = t.y, .z = t.z });
        }

        /// Wanted bookkeeping, once a tick (wanted-level.md 4.1): drop old
        /// reports, clear the level of a player who has respawned or has
        /// "no police" on, and run the recent-crime timer. Cops check the
        /// player through `copSees` (D1's threat search, E's crews).
        pub fn sysWanted(self: *Self) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            const pol = &self.state.sp.police;
            while (pol.report_len > 0 and pol.reports[pol.report_head].tick +% 1 < self.state.tick) {
                pol.report_head = @intCast((pol.report_head + 1) % TP.report_ring);
                pol.report_len -= 1;
            }
            for (0..cfg.max_players) |i| {
                const slot: u8 = @intCast(i);
                const s = &self.state.sp.wanted[i];
                const ped = self.state.players[i].ped;
                if (!eql(ped, s.ped)) {
                    // A new ped for this slot: joined or respawned.
                    s.ped = ped;
                    clear(self, slot);
                }
                if (s.flags & State.flag_no_police != 0 and s.points != 0) clear(self, slot);
                if (s.recent > 0) s.recent -= 1;
                if (s.voice_cool > 0) s.voice_cool -= 1;
            }
        }
    };
}
