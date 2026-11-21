//! Player career (single player): lives, multiplier, cash/points, jail
//! cards, death and arrest state, the power-up timers that are not on the
//! ped. Owner: workstream G (power-ups-death-and-arrest.md, scoring.md,
//! script-player.md). The wasted and busted sequences themselves are in
//! `sys/death.zig`; this file is the state and the API others call.
//!
//! Every function is safe to call in any configuration: outside `sp` the
//! setters do nothing and the getters return the defaults (multiplier 1).

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const TC = @import("../tuning/career.zig");

/// Per player, in the SP state block (`state.sp.career[slot]`).
pub const State = extern struct {
    /// Spare lives, 0-99: dying with none left is game over.
    lives: u8 = 0,
    /// Score multiplier, 1-99 once started.
    multiplier: u8 = 0,
    jail_cards: u8 = 0,
    /// `flag_*`.
    flags: u8 = 0,
    /// Points; in GTA2 cash and points are one number.
    points: i32 = 0,
    /// `phase_*`.
    phase: u8 = phase_playing,
    /// Ticks left in the wasted or busted countdown.
    countdown: u8 = 0,
    /// Cause of the last death (the kill event's weapon numbering).
    cause: u8 = 0,
    /// The kill-frenzy weapon (a hand weapon index), or `no_weapon`.
    frenzy_weapon: u8 = no_weapon,
    /// The body left behind while wasted or busted, or none.
    double: EntityId = .none,
    /// The car the player was in when wasted or busted: its vehicle
    /// weapons go with his own at the end of the countdown.
    death_car: EntityId = .none,
    /// Power-up timers not on the ped, in ticks.
    electro_fingers: u16 = 0,
    invisible: u16 = 0,
    /// Elvis kills have their own combo (scoring.md 3.2).
    elvis_combo: u8 = 0,
    elvis_timer: u8 = 0,
    /// Emergency-vehicle kinds destroyed in the current window (bits 0-4:
    /// ambulance, police, SWAT, FBI, fire truck) and ticks left in it.
    emergency_kinds: u8 = 0,
    emergency_timer: u8 = 0,
    /// Accuracy (scoring.md 3.4): projectile hits by weapon, hand weapons
    /// 0-9 then 10 for vehicle weapons, on a threat and on anyone else.
    hits_threat: [11]u16 = @splat(0),
    hits_other: [11]u16 = @splat(0),
    _pad: [2]u16 = @splat(0),

    pub const no_weapon: u8 = 0xFF;

    pub const phase_playing: u8 = 0;
    pub const phase_wasted: u8 = 1;
    pub const phase_busted: u8 = 2;
    /// The level is over: no lives left (or busted in a bonus stage).
    pub const phase_game_over: u8 = 3;

    /// Lives and multiplier have their starting values.
    pub const flag_started: u8 = 1;
    /// Options (cheats): keep weapons after death or arrest; an unlimited
    /// jail card; unlimited double damage; permanent invisibility.
    pub const flag_keep_weapons: u8 = 2;
    pub const flag_unlimited_jail: u8 = 4;
    pub const flag_unlimited_double: u8 = 8;
    pub const flag_always_invisible: u8 = 16;
    /// A bonus stage: an arrest ends it as game over (3.3 step 5).
    pub const flag_bonus_stage: u8 = 32;
    /// Set whenever the player is wasted or busted; the script's
    /// "mission ended by death or arrest" handling (A1) reads and clears it.
    pub const flag_was_out: u8 = 64;
};

comptime {
    // Layout guard: no implicit padding.
    var sum: usize = 0;
    for (@typeInfo(State).@"struct".field_types) |FT| sum += @sizeOf(FT);
    if (sum != @sizeOf(State)) @compileError("career.State has implicit padding");
}

/// How a score is added (scoring.md: some rewards ignore the multiplier).
pub const Multiplied = enum { with_multiplier, flat };

/// The power-ups (power-ups-death-and-arrest.md 3.1), for `takePowerUp`
/// and `givePowerUp`.
pub const PowerUp = enum(u8) {
    multiplier = 0,
    extra_life = 1,
    health = 2,
    armour = 3,
    jail_card = 4,
    cop_bribe = 5,
    invulnerability = 6,
    double_damage = 7,
    fast_reload = 8,
    electro_fingers = 9,
    invisibility = 10,
    respect = 11,
    instant_gang = 12,
    _,
};

pub fn Sys(comptime Self: type) type {
    return struct {
        const sp = Self.single_player;
        const max_players = Self.config.max_players;

        /// The career row of `slot`, or null outside `sp` or out of range.
        pub fn row(self: *Self, slot: u8) ?*State {
            if (comptime !sp) return null;
            if (slot >= max_players) return null;
            return &self.state.sp.career[slot];
        }
        pub fn rowConst(self: *const Self, slot: u8) ?*const State {
            if (comptime !sp) return null;
            if (slot >= max_players) return null;
            return &self.state.sp.career[slot];
        }

        /// Give `slot` its starting lives and multiplier once.
        pub fn start(self: *Self, slot: u8) void {
            const cs = row(self, slot) orelse return;
            if (cs.flags & State.flag_started != 0) return;
            cs.flags |= State.flag_started;
            cs.lives = TC.start_lives;
            cs.multiplier = 1;
            cs.frenzy_weapon = State.no_weapon;
        }

        /// Add points (or cash) for `slot`: `amount` x the multiplier, or
        /// flat (scoring.md 3.1, script-player.md 2.1). The player row's
        /// `score` mirrors it for the hosts.
        pub fn addScore(self: *Self, slot: u8, amount: i32, how: Multiplied) void {
            if (self.predicting()) return;
            const cs = row(self, slot) orelse return;
            start(self, slot);
            const m: i32 = if (how == .with_multiplier) @max(1, cs.multiplier) else 1;
            cs.points +|= amount *| m;
            self.state.players[slot].score = cs.points;
        }
        pub fn score(self: *const Self, slot: u8) i32 {
            const cs = rowConst(self, slot) orelse return 0;
            return cs.points;
        }

        pub fn lives(self: *const Self, slot: u8) u8 {
            const cs = rowConst(self, slot) orelse return 0;
            return cs.lives;
        }
        /// Change the spare lives by `n`, clamped to 0-99.
        pub fn addLives(self: *Self, slot: u8, n: i8) void {
            const cs = row(self, slot) orelse return;
            start(self, slot);
            cs.lives = @intCast(std.math.clamp(@as(i32, cs.lives) + n, 0, TC.lives_max));
        }

        pub fn multiplier(self: *const Self, slot: u8) u8 {
            const cs = rowConst(self, slot) orelse return 1;
            return @max(1, cs.multiplier);
        }
        /// Set the multiplier, clamped to 1-99.
        pub fn setMultiplier(self: *Self, slot: u8, m: u8) void {
            const cs = row(self, slot) orelse return;
            start(self, slot);
            cs.multiplier = std.math.clamp(m, 1, TC.multiplier_max);
        }
        /// Change the multiplier by `n`, clamped to 1-99 (script-player.md
        /// 2.1, type 282).
        pub fn addMultiplier(self: *Self, slot: u8, n: i8) void {
            const cs = row(self, slot) orelse return;
            start(self, slot);
            cs.multiplier = @intCast(std.math.clamp(@as(i32, cs.multiplier) + n, 1, TC.multiplier_max));
        }

        pub fn addJailCard(self: *Self, slot: u8) void {
            _ = takePowerUp(self, slot, .jail_card);
        }
        pub fn jailCards(self: *const Self, slot: u8) u8 {
            const cs = rowConst(self, slot) orelse return 0;
            return cs.jail_cards;
        }

        /// Wasted or busted and not yet back on the street (or game over).
        pub fn isOut(self: *const Self, slot: u8) bool {
            const cs = rowConst(self, slot) orelse return false;
            return cs.phase != State.phase_playing;
        }
        pub fn isGameOver(self: *const Self, slot: u8) bool {
            const cs = rowConst(self, slot) orelse return false;
            return cs.phase == State.phase_game_over;
        }
        /// The body double while wasted or busted (the camera holds on it;
        /// the police drive off with it after an arrest), or none.
        pub fn bodyDouble(self: *const Self, slot: u8) EntityId {
            const cs = rowConst(self, slot) orelse return .none;
            return cs.double;
        }
        /// Is `id` some player's body double?
        pub fn isDouble(self: *const Self, id: EntityId) bool {
            if (comptime !sp) return false;
            if (id.isNone()) return false;
            for (self.state.sp.career) |cs| if (prelude.eql(cs.double, id)) return true;
            return false;
        }

        /// Start the busted sequence (power-ups-death-and-arrest.md 3.3).
        /// `by` is the arresting officer (unused for now).
        pub fn bust(self: *Self, slot: u8, by: EntityId) void {
            Self.death.startBusted(self, slot, by);
        }

        /// Invisible to peds and police (ped-ai.md 3.15; the AI also
        /// checks that the player is on foot).
        pub fn invisible(self: *const Self, slot: u8) bool {
            const cs = rowConst(self, slot) orelse return false;
            return cs.invisible > 0 or cs.flags & State.flag_always_invisible != 0;
        }
        pub fn electroFingers(self: *const Self, slot: u8) bool {
            const cs = rowConst(self, slot) orelse return false;
            return cs.electro_fingers > 0;
        }

        /// Set the ped AI's invisibility and electro-fingers flags on the
        /// player's ped from the career's timers (ped-ai.md 3.14-3.15).
        pub fn applyEffects(self: *Self, slot: u8) void {
            const cs = row(self, slot) orelse return;
            const ped = self.state.players[slot].ped;
            Self.objectives.setInvisible(self, ped, invisible(self, slot));
            Self.objectives.setElectroFingers(self, ped, cs.electro_fingers > 0);
        }

        /// Set (or with `State.no_weapon` clear) the kill-frenzy weapon
        /// (script-characters.md 2.x, types 411 and 412). A hand weapon is
        /// given unlimited ammo until it is cleared or the player dies.
        pub fn setFrenzyWeapon(self: *Self, slot: u8, weapon: u8) void {
            const cs = row(self, slot) orelse return;
            const w = &self.state.world;
            const ped = self.state.players[slot].ped;
            if (cs.frenzy_weapon < T.weapon_count) {
                if (w.get(ped, c.Weapon)) |wpn| wpn.rounds()[cs.frenzy_weapon] = 0;
            }
            cs.frenzy_weapon = if (weapon < T.weapon_count) weapon else State.no_weapon;
            if (weapon < T.weapon_count) {
                if (w.get(ped, c.Weapon)) |wpn| {
                    wpn.rounds()[weapon] = T.infinite_ammo;
                    wpn.kind = weapon;
                }
            }
        }

        /// Collect a power-up (power-ups-death-and-arrest.md 3.1). False
        /// when it is refused, and then the pickup stays where it is.
        pub fn takePowerUp(self: *Self, slot: u8, which: PowerUp) bool {
            if (comptime !sp) return false;
            if (self.predicting()) return false;
            const cs = row(self, slot) orelse return false;
            start(self, slot);
            const w = &self.state.world;
            const ped_id = self.state.players[slot].ped;
            switch (which) {
                .multiplier => {
                    if (cs.multiplier >= TC.multiplier_max) return false;
                    cs.multiplier += 1;
                },
                .extra_life => {
                    if (cs.lives >= TC.lives_max) return false;
                    cs.lives += 1;
                },
                .jail_card => {
                    if (cs.jail_cards > 0) return false;
                    cs.jail_cards = 1;
                },
                .cop_bribe => {
                    if (self.state.sp.wanted[slot].points == 0) return false;
                    Self.wanted.clear(self, slot);
                },
                .electro_fingers => {
                    if (!refresh(&cs.electro_fingers, TC.electro_fingers_ticks)) return false;
                    applyEffects(self, slot);
                },
                .invisibility => {
                    if (!refresh(&cs.invisible, TC.invisible_ticks)) return false;
                    applyEffects(self, slot);
                },
                .respect => {
                    const t = w.get(ped_id, c.Transform) orelse return false;
                    const gang = Self.gangs.gangOfArea(self, fx.toInt(t.x), fx.toInt(t.y));
                    if (gang == ids.gang_none) return false;
                    if (Self.gangs.respect(self, gang) >= TC.respect_max) return false;
                    Self.gangs.respectPowerUp(self, slot);
                },
                .instant_gang => {
                    // Refused unless on foot; then up to 4 nearby peds
                    // join the player's group (D2, ped-ai.md 3.11).
                    const r = w.get(ped_id, c.Riding) orelse return false;
                    if (!r.vehicle.isNone()) return false;
                    _ = Self.gangs.instantGang(self, slot);
                },
                .health => {
                    const h = w.get(ped_id, c.Health) orelse return false;
                    if (h.hp >= T.ped_hp) return false;
                    h.hp = T.ped_hp;
                },
                .armour => {
                    const p = w.get(ped_id, c.Pedestrian) orelse return false;
                    if (p.armour >= TC.armour_charges) return false;
                    p.armour = TC.armour_charges;
                },
                .invulnerability => {
                    const p = w.get(ped_id, c.Pedestrian) orelse return false;
                    return refresh(&p.invulnerable, TC.invulnerable_ticks);
                },
                .double_damage => {
                    const p = w.get(ped_id, c.Pedestrian) orelse return false;
                    return refresh(&p.double_damage, TC.double_damage_ticks);
                },
                .fast_reload => {
                    const p = w.get(ped_id, c.Pedestrian) orelse return false;
                    return refresh(&p.fast_reload, TC.fast_reload_ticks);
                },
                _ => return false,
            }
            return true;
        }

        /// A timed power-up restarts at full length unless it is exactly
        /// full already (3.1, "Refreshing").
        fn refresh(timer: *u16, full: u16) bool {
            if (timer.* == full) return false;
            timer.* = full;
            return true;
        }

        /// Give a timed power-up outright for `ticks` (scripts, kill
        /// frenzies): no refusal. `which` is a `PowerUp`; untimed ones are
        /// collected as by `takePowerUp`.
        pub fn givePowerUp(self: *Self, slot: u8, which: u8, ticks: u16) void {
            if (self.predicting()) return;
            const cs = row(self, slot) orelse return;
            start(self, slot);
            const p = self.state.world.get(self.state.players[slot].ped, c.Pedestrian);
            switch (@as(PowerUp, @enumFromInt(which))) {
                .electro_fingers => {
                    cs.electro_fingers = ticks;
                    applyEffects(self, slot);
                },
                .invisibility => {
                    cs.invisible = ticks;
                    applyEffects(self, slot);
                },
                .invulnerability => if (p) |pp| {
                    pp.invulnerable = ticks;
                },
                .double_damage => if (p) |pp| {
                    pp.double_damage = ticks;
                },
                .fast_reload => if (p) |pp| {
                    pp.fast_reload = ticks;
                },
                else => _ = takePowerUp(self, slot, @enumFromInt(which)),
            }
        }

        /// Options (cheats) from `State.flag_*`: keep weapons, unlimited
        /// jail card, unlimited double damage, always invisible, bonus stage.
        pub fn setOption(self: *Self, slot: u8, flag: u8, on: bool) void {
            const cs = row(self, slot) orelse return;
            if (on) cs.flags |= flag else cs.flags &= ~flag;
            applyEffects(self, slot);
        }

        /// Count a projectile hit by `slot` for the accuracy statistics
        /// (scoring.md 3.4). `weapon` is the projectile's weapon byte.
        pub fn countHit(self: *Self, slot: u8, weapon: u8, threat: bool) void {
            const cs = row(self, slot) orelse return;
            const i: usize = if (weapon < T.weapon_count) weapon else 10;
            if (threat) cs.hits_threat[i] +|= 1 else cs.hits_other[i] +|= 1;
        }
    };
}
