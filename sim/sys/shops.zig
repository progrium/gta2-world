//! Car shops: the spray shop. A level script declares each shop as an
//! object of model `car_shop_model` (`CAR_SHOP` in the public scripting
//! docs); the declaration's value byte is a paint remap for a spray shop,
//! or one of the weapon shop codes from `first_weapon_shop` up (not built
//! yet). Driving a player's car into a spray shop's block repaints it and,
//! in the living city, clears the wanted level for a price.
//!
//! No behaviour note covers shops yet: the trigger box, the price and
//! "repaint every visit, charge only to clear the stars" are ours
//! (`tuning/objects.zig`). Shops come from the level's script, so they
//! work in every configuration whose host attaches the level; the repaint
//! and the wanted clear are authoritative only (a predicting client gets
//! them in the next snapshot).

const std = @import("std");
const prelude = @import("../prelude.zig");
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const OT = @import("../tuning/objects.zig");
const W = @import("../script/world.zig");
const lv = @import("interfaces").level;

/// A shop the level's script declares (static, outside the saved state).
pub const Shop = struct {
    /// The shop's block.
    bx: i32,
    by: i32,
    /// Its floor height.
    z: Fx,
    /// The declaration's value: a remap below `OT.first_weapon_shop`.
    value: u8,

    pub fn isSpray(s: Shop) bool {
        return s.value < OT.first_weapon_shop;
    }
};

pub const max_shops = 64;

/// The declaration commands that place an object (script-declarations.md
/// 2.4): 15 and 16 plain, 17-20 with a value.
fn isObjectDecl(kind: u16) bool {
    return kind >= 15 and kind <= 20;
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;

        /// Read the shops out of the level's main script into `self.shop_list`
        /// (called by `attachLevel`). Mission-created shops are not seen.
        pub fn collect(self: *Self, l: *const lv.Level) void {
            self.shop_count = 0;
            if (l.script.pointers.len == 0) return;
            var num: u16 = 1;
            while (num < 6000) : (num += 1) {
                if (self.shop_count >= max_shops) return;
                const f = Self.script.findIn(&l.script, num) orelse continue;
                if (!isObjectDecl(f.kind)) continue;
                const p = W.P{ .b = f.params };
                if (p.u16_(16) != OT.car_shop_model) continue;
                const pos = p.pos(4);
                const from = if (pos.ground) fx.fromInt(map.size_z - 1) else pos.z;
                const floor = map.floorAt(self.grid, pos.x, pos.y, from, T.ped_step);
                // Only the valued forms carry the value (as the declaration
                // pass applies it, cmd_decl.zig).
                const value: u8 = if (f.kind >= 17 and f.params.len >= 24) @truncate(p.u32_(20)) else 0;
                self.shop_list[self.shop_count] = .{
                    .bx = fx.toInt(pos.x),
                    .by = fx.toInt(pos.y),
                    .z = if (floor < 0) (if (pos.ground) 0 else pos.z) else floor,
                    .value = value,
                };
                self.shop_count += 1;
            }
        }

        /// The spray shop whose block holds (x, y, z), if any.
        pub fn sprayAt(self: *const Self, x: Fx, y: Fx, z: Fx) ?*const Shop {
            const bx = fx.toInt(x);
            const by = fx.toInt(y);
            for (self.shop_list[0..self.shop_count]) |*s| {
                if (!s.isSpray() or s.bx != bx or s.by != by) continue;
                if (@abs(z - s.z) >= @as(u32, @intCast(OT.shop_reach_z))) continue;
                return s;
            }
            return null;
        }

        /// Once a tick: each player's car that has just driven into a
        /// spray shop is repainted with the shop's remap, and the player's
        /// wanted level is cleared if they can pay. `flag_in_shop` marks a
        /// car inside a shop, so a visit acts once.
        pub fn sysShops(self: *Self) void {
            if (self.shop_count == 0 or self.predicting()) return;
            const w = &self.state.world;
            var slot: u8 = 0;
            while (slot < cfg.max_players) : (slot += 1) {
                const car = self.state.players[slot].car;
                if (car.isNone()) continue;
                const v = w.get(car, c.Vehicle) orelse continue;
                const t = w.get(car, c.Transform) orelse continue;
                const shop = sprayAt(self, t.x, t.y, t.z) orelse {
                    v.flags &= ~c.Vehicle.flag_in_shop;
                    continue;
                };
                if (v.flags & c.Vehicle.flag_in_shop != 0) continue;
                v.flags |= c.Vehicle.flag_in_shop;
                if (v.flags & c.Vehicle.flag_wrecked != 0) continue;
                if (w.get(car, c.Appearance)) |a| a.remap = shop.value;
                const cleared = clearWanted(self, slot);
                self.pushEvent(.{
                    .kind = .respray,
                    .a = slot,
                    .b = shop.value,
                    .c = @intFromEnum(cleared),
                    .x = (fx.fromInt(shop.bx)) + fx.one / 2,
                    .y = (fx.fromInt(shop.by)) + fx.one / 2,
                    .z = shop.z,
                });
            }
        }

        pub const Cleared = enum(u8) { no_stars = 0, cleared = 1, cannot_pay = 2 };

        /// Clear `slot`'s wanted level for the shop's price: career cash in
        /// single player, points in a police room. Nothing in plain
        /// deathmatch, which has no wanted level.
        fn clearWanted(self: *Self, slot: u8) Cleared {
            if (comptime !Self.city) return .no_stars;
            if (Self.wanted.stars(self, slot) == 0) return .no_stars;
            if (comptime Self.single_player) {
                if (Self.career.score(self, slot) < OT.shop_price_sp) return .cannot_pay;
                Self.career.addScore(self, slot, -OT.shop_price_sp, .flat);
            } else {
                const row = &self.state.players[slot];
                if (row.score < OT.shop_price_mp) return .cannot_pay;
                row.score -= OT.shop_price_mp;
            }
            Self.wanted.clear(self, slot);
            return .cleared;
        }
    };
}
