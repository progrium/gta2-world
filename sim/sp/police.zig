//! Police (single player): the pursuit per wanted player, crew targets per
//! star tier, the new-car cap, the one-star timeout; later the crews,
//! roadblocks and arrests. Owner: workstream E (wanted-level.md 3.4-3.5,
//! police-ai.md).
//!
//! Crews (dispatch, box-in and ram, searching, on-foot arrest) wait for the
//! objective API (D1) and car tasks and routes (F); until then a pursuit
//! runs its states and counts with no crews on the street.

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

/// In the SP state block (`state.sp.police`).
pub const State = extern struct {
    /// Crime reports (wanted-level.md 3.3), a ring: `report_head` is the
    /// oldest of `report_len`.
    reports: [TP.report_ring]wanted.Report = @splat(.{}),
    report_head: u8 = 0,
    report_len: u8 = 0,
    /// Global cap on new police cars spawning (wanted-level.md 3.5).
    new_car_cap: u8 = 0,
    flags: u8 = 0,
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
        const sp = Self.single_player;

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
            return s.pursuit == @intFromEnum(Pursuit.active) and s.crews > 0;
        }

        pub fn pursuitOf(self: *const Self, slot: u8) Pursuit {
            if (comptime !sp) return .idle;
            if (slot >= cfg.max_players) return .idle;
            return @enumFromInt(self.state.sp.wanted[slot].pursuit);
        }

        /// Is `car` a police crew or roadblock car? (No crews yet.)
        pub fn ownsCar(self: *const Self, car: EntityId) bool {
            _ = .{ self, car };
            return false;
        }

        fn endPursuit(self: *Self, s: *wanted.State) void {
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
                    endPursuit(self, s);
                    s.quiet = 0;
                    continue;
                }
                const tg = targetsFor(tier, s.crews);
                s.crews_wanted = tg.crews;
                s.new_cars = tg.new_cars;
                s.top_kind = @max(s.top_kind, tg.kind);
                // One-star timeout (wanted-level.md 3.4).
                if (tier == 1 and !pursued(self, slot)) {
                    s.quiet += 1;
                    if (s.quiet >= TP.one_star_timeout) {
                        Self.wanted.clear(self, slot);
                        endPursuit(self, s);
                        continue;
                    }
                } else s.quiet = 0;
                switch (@as(Pursuit, @enumFromInt(s.pursuit))) {
                    .idle => {
                        s.pursuit = @intFromEnum(Pursuit.responding);
                        s.crew_timer = TP.first_crew_delay;
                    },
                    .responding, .searching => {},
                    .active => {
                        if (s.sight > 0) s.sight -= 1;
                        if (s.sight == 0) s.pursuit = @intFromEnum(Pursuit.searching);
                    },
                    _ => s.pursuit = @intFromEnum(Pursuit.idle),
                }
                if (s.crew_timer > 0) s.crew_timer -= 1;
            }
        }
    };
}
