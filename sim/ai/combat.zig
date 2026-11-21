//! Fighting (ped-ai.md 3.7-3.9, weapons.md 3.8): chasing and keeping
//! range, weapon choice, aim jitter, police fire rationing, test shots,
//! and the punch. Owner: workstream D1.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const map = prelude.map;
const ecs = prelude.ecs;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const ids = @import("../ids.zig");
const anim = @import("../anim.zig");
const A = @import("../tuning/ped_ai.zig");
const O = c.Objective;
const P = @import("move.zig").P;
const threat_mod = @import("threat.zig");

/// `abi.rand` salts (D1 range 0x1300-0x13FF).
pub const salt_miss: u32 = 0x1300;
pub const salt_miss2: u32 = 0x1301;
pub const salt_miss_big: u32 = 0x1302;
pub const salt_miss_side: u32 = 0x1303;

pub fn Sys(comptime Self: type) type {
    return struct {
        const move = @import("move.zig").Sys(Self);
        const threat = threat_mod.Sys(Self);
        const CensusT = threat.CensusT;
        pub const Progress = threat.Progress;

        fn isPistolFamily(k: u8) bool {
            return k == T.weapon_pistol or k == T.weapon_smg or k == T.weapon_dual_pistol or k == T.weapon_silenced;
        }

        fn isThrown(k: u8) bool {
            return k == T.weapon_grenade or k == T.weapon_molotov;
        }

        fn has(p: P, k: u8) bool {
            return p.wpn.roundsConst()[k] != 0;
        }

        /// The heaviest weapon a ped holds other than the pistol, if any.
        fn heavy(p: P) ?u8 {
            var k: u8 = T.weapon_count;
            while (k > 1) {
                k -= 1;
                if (k != T.weapon_pistol and has(p, k)) return k;
            }
            return if (has(p, 1)) 1 else null;
        }

        /// Weapon choice (3.8): police and guards use their heavier weapon
        /// only against the player in a moving car; FBI (and roadblock
        /// cops) use it at range or against vehicles and the sidearm
        /// within 0.5 block of a ped on foot.
        fn chooseWeapon(self: *Self, p: P, target: EntityId, dist: Fx, target_in_car: bool, car_moving: bool) void {
            const occ: ids.Occupation = @enumFromInt(p.o.occupation);
            const hv = heavy(p);
            switch (occ) {
                .police, .guard => {
                    const want_heavy = threat.playerSlot(self, target) != null and target_in_car and car_moving;
                    if (want_heavy and hv != null) p.wpn.kind = hv.? else if (has(p, T.weapon_pistol)) p.wpn.kind = T.weapon_pistol;
                },
                .fbi, .army, .swat => {
                    if (!target_in_car and dist <= A.fbi_sidearm_range and has(p, T.weapon_pistol)) {
                        p.wpn.kind = T.weapon_pistol;
                    } else if (hv) |k| p.wpn.kind = k;
                },
                else => {},
            }
        }

        /// Aim jitter (3.8) for the next shot, in angle units.
        fn jitter(self: *Self, p: P) u16 {
            if (p.o.flags & O.flag_accurate != 0 or !isPistolFamily(p.wpn.kind)) return 0;
            if (p.wpn.cooldown > 1) return @bitCast(@as(i16, p.o.jitter) * 64);
            var miss = self.randBelow(p.id, salt_miss, 256) < A.miss_chance_256;
            const moving = p.vel.vx != 0 or p.vel.vy != 0;
            if (!miss and moving) miss = self.randBelow(p.id, salt_miss2, 256) < A.miss_chance_256;
            var off: i32 = 0;
            if (miss) {
                off = if (self.randBelow(p.id, salt_miss_big, 256) < A.big_miss_256) A.miss_big else A.miss_small;
                if (self.randBelow(p.id, salt_miss_side, 2) == 0) off = -off;
            }
            p.o.jitter = @intCast(@divTrunc(off, 64));
            return @truncate(@as(u32, @bitCast(off)));
        }

        /// Would a shot along `angle` from the shooter reach `target`
        /// before a wall or another body? (The invisible test shot.)
        pub fn rayReaches(self: *Self, p: P, angle: u16, target: EntityId, tpos: c.Transform) bool {
            const dist = fx.length(tpos.x - p.t.x, tpos.y - p.t.y);
            const ex = p.t.x + fx.mul(fx.cos(angle), dist);
            const ey = p.t.y + fx.mul(fx.sin(angle), dist);
            if (fx.length(ex - tpos.x, ey - tpos.y) > A.line_clearance + T.ped_radius) return false;
            if (map.moveHitsWall(self.grid, p.t.x, p.t.y, ex, ey, p.t.z + T.shot_height, map.bullet)) return false;
            const dx = fx.cos(angle);
            const dy = fx.sin(angle);
            const tb = self.state.world.table(Self.Ped);
            var i: u32 = 0;
            while (i < tb.len) : (i += 1) {
                if (tb.slot[i] != ecs.Slot.alive) continue;
                const id = EntityId.make(.ped, i, tb.gen[i]);
                if (eql(id, p.id) or eql(id, target)) continue;
                if (!tb.col(c.Riding)[i].vehicle.isNone() or tb.col(c.Health)[i].hp <= 0) continue;
                const bt = tb.col(c.Transform)[i];
                if (fx.abs(bt.z - p.t.z) > A.same_height) continue;
                const rx = bt.x - p.t.x;
                const ry = bt.y - p.t.y;
                const along = fx.mul(rx, dx) + fx.mul(ry, dy);
                if (along <= 0 or along >= dist) continue;
                const across = fx.abs(fx.mul(rx, dy) - fx.mul(ry, dx));
                if (across < A.line_clearance) return false;
            }
            return true;
        }

        fn testShot(self: *Self, p: P, target: EntityId, tpos: c.Transform) bool {
            const aim = move.bearing(p.t, tpos.x, tpos.y);
            if (rayReaches(self, p, aim, target, tpos)) return true;
            if (p.wpn.kind == T.weapon_shotgun) {
                const offs = [4]u16{ A.shotgun_test_spread, 0 -% A.shotgun_test_spread, 2 *% A.shotgun_test_spread, 0 -% 2 *% A.shotgun_test_spread };
                for (offs) |off| if (rayReaches(self, p, aim +% off, target, tpos)) return true;
            }
            return false;
        }

        /// Police rationing (3.8): against a player on foot, nobody fires
        /// until 2 police are on screen, and one at a time.
        fn mayFire(self: *Self, cs: *CensusT, p: P, target: EntityId) bool {
            if (!threat_mod.isLaw(p.o.occupation)) return true;
            const slot = threat.playerSlot(self, target) orelse return true;
            if (!threat.onFoot(self, target)) return true;
            if (cs.law_on_screen[slot] < A.police_min_present) return false;
            const holder = cs.firing[slot];
            if (holder.isNone() or eql(holder, p.id)) {
                cs.firing[slot] = p.id;
                p.o.flags |= O.flag_firing_turn;
                return true;
            }
            return false;
        }

        fn releaseTurn(cs: *CensusT, p: P) void {
            if (p.o.flags & O.flag_firing_turn == 0) return;
            p.o.flags &= ~O.flag_firing_turn;
            for (&cs.firing) |*f| if (eql(f.*, p.id)) {
                f.* = .none;
            };
        }

        /// Sidestep to find a clear line (while test shots fail).
        fn sidestep(self: *Self, p: P, tpos: c.Transform) void {
            const b = move.bearing(p.t, tpos.x, tpos.y);
            const side: u16 = if ((self.state.tick >> 5) & 1 == 0) 16384 else 49152;
            const h = move.clearHeading(self, p, b +% side);
            p.ctl.in = .{ .steer = 0, .throttle = 127, .buttons = prelude.Button.direct | prelude.Button.run, .aim = h, .seq = 0 };
            p.o.flags |= O.flag_steered;
        }

        /// Kill a ped (or attack a car when `car_target`): ranged by the
        /// range table, or the punch when unarmed.
        pub fn attackTarget(self: *Self, cs: *CensusT, p: P, target: EntityId, car_target: bool, assigned: bool) Progress {
            const w = &self.state.world;
            if (car_target) {
                const v = w.get(target, c.Vehicle) orelse return .passed;
                if (v.flags & c.Vehicle.flag_wrecked != 0) return .passed;
            } else {
                if (!threat.eligible(self, target)) {
                    releaseTurn(cs, p);
                    return .passed;
                }
                // Invisibility calls off a chase (3.15).
                if (threat.invisibleOnFoot(self, target)) {
                    releaseTurn(cs, p);
                    return .failed;
                }
            }
            if (p.ride.vehicle.isNone() == false) return .running; // riding: nothing to do on foot
            const tpos = threat.posOf(self, target) orelse return .passed;
            var in_car = car_target;
            var car_moving = false;
            if (!car_target) {
                if (w.get(target, c.Riding)) |r| {
                    if (!r.vehicle.isNone()) {
                        in_car = true;
                        if (w.get(r.vehicle, c.Velocity)) |cv| car_moving = Self.speedOf(cv) > A.car_still_speed;
                    }
                }
            } else if (w.get(target, c.Velocity)) |cv| car_moving = Self.speedOf(cv) > A.car_still_speed;
            const dist = fx.length(tpos.x - p.t.x, tpos.y - p.t.y);
            const occ: ids.Occupation = @enumFromInt(p.o.occupation);
            const unarmed = !threat.armed(self, p.id) or occ == .mugger;
            if (unarmed) {
                releaseTurn(cs, p);
                return punch(self, p, target, assigned);
            }
            chooseWeapon(self, p, target, dist, in_car, car_moving);
            const k = p.wpn.kind;
            var r = A.ranges[k];
            // A car, or a ped in a nearly still car, has its own ranges.
            if (car_target or (in_car and !car_moving)) r = .{ .fire = A.car_fire_range, .back_off = A.car_back_off };
            const is_leader = isLeader(self, p.id);
            if (!in_car and (occ == .fbi or is_leader)) r.close_in = A.leader_close_in;
            p.o.flags |= O.flag_attacking;
            // Hit and run: retreat at full speed for a while.
            if (p.o.retreat > 0) {
                p.o.retreat -= 1;
                releaseTurn(cs, p);
                move.runFrom(self, p, tpos.x, tpos.y);
                return .running;
            }
            const explosive = T.weapons[k].explosive;
            const covered = isThrown(k) and map.blocks(self.grid, p.t.x, p.t.y, p.t.z + fx.one, 0);
            if ((r.back_off > 0 and dist < r.back_off) or (explosive and dist < A.explosive_min_range) or covered) {
                releaseTurn(cs, p);
                move.runFrom(self, p, tpos.x, tpos.y);
                return .running;
            }
            const want = if (r.close_in > 0) @min(r.close_in, r.fire) else r.fire;
            if (dist > want) {
                // Closing in. A gun already near its range keeps firing on
                // the move (ours: within a block past it), so a fleeing
                // target at running pace is not out of reach for ever.
                move.chase(self, p, tpos.x, tpos.y, dist);
                const aim_on = move.bearing(p.t, tpos.x, tpos.y);
                const run_fire = r.close_in == 0 and !isThrown(k) and dist <= r.fire + A.run_and_gun and
                    p.o.flags & O.flag_test_shots == 0 and move.angleDiff(p.t.heading, aim_on) <= A.fire_cone and mayFire(self, cs, p, target);
                if (run_fire) p.ctl.in.buttons |= prelude.Button.fire else releaseTurn(cs, p);
                return .running;
            }
            // In range: face the target and fire, with jitter.
            if (p.o.flags & O.flag_test_shots != 0) {
                releaseTurn(cs, p);
                if (p.o.wait > 0) {
                    p.o.wait -= 1;
                    move.aimAt(p, tpos.x, tpos.y, 0, false);
                    return .running;
                }
                p.o.wait = if (k == T.weapon_smg or k == T.weapon_silenced) A.test_wait_mg else A.test_wait;
                if (testShot(self, p, target, tpos)) {
                    p.o.flags &= ~O.flag_test_shots;
                    move.aimAt(p, tpos.x, tpos.y, 0, false);
                } else sidestep(self, p, tpos);
                return .running;
            }
            const off = jitter(self, p);
            const aim = move.bearing(p.t, tpos.x, tpos.y) +% off;
            var fire = move.angleDiff(p.t.heading, aim) <= A.fire_cone and mayFire(self, cs, p, target);
            if (!fire) releaseTurn(cs, p);
            if (isThrown(k)) {
                // A thrower tests its line once before each throw, then
                // winds up in proportion to the distance and lets go.
                const want_charge: u16 = @intCast(@min(@as(i32, T.throw_strength_max), 10 + @divTrunc(dist * 20, fx.one)));
                if (p.ped.charge == 0 and fire and !testShot(self, p, target, tpos)) {
                    sidestep(self, p, tpos);
                    return .running;
                }
                if (p.ped.charge >= want_charge) fire = false;
            }
            move.stand(p, aim, fire);
            return .running;
        }

        fn isLeader(self: *Self, id: EntityId) bool {
            if (comptime !Self.Ped.has(c.Group)) return false;
            if (comptime @hasDecl(Self.gangs, "isLeader")) return Self.gangs.isLeader(self, id);
            return false;
        }

        // ------------------------------------------------------------------
        // The punch (3.9)

        pub fn punch(self: *Self, p: P, target: EntityId, assigned: bool) Progress {
            const w = &self.state.world;
            if (!threat.eligible(self, target)) return .passed;
            if (threat.invisibleOnFoot(self, target)) return .failed;
            p.o.flags |= O.flag_attacking;
            const tpos = threat.posOf(self, target) orelse return .passed;
            const dist = fx.length(tpos.x - p.t.x, tpos.y - p.t.y);
            const law = threat_mod.isLaw(p.o.occupation);
            // A target in a car: pull the driver out if the car is slow
            // enough (the door sequence is D2's).
            if (w.get(target, c.Riding)) |r| {
                if (!r.vehicle.isNone()) {
                    const cv = w.get(r.vehicle, c.Velocity) orelse return .failed;
                    const limit = if (law) A.pull_out_speed_law else A.pull_out_speed;
                    if (Self.speedOf(cv) > limit) return .failed;
                    if (dist > T.enter_reach) {
                        move.chase(self, p, tpos.x, tpos.y, dist);
                        return .running;
                    }
                    if (comptime @hasDecl(Self, "startEnter")) {
                        self.startEnter(p.id, r.vehicle);
                    } else move.aimAt(p, tpos.x, tpos.y, 0, false);
                    return .running;
                }
            }
            const tp = w.get(target, c.Pedestrian).?;
            if (fx.abs(tpos.z - p.t.z) > A.same_height or tp.state != c.Pedestrian.state_up or dist > A.punch_reach) {
                p.o.wait = 0;
                move.chase(self, p, tpos.x, tpos.y, dist);
                return .running;
            }
            // In reach: swing. The fist lands on one frame of the swing.
            move.aimAt(p, tpos.x, tpos.y, 0, false);
            p.ped.anim = c.Pedestrian.anim_punch;
            const per = anim.ticks_per_frame.punch;
            const swing: u16 = A.punch_frames * per;
            const hit_tick: u16 = A.punch_hit_frame * per;
            const now = p.o.wait;
            p.o.wait = if (now + 1 >= swing) 0 else now + 1;
            if (now != hit_tick) return .running;
            p.o.punched = target;
            const occ: ids.Occupation = @enumFromInt(p.o.occupation);
            const target_slot = threat.playerSlot(self, target);
            if (occ == .mugger) {
                if (target_slot) |s| Self.career.addScore(self, s, -A.mug_score, .flat);
                p.o.mugs +|= 1;
                if (p.o.mugs > A.mug_retire) p.o.occupation = @backingInt(ids.Occupation.civilian);
                p.o.think = A.mug_rest;
                return .passed;
            }
            if (threat.occupationOf(self, target) == .criminal) return .running;
            const th = w.get(target, c.Health).?;
            if (th.hp < A.punch_knockdown_hp) {
                if (law and target_slot != null) {
                    if (comptime Self.single_player) Self.career.bust(self, target_slot.?, p.id) else self.killPed(target, p.id);
                    return .passed;
                }
                self.knock(target, c.Pedestrian.state_down, fx.cos(p.t.heading), fx.sin(p.t.heading), 0, 0, p.id);
                return if (assigned) .running else .passed;
            }
            self.hurt(target, A.punch_damage, p.id);
            return .running;
        }
    };
}
