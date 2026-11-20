//! Gangs and respect (single player). Owner: workstream D2
//! (gangs-and-respect.md, script-declarations.md 2.11, ped-ai.md 3.13).
//!
//! The level's script declares the gangs (`defineGang`, `setKillReaction`,
//! `setAlwaysBasic`, `setKillsCount`); kills, hijacks and destroyed cars
//! change the player's respect with each gang (`onPedDeath`, `onHijack`,
//! `onCarDestroyed`, called by health and enter/exit); missions change it
//! in steps (`changeRespect`); gang members arm themselves by it
//! (`weaponForPlayer`).
//!
//! Single player has one player, so one respect row: the note's "player 1"
//! everywhere.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");

/// Numbers from gangs-and-respect.md 4 (all [exe] in the note).
pub const respect_min: i32 = -100;
pub const respect_max: i32 = 100;
pub const high_respect: i32 = 80;
pub const angry_below: i32 = -60;
pub const kill_weight: i32 = 5;
pub const light_weight: i32 = 1;
pub const step_size: i32 = 20;

/// One declared gang (script-declarations.md 2.11 and the separate
/// commands for kill reactions and the basic-weapon switch).
pub const Gang = extern struct {
    /// Hash of the gang's name (`nameHash`), which ties it to its map
    /// zones of kind `gang` with the same name.
    name_hash: u32 = 0,
    /// How much killing one member changes this gang's respect.
    kill_change: i8 = 0,
    /// Basic, angry and hate weapons (`Weapon.kind` numbering).
    basic: u8 = 0,
    angry: u8 = 0,
    hate: u8 = 0,
    car_model: u8 = no_model,
    car_remap: u8 = 0,
    ped_remap: u8 = 0,
    arrow: u8 = 0,
    /// `flag_*`.
    flags: u8 = 0,
    _pad: u8 = 0,
    /// For each other gang `g`: how `g` feels when you kill one of this
    /// gang's members (`reaction[g]`).
    reaction: [ids.max_gangs]i8 = @splat(0),

    pub const no_model: u8 = 0xFF;
    pub const flag_defined: u8 = 1;
    /// Members always use the basic weapon.
    pub const flag_always_basic: u8 = 2;
    /// Killing members changes nothing.
    pub const flag_kills_ignored: u8 = 4;
};

/// In the SP state block (`state.sp.gangs`).
pub const State = extern struct {
    /// Respect per gang for the player, -100..100 (gangs-and-respect.md).
    respect: [ids.max_gangs]i8 = @splat(0),
    /// Gangs the level declared (the highest index used, plus one).
    count: u8 = 0,
    _pad: u8 = 0,
    gangs: [ids.max_gangs]Gang = @splat(.{}),
};

/// What a gang declaration sets (script-declarations.md 2.11).
pub const Def = struct {
    name: []const u8,
    kill_change: i8,
    basic: u8,
    angry: u8,
    hate: u8,
    car_model: u8 = Gang.no_model,
    car_remap: u8 = 0,
    ped_remap: u8 = 0,
    arrow: u8 = 0,
};

/// FNV-1a of a gang or zone name, so names cost no state bytes.
pub fn nameHash(name: []const u8) u32 {
    var h: u32 = 2166136261;
    for (name) |b| {
        h ^= b;
        h *%= 16777619;
    }
    return h;
}

/// Respect plus `delta`, held to -100..100 whatever the sizes (3.1).
pub fn clampAdd(r: i8, delta: i32) i8 {
    return @intCast(std.math.clamp(@as(i32, r) +| delta, respect_min, respect_max));
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.single_player;

        fn st(self: *Self) *State {
            return &self.state.sp.gangs;
        }
        fn stc(self: *const Self) *const State {
            return &self.state.sp.gangs;
        }
        fn valid(gang: u8) bool {
            return gang < ids.max_gangs;
        }

        // ------------------------------------------------------------
        // Declarations

        /// Declare gang `gang` (script type 223). Respect starts at 0.
        pub fn defineGang(self: *Self, gang: u8, d: Def) void {
            if (comptime !sp) return;
            if (!valid(gang)) return;
            const s = st(self);
            s.gangs[gang] = .{
                .name_hash = nameHash(d.name),
                .kill_change = d.kill_change,
                .basic = d.basic,
                .angry = d.angry,
                .hate = d.hate,
                .car_model = d.car_model,
                .car_remap = d.car_remap,
                .ped_remap = d.ped_remap,
                .arrow = d.arrow,
                .flags = Gang.flag_defined,
            };
            s.respect[gang] = 0;
            if (gang >= s.count) s.count = gang + 1;
        }

        /// How `other` feels when the player kills a member of `gang`.
        pub fn setKillReaction(self: *Self, gang: u8, other: u8, reaction: i8) void {
            if (comptime !sp) return;
            if (!valid(gang) or !valid(other)) return;
            st(self).gangs[gang].reaction[other] = reaction;
        }

        pub fn setAlwaysBasic(self: *Self, gang: u8, on: bool) void {
            if (comptime !sp) return;
            if (!valid(gang)) return;
            setFlag(&st(self).gangs[gang], Gang.flag_always_basic, on);
        }

        /// Whether killing `gang`'s members changes respect at all.
        pub fn setKillsCount(self: *Self, gang: u8, on: bool) void {
            if (comptime !sp) return;
            if (!valid(gang)) return;
            setFlag(&st(self).gangs[gang], Gang.flag_kills_ignored, !on);
        }

        fn setFlag(g: *Gang, f: u8, on: bool) void {
            if (on) g.flags |= f else g.flags &= ~f;
        }

        pub fn gangInfo(self: *const Self, gang: u8) ?*const Gang {
            if (comptime !sp) return null;
            if (!valid(gang)) return null;
            const g = &stc(self).gangs[gang];
            return if (g.flags & Gang.flag_defined != 0) g else null;
        }

        /// The gang whose car model is `model`, or `ids.gang_none`.
        pub fn gangOfCarModel(self: *const Self, model: u8) u8 {
            if (comptime !sp) return ids.gang_none;
            const s = stc(self);
            for (s.gangs[0..s.count], 0..) |g, i| {
                if (g.flags & Gang.flag_defined != 0 and g.car_model == model) return @intCast(i);
            }
            return ids.gang_none;
        }

        // ------------------------------------------------------------
        // Respect

        pub fn respect(self: *const Self, gang: u8) i8 {
            if (comptime !sp) return 0;
            if (!valid(gang)) return 0;
            return stc(self).respect[gang];
        }

        pub fn setRespect(self: *Self, gang: u8, value: i8) void {
            if (comptime !sp) return;
            if (!valid(gang)) return;
            st(self).respect[gang] = clampAdd(value, 0);
        }

        /// Respect 80 or more (3.1).
        pub fn isHighRespect(self: *const Self, gang: u8) bool {
            return respect(self, gang) >= high_respect;
        }

        /// Change respect by whole steps (mission rewards, script): 20 x
        /// `steps` with `gang`, and the opposite way with every gang that
        /// has a non-zero kill reaction to it (3.2).
        pub fn changeRespect(self: *Self, gang: u8, steps: i8) void {
            if (comptime !sp) return;
            if (gangInfo(self, gang) == null) return;
            const s = st(self);
            const d = step_size * @as(i32, steps);
            s.respect[gang] = clampAdd(s.respect[gang], d);
            for (s.gangs[gang].reaction, 0..) |r, g| {
                if (r != 0 and g != gang) s.respect[g] = clampAdd(s.respect[g], -d);
            }
        }

        /// The respect power-up: +20 with the gang whose area the player
        /// is in (3.2).
        pub fn respectPowerUp(self: *Self, player: u32) void {
            if (comptime !sp) return;
            const ped = self.pedOf(player) orelse return;
            const t = self.state.world.get(ped, c.Transform).?;
            const g = gangOfArea(self, fx.toInt(t.x), fx.toInt(t.y));
            if (!valid(g)) return;
            st(self).respect[g] = clampAdd(st(self).respect[g], step_size);
        }

        /// A credited kill of one of `gang`'s members by `by` (a ped, or a
        /// car for its driver): -5 x its kill change, and +5 x each other
        /// gang's reaction; 1 instead of 5 when run over (3.2). Only kills
        /// credited to the player count.
        pub fn onKill(self: *Self, gang: u8, by: EntityId) void {
            if (comptime !sp) return;
            if (self.creditSlot(by) == Self.Event.no_slot) return;
            const run_over = self.state.world.get(by, c.Vehicle) != null;
            applyKill(self, gang, if (run_over) light_weight else kill_weight);
        }

        fn applyKill(self: *Self, gang: u8, weight: i32) void {
            if (!valid(gang)) return;
            const s = st(self);
            const g = &s.gangs[gang];
            if (g.flags & Gang.flag_defined == 0 or g.flags & Gang.flag_kills_ignored != 0) return;
            s.respect[gang] = clampAdd(s.respect[gang], -weight * g.kill_change);
            for (g.reaction, 0..) |r, other| {
                if (other != gang and r != 0) s.respect[other] = clampAdd(s.respect[other], weight * r);
            }
        }

        /// The gang a dead ped counts for: a gang member's own, or a
        /// background ped's turf gang (ped-ai.md 3.13), or none.
        pub fn gangOfPed(self: *Self, ped: EntityId) u8 {
            if (comptime !sp) return ids.gang_none;
            const gr = self.state.world.get(ped, c.Group) orelse return ids.gang_none;
            return if (valid(gr.gang)) gr.gang else ids.gang_none;
        }

        /// Ped `victim` died, hit last by `by`. Called by health (G) before
        /// the body is removed.
        pub fn onPedDeath(self: *Self, victim: EntityId, by: EntityId) void {
            if (comptime !sp) return;
            if (self.state.world.get(victim, c.Controller)) |ctl| {
                if (ctl.player != c.Controller.no_player) return;
            }
            const g = gangOfPed(self, victim);
            if (g == ids.gang_none) return;
            onKill(self, g, by);
        }

        /// The player took `car` (3.2): a gang car, by its model, counts
        /// as a 1-point kill against that gang.
        pub fn onHijack(self: *Self, car: EntityId, by: EntityId) void {
            if (comptime !sp) return;
            if (self.creditSlot(by) == Self.Event.no_slot) return;
            const v = self.state.world.get(car, c.Vehicle) orelse return;
            applyKill(self, gangOfCarModel(self, v.model), light_weight);
        }

        /// `car` was destroyed, hit last by `by`. Called by health (G).
        pub fn onCarDestroyed(self: *Self, car: EntityId, by: EntityId) void {
            if (comptime !sp) return;
            if (self.creditSlot(by) == Self.Event.no_slot) return;
            const v = self.state.world.get(car, c.Vehicle) orelse return;
            applyKill(self, gangOfCarModel(self, v.model), light_weight);
        }

        /// The weapon members of `gang` use against the player (3.3):
        /// basic in network games or when always-basic; hate at exactly
        /// -100; basic above -60; angry otherwise.
        pub fn weaponForPlayer(self: *const Self, gang: u8) u8 {
            if (comptime !sp) return 0;
            const g = gangInfo(self, gang) orelse return 0;
            if (g.flags & Gang.flag_always_basic != 0) return g.basic;
            const r: i32 = respect(self, gang);
            if (r == respect_min) return g.hate;
            if (r > angry_below) return g.basic;
            return g.angry;
        }

        /// Are gangs `a` and `b` enemies? Different declared gangs are
        /// (ped-ai.md 3.12 pairs any two groups of different gangs).
        pub fn hostile(self: *const Self, a: u8, b: u8) bool {
            _ = self;
            return valid(a) and valid(b) and a != b;
        }

        /// The gang whose area holds block (bx, by), or `ids.gang_none`:
        /// the first `gang` zone there, matched to a gang by name.
        pub fn gangOfArea(self: *const Self, bx: i32, by: i32) u8 {
            if (comptime !sp) return ids.gang_none;
            const l = self.level orelse return ids.gang_none;
            const z = l.zoneAt(.gang, bx, by) orelse return ids.gang_none;
            const h = nameHash(z.name);
            const s = stc(self);
            for (s.gangs[0..s.count], 0..) |g, i| {
                if (g.flags & Gang.flag_defined != 0 and g.name_hash == h) return @intCast(i);
            }
            return ids.gang_none;
        }

        pub fn sysGangs(self: *Self) void {
            _ = self;
        }
    };
}
