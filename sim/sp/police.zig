//! Police (single player): the pursuit per wanted player, crew targets per
//! star tier, the new-car cap, the one-star timeout; later the crews,
//! roadblocks and arrests. Owner: workstream E (wanted-level.md 3.4-3.5,
//! police-ai.md).
//!
//! The crews themselves (dispatch, box-in and ram, searching, on-foot
//! arrest) are in `ai/police_crew.zig`.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const TP = @import("../tuning/police.zig");
const wanted = @import("wanted.zig");
const Pursuit = wanted.Pursuit;
const crew_mod = @import("../ai/police_crew.zig");
pub const Crew = crew_mod.Crew;
const roadblock_mod = @import("../ai/roadblock.zig");
pub const Roadblock = roadblock_mod.Roadblock;

/// In the SP state block (`state.sp.police`).
pub const State = extern struct {
    /// Crime reports (wanted-level.md 3.3), a ring: `report_head` is the
    /// oldest of `report_len`.
    reports: [TP.report_ring]wanted.Report = @splat(.{}),
    report_head: u8 = 0,
    report_len: u8 = 0,
    /// Global cap on new police cars spawning (wanted-level.md 3.5).
    new_car_cap: u8 = 0,
    /// `flag_*`.
    flags: u8 = 0,
    /// Crews on every pursuit (`ai/police_crew.zig`).
    crews: [TP.max_crews]Crew = @splat(.{}),
    /// Roadblocks (`ai/roadblock.zig`).
    roadblocks: [TP.max_roadblocks]Roadblock = @splat(.{}),
    /// Ticks before another roadblock may start.
    roadblock_cooldown: u16 = 0,
    _pad: u16 = 0,

    /// Debug: no crews are dispatched (pursuits still run their states).
    pub const flag_no_dispatch: u8 = 1;
};

/// Crew targets for a star tier (wanted-level.md 3.5).
pub const Targets = struct {
    /// Police car crews wanted.
    crews: u8,
    /// Highest crew kind for this tier (`ids.Occupation`), 0 none.
    kind: u8,
    /// Cap on new police cars spawning, given the live crews.
    new_cars: u8,
};

pub fn targetsFor(tier: u8, crews: u8) Targets {
    const police = @intFromEnum(ids.Occupation.police);
    return switch (tier) {
        0 => .{ .crews = 0, .kind = 0, .new_cars = 0 },
        1 => .{ .crews = 1, .kind = police, .new_cars = if (crews == 0) 1 else 0 },
        2, 3 => .{ .crews = 2, .kind = police, .new_cars = if (crews <= 1) 2 else 0 },
        // SWAT joins once police are active (police-ai.md 3.6).
        4 => .{ .crews = 2, .kind = @intFromEnum(ids.Occupation.swat), .new_cars = if (crews <= 1) 2 else 0 },
        // Police crews sent home; no police or SWAT and at most one FBI.
        5 => .{ .crews = 0, .kind = @intFromEnum(ids.Occupation.fbi), .new_cars = if (crews <= 1) 2 else 0 },
        else => .{ .crews = 0, .kind = @intFromEnum(ids.Occupation.army), .new_cars = 0 },
    };
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;
        const sp = Self.city;
        pub const crew = crew_mod.Sys(Self);
        pub const roadblock = roadblock_mod.Sys(Self);

        /// For the traffic spawner (F): place a roadblock instead of a
        /// plain car at block (bx, by), level `l`, lane direction `dir`?
        /// True if one went up (place no car then).
        pub fn tryRoadblock(self: *Self, bx: i32, by: i32, l: i32, dir: u2) bool {
            if (comptime !sp) return false;
            if (self.predicting()) return false;
            return roadblock.tryRoadblock(self, bx, by, l, dir);
        }

        /// A law-enforcement ped sighted player `slot` (police-ai.md 3.1,
        /// 3.3): the sight clock restarts, and a responding or searching
        /// pursuit turns active.
        pub fn sighted(self: *Self, slot: u8) void {
            if (comptime !sp) return;
            if (self.predicting() or slot >= cfg.max_players) return;
            const s = &self.state.sp.wanted[slot];
            s.sight = TP.sight_ticks;
            switch (@as(Pursuit, @enumFromInt(s.pursuit))) {
                .responding, .searching => s.pursuit = @intFromEnum(Pursuit.active),
                else => {},
            }
        }

        /// Is a crew actively pursuing player `slot`?
        pub fn pursued(self: *const Self, slot: u8) bool {
            if (comptime !sp) return false;
            if (slot >= cfg.max_players) return false;
            const s = &self.state.sp.wanted[slot];
            if (s.pursuit != @intFromEnum(Pursuit.active)) return false;
            for (self.state.sp.police.crews) |cr| {
                if (cr.slot != slot) continue;
                switch (@as(crew_mod.Phase, @enumFromInt(cr.phase))) {
                    .chasing, .on_foot, .boarding => return true,
                    else => {},
                }
            }
            return false;
        }

        pub fn pursuitOf(self: *const Self, slot: u8) Pursuit {
            if (comptime !sp) return .idle;
            if (slot >= cfg.max_players) return .idle;
            return @enumFromInt(self.state.sp.wanted[slot].pursuit);
        }

        /// Is `car` a police crew car?
        pub fn ownsCar(self: *const Self, car: EntityId) bool {
            if (comptime !sp) return false;
            return crew.crewOfCar(@constCast(self), car) != null or roadblock.ownsCar(@constCast(self), car);
        }

        /// Debug: dispatch crews or not.
        pub fn setDispatch(self: *Self, on: bool) void {
            if (comptime !sp) return;
            const f = &self.state.sp.police.flags;
            if (on) f.* &= ~State.flag_no_dispatch else f.* |= State.flag_no_dispatch;
        }

        /// Is `ped` a crew officer?
        pub fn isOfficer(self: *const Self, ped: EntityId) bool {
            if (comptime !sp) return false;
            return crew.crewOfPed(@constCast(self), ped) != null;
        }

        /// A car-on-car impact (`wanted.onCarImpact`): a crew's ram.
        pub fn onImpact(self: *Self, hit: EntityId, by_car: EntityId) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            crew.onImpact(self, hit, by_car);
        }

        fn releaseCrews(self: *Self, slot: u8, keep_kind: u8) void {
            for (&self.state.sp.police.crews) |*cr| {
                const ph: crew_mod.Phase = @enumFromInt(cr.phase);
                if (ph == .free or ph == .escort or cr.slot != slot) continue;
                if (keep_kind != 0 and cr.kind == keep_kind) continue;
                crew.release(self, cr);
            }
        }

        /// Add crews up to the tier's targets (wanted-level.md 3.5): police
        /// car crews, and at four stars one SWAT crew once police are active.
        fn dispatchCrews(self: *Self, slot: u8, s: *wanted.State) void {
            if (s.crew_timer > 0 or self.state.sp.police.flags & State.flag_no_dispatch != 0) return;
            const police: u8 = @intFromEnum(ids.Occupation.police);
            const swat: u8 = @intFromEnum(ids.Occupation.swat);
            const delay = if (crew.count(self, slot, 0) == 0) TP.first_crew_delay else TP.backup_crew_delay;
            if (s.new_cars > 0 and crew.count(self, slot, police) < s.crews_wanted) {
                if (crew.dispatch(self, slot, police, delay)) s.crew_timer = delay;
                return;
            }
            if (s.tier == 4 and s.pursuit == @intFromEnum(Pursuit.active) and crew.count(self, slot, swat) == 0) {
                if (crew.dispatch(self, slot, swat, delay)) s.crew_timer = delay;
            }
        }

        /// Surplus police crews go home when the target drops; at five
        /// stars and up every police and SWAT crew does (police-ai.md 3.6).
        fn trimCrews(self: *Self, slot: u8, s: *wanted.State) void {
            const police: u8 = @intFromEnum(ids.Occupation.police);
            // FBI and army tiers send police and SWAT home; the units
            // reskinned from traffic for this tier stay (police-ai.md 3.6).
            if (s.tier >= 5) return releaseCrews(self, slot, if (s.tier == 5) @intFromEnum(ids.Occupation.fbi) else @intFromEnum(ids.Occupation.army));
            if (s.tier < 4) {
                for (&self.state.sp.police.crews) |*cr| {
                    if (cr.slot == slot and cr.kind == @intFromEnum(ids.Occupation.swat) and cr.phase != @intFromEnum(crew_mod.Phase.free) and cr.phase != @intFromEnum(crew_mod.Phase.escort)) crew.release(self, cr);
                }
            }
            var n = crew.count(self, slot, police);
            for (&self.state.sp.police.crews) |*cr| {
                if (n <= s.crews_wanted) break;
                if (cr.slot != slot or cr.kind != police or cr.phase == @intFromEnum(crew_mod.Phase.free) or cr.phase == @intFromEnum(crew_mod.Phase.escort)) continue;
                crew.release(self, cr);
                n -= 1;
            }
        }

        /// An arrested player's body double is taken away by a police car
        /// two ticks before the countdown ends (power-ups-death-and-arrest.md
        /// 3.3 step 3).
        fn takeDoubles(self: *Self) void {
            const career = @import("career.zig");
            const TCr = @import("../tuning/career.zig");
            for (0..cfg.max_players) |i| {
                const cs = &self.state.sp.career[i];
                if (cs.phase != career.State.phase_busted or cs.countdown != TCr.police_take_double) continue;
                crew.callForDouble(self, cs.double);
            }
        }

        fn endPursuit(self: *Self, slot: u8, s: *wanted.State) void {
            releaseCrews(self, slot, 0);
            const was = s.pursuit != @intFromEnum(Pursuit.idle);
            s.pursuit = @intFromEnum(Pursuit.idle);
            s.crews = 0;
            s.crews_wanted = 0;
            s.new_cars = 0;
            s.top_kind = 0;
            s.sight = 0;
            s.crew_timer = 0;
            if (was) self.state.sp.police.new_car_cap = TP.new_car_cap_reset;
        }

        /// Each pursuit, once a tick (wanted-level.md 4.2): read the tier,
        /// set the crew targets and the new-car cap, run the one-star
        /// timeout, then advance the pursuit.
        pub fn sysPolice(self: *Self) void {
            if (comptime !sp) return;
            if (self.predicting()) return;
            for (0..cfg.max_players) |i| {
                const slot: u8 = @intCast(i);
                const s = &self.state.sp.wanted[i];
                const alive = if (self.pedOf(slot)) |ped| self.state.world.get(ped, c.Health).?.hp > 0 else false;
                const tier = wanted.starsOf(s.points);
                s.tier = tier;
                if (tier == 0 or !alive) {
                    endPursuit(self, slot, s);
                    s.quiet = 0;
                    continue;
                }
                s.crews = crew.count(self, slot, 0);
                const tg = targetsFor(tier, s.crews);
                s.crews_wanted = tg.crews;
                s.new_cars = tg.new_cars;
                s.top_kind = @max(s.top_kind, tg.kind);
                // One-star timeout (wanted-level.md 3.4).
                if (tier == 1 and !pursued(self, slot)) {
                    s.quiet += 1;
                    if (s.quiet >= TP.one_star_timeout) {
                        Self.wanted.clear(self, slot);
                        endPursuit(self, slot, s);
                        continue;
                    }
                } else s.quiet = 0;
                switch (@as(Pursuit, @enumFromInt(s.pursuit))) {
                    .idle => {
                        // Newly wanted: the police know where he is now
                        // (ours, for a level set by script or power-up
                        // with no crime report behind it).
                        if (s.recent == 0) {
                            if (self.transformOf(self.state.players[slot].ped)) |t| {
                                s.last_x = t.x;
                                s.last_y = t.y;
                                s.last_z = t.z;
                            }
                        }
                        s.pursuit = @intFromEnum(Pursuit.responding);
                    },
                    .responding, .searching => {},
                    .active => {
                        if (s.sight > 0) s.sight -= 1;
                        if (s.sight == 0) s.pursuit = @intFromEnum(Pursuit.searching);
                    },
                    _ => s.pursuit = @intFromEnum(Pursuit.idle),
                }
                if (s.crew_timer > 0) s.crew_timer -= 1;
                trimCrews(self, slot, s);
                dispatchCrews(self, slot, s);
            }
            // Crews act (wanted-level.md 4.3).
            crew.adoptReskins(self);
            for (&self.state.sp.police.crews) |*cr| crew.update(self, cr);
            roadblock.upkeep(self);
            takeDoubles(self);
        }
    };
}
