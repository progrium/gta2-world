//! Broadphase and body contacts: car-car, car-ped, ped-ped (car-collision.md).
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
        const Entry = Self.Entry;
        const nil = Self.nil;
        const cell_shift = Self.cell_shift;
        const cells_x = Self.cells_x;
        const cells_y = Self.cells_y;

        pub fn cellOf(x: Fx, y: Fx) u32 {
            const cx: u32 = @intCast(std.math.clamp(x >> cell_shift, 0, cells_x - 1));
            const cy: u32 = @intCast(std.math.clamp(y >> cell_shift, 0, cells_y - 1));
            return cy * cells_x + cx;
        }

        pub fn addEntry(self: *Self, id: EntityId, t: *const c.Transform, r: Fx, mass: i32) void {
            const sc = &self.scratch;
            const cell = cellOf(t.x, t.y);
            if (sc.cell_stamp[cell] != sc.stamp) {
                sc.cell_stamp[cell] = sc.stamp;
                sc.cell_head[cell] = nil;
            }
            sc.entries[sc.n] = .{ .id = id, .x = t.x, .y = t.y, .z = t.z, .r = r, .mass = mass, .movable = self.writable(id), .next = sc.cell_head[cell] };
            sc.cell_head[cell] = sc.n;
            sc.n += 1;
        }

        /// Uniform grid of 2x2-block cells, rebuilt every tick from state, so
        /// it never needs saving. In predict mode it holds every body: the
        /// unpredicted ones are fixed obstacles.
        pub fn buildBroadphase(self: *Self) void {
            const sc = &self.scratch;
            sc.n = 0;
            sc.stamp +%= 1;
            if (sc.stamp == 0) {
                @memset(&sc.cell_stamp, 0);
                sc.stamp = 1;
            }
            self.state.world.each(.{ c.Vehicle, c.Transform, c.Collider }, self, struct {
                fn f(sim: *Self, id: EntityId, v: *c.Vehicle, t: *c.Transform, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    const m = T.carModel(v.model);
                    sim.addEntry(id, t, m.radius, m.mass);
                }
            }.f);
            self.state.world.each(.{ c.Pedestrian, c.Transform, c.Collider }, self, struct {
                fn f(sim: *Self, id: EntityId, _: *c.Pedestrian, t: *c.Transform, col: *c.Collider) void {
                    if (col.flags & c.Collider.flag_disabled != 0) return;
                    sim.addEntry(id, t, T.ped_radius, T.ped_mass);
                }
            }.f);
        }

        pub fn sysContacts(self: *Self) void {
            const sc = &self.scratch;
            var i: u32 = 0;
            while (i < sc.n) : (i += 1) {
                const a = sc.entries[i];
                const ccx: i32 = std.math.clamp(a.x >> cell_shift, 0, cells_x - 1);
                const ccy: i32 = std.math.clamp(a.y >> cell_shift, 0, cells_y - 1);
                var dy: i32 = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) {
                        const nx = ccx + dx;
                        const ny = ccy + dy;
                        if (nx < 0 or ny < 0 or nx >= cells_x or ny >= cells_y) continue;
                        const cell: u32 = @intCast(ny * cells_x + nx);
                        if (sc.cell_stamp[cell] != sc.stamp) continue;
                        var j = sc.cell_head[cell];
                        while (j != nil) : (j = sc.entries[j].next) {
                            if (j <= i) continue; // each pair once, in entry order
                            self.resolvePair(&sc.entries[i], &sc.entries[j]);
                        }
                    }
                }
            }
        }

        /// A car's ground rectangle as corners, relative to its centre.
        pub fn carCorners(t: *const c.Transform, m: *const T.CarModel) [4][2]Fx {
            const cs = fx.cos(t.heading);
            const sn = fx.sin(t.heading);
            const k = [_][2]Fx{ .{ m.half_len, m.half_wid }, .{ m.half_len, -m.half_wid }, .{ -m.half_len, -m.half_wid }, .{ -m.half_len, m.half_wid } };
            var out: [4][2]Fx = undefined;
            for (k, &out) |p, *o| o.* = .{ fx.mul(p[0], cs) - fx.mul(p[1], sn), fx.mul(p[0], sn) + fx.mul(p[1], cs) };
            return out;
        }

        /// Is world point (px, py) inside the car rectangle at `t`?
        pub fn inRect(t: *const c.Transform, m: *const T.CarModel, px: Fx, py: Fx) bool {
            const dx = px - t.x;
            const dy = py - t.y;
            const cs = fx.cos(t.heading);
            const sn = fx.sin(t.heading);
            const u = fx.mul(dx, cs) + fx.mul(dy, sn);
            const v = fx.mul(dy, cs) - fx.mul(dx, sn);
            return fx.abs(u) < m.half_len and fx.abs(v) < m.half_wid;
        }

        /// Separating axes for two car rectangles: null if apart, else the
        /// smallest overlap and its axis (unit, pointing from a to b).
        pub fn rectOverlap(ta: *const c.Transform, ma: *const T.CarModel, tb: *const c.Transform, mb: *const T.CarModel) ?struct { depth: Fx, nx: Fx, ny: Fx } {
            const axes = [_][2]Fx{ .{ fx.cos(ta.heading), fx.sin(ta.heading) }, .{ -fx.sin(ta.heading), fx.cos(ta.heading) }, .{ fx.cos(tb.heading), fx.sin(tb.heading) }, .{ -fx.sin(tb.heading), fx.cos(tb.heading) } };
            const ca = carCorners(ta, ma);
            const cb = carCorners(tb, mb);
            var best: Fx = std.math.maxInt(Fx);
            var bn: [2]Fx = .{ fx.one, 0 };
            const dx = tb.x - ta.x;
            const dy = tb.y - ta.y;
            for (axes) |ax| {
                var ra: Fx = 0;
                var rb: Fx = 0;
                for (ca) |p| ra = @max(ra, fx.mul(p[0], ax[0]) + fx.mul(p[1], ax[1]));
                for (cb) |p| rb = @max(rb, fx.mul(p[0], ax[0]) + fx.mul(p[1], ax[1]));
                const d = fx.mul(dx, ax[0]) + fx.mul(dy, ax[1]);
                const overlap = ra + rb - fx.abs(d);
                if (overlap <= 0) return null;
                if (overlap < best) {
                    best = overlap;
                    bn = if (d >= 0) ax else .{ -ax[0], -ax[1] };
                }
            }
            return .{ .depth = best, .nx = bn[0], .ny = bn[1] };
        }

        /// Car against car (car-collision.md 3.3, 3.6): their rectangles
        /// overlap; the contact point is a corner of one inside the other.
        /// They are pushed apart along the shallowest axis, then take the
        /// rigid-body impulse with restitution 0.5 along the line from the
        /// contact point to car a's centre, so off-centre hits spin both.
        pub fn carCar(self: *Self, a: *Entry, b: *Entry) void {
            const w = &self.state.world;
            const ta = w.get(a.id, c.Transform).?;
            const tb = w.get(b.id, c.Transform).?;
            if (fx.abs(ta.z - tb.z) > fx.half) return;
            const rr = a.r + b.r;
            if (fx.abs(tb.x - ta.x) >= rr or fx.abs(tb.y - ta.y) >= rr) return;
            const ma = T.carModel(w.get(a.id, c.Vehicle).?.model);
            const mb = T.carModel(w.get(b.id, c.Vehicle).?.model);
            const ov = rectOverlap(ta, ma, tb, mb) orelse return;
            self.scratch.stats.contacts += 1;
            // Contact point: a corner of one inside the other, else midway.
            var px = (ta.x + tb.x) >> 1;
            var py = (ta.y + tb.y) >> 1;
            find: {
                for (carCorners(ta, ma)) |k| if (inRect(tb, mb, ta.x + k[0], ta.y + k[1])) {
                    px = ta.x + k[0];
                    py = ta.y + k[1];
                    break :find;
                };
                for (carCorners(tb, mb)) |k| if (inRect(ta, ma, tb.x + k[0], tb.y + k[1])) {
                    px = tb.x + k[0];
                    py = tb.y + k[1];
                    break :find;
                };
            }
            // Separate along the shallowest axis, by mass.
            const mass_a: i64 = if (a.movable) a.mass else 1 << 40;
            const mass_b: i64 = if (b.movable) b.mass else 1 << 40;
            const total = mass_a + mass_b;
            const push_a: Fx = @intCast(@divTrunc(@as(i64, ov.depth) * mass_b, total));
            const push_b = ov.depth - push_a;
            if (a.movable) {
                const x = ta.x - fx.mul(ov.nx, push_a);
                const y = ta.y - fx.mul(ov.ny, push_a);
                if (!self.boxBlocked(x, y, ta.z, ta.heading, ma)) {
                    ta.x = x;
                    ta.y = y;
                }
            }
            if (b.movable) {
                const x = tb.x + fx.mul(ov.nx, push_b);
                const y = tb.y + fx.mul(ov.ny, push_b);
                if (!self.boxBlocked(x, y, tb.z, tb.heading, mb)) {
                    tb.x = x;
                    tb.y = y;
                }
            }
            a.x = ta.x;
            a.y = ta.y;
            b.x = tb.x;
            b.y = tb.y;
            // n: from the contact point toward a's centre.
            var nx = ta.x - px;
            var ny = ta.y - py;
            const nl = fx.length(nx, ny);
            if (nl == 0) return;
            nx = fx.div(nx, nl);
            ny = fx.div(ny, nl);
            const va = w.get(a.id, c.Velocity).?;
            const vb = w.get(b.id, c.Velocity).?;
            const rax = px - ta.x;
            const ray = py - ta.y;
            const rbx = px - tb.x;
            const rby = py - tb.y;
            // Contact point velocities, rotation included.
            const vax = va.vx - fx.mul(va.spin, ray);
            const vay = va.vy + fx.mul(va.spin, rax);
            const vbx = vb.vx - fx.mul(vb.spin, rby);
            const vby = vb.vy + fx.mul(vb.spin, rbx);
            const vn = fx.mul(vax - vbx, nx) + fx.mul(vay - vby, ny);
            if (vn >= 0) return; // separating
            const ran = fx.mul(rax, ny) - fx.mul(ray, nx);
            const rbn = fx.mul(rbx, ny) - fx.mul(rby, nx);
            var denom: Fx = 0;
            if (a.movable) denom += fx.div(fx.one, ma.mass) + fx.div(fx.mul(ran, ran), ma.inertia);
            if (b.movable) denom += fx.div(fx.one, mb.mass) + fx.div(fx.mul(rbn, rbn), mb.inertia);
            if (denom <= 0) return;
            const e8: i64 = 8 + T.car_restitution_8ths;
            const j: Fx = @intCast(@divTrunc(@as(i64, -fx.div(vn, denom)) * e8, 8));
            const jx = fx.mul(j, nx);
            const jy = fx.mul(j, ny);
            if (a.movable) applyImpulse(va, ma, rax, ray, jx, jy);
            if (b.movable) applyImpulse(vb, mb, rbx, rby, -jx, -jy);
            if (j > T.impact_min_speed) {
                self.scratch.stats.impacts += 1;
                self.damageCar(a.id, @as(i64, j) * T.impact_damage, b.id);
                self.damageCar(b.id, @as(i64, j) * T.impact_damage, a.id);
            }
        }

        /// Impulse (jx, jy) at offset (rx, ry) from a car's centre
        /// (car-collision.md 3.4): velocity by impulse / mass, spin by the
        /// torque over the moment of inertia; an impulse under 0.01 per unit
        /// of mass leaves the car alone.
        pub fn applyImpulse(vel: *c.Velocity, m: *const T.CarModel, rx: Fx, ry: Fx, jx: Fx, jy: Fx) void {
            const dvx = fx.div(jx, m.mass);
            const dvy = fx.div(jy, m.mass);
            if (fx.length(dvx, dvy) <= T.impulse_min) return;
            vel.vx += dvx;
            vel.vy += dvy;
            vel.spin += fx.div(fx.mul(rx, jy) - fx.mul(ry, jx), m.inertia);
        }

        pub fn resolvePair(self: *Self, a: *Entry, b: *Entry) void {
            if (!a.movable and !b.movable) return;
            const a_car = a.id.kind() == @backingInt(abi.Kind.car);
            const b_car = b.id.kind() == @backingInt(abi.Kind.car);
            if (a_car and !b_car) return self.carPed(a, b);
            if (b_car and !a_car) return self.carPed(b, a);
            if (a_car and b_car) return self.carCar(a, b);
            const w = &self.state.world;
            const ta = w.get(a.id, c.Transform).?;
            const tb = w.get(b.id, c.Transform).?;
            if (fx.abs(ta.z - tb.z) > fx.half) return;
            const ddx = tb.x - ta.x;
            const ddy = tb.y - ta.y;
            const rr = a.r + b.r;
            if (fx.abs(ddx) >= rr or fx.abs(ddy) >= rr) return;
            const d = fx.length(ddx, ddy);
            if (d >= rr) return;
            self.scratch.stats.contacts += 1;
            const va = w.get(a.id, c.Velocity).?;
            const vb = w.get(b.id, c.Velocity).?;
            // Normal (unit) from a to b; coincident bodies push along +x.
            const nx = if (d == 0) fx.one else fx.div(ddx, d);
            const ny = if (d == 0) 0 else fx.div(ddy, d);
            const pen = rr - d;
            // An immovable side acts as infinitely heavy.
            const ma: i64 = if (a.movable) a.mass else 1 << 40;
            const mb: i64 = if (b.movable) b.mass else 1 << 40;
            const total = ma + mb;
            const push_a: Fx = @intCast(@divTrunc(@as(i64, pen) * mb, total));
            const push_b = pen - push_a;
            // Do not push a body into a wall.
            const ma_step: Fx = if (a_car) T.car_step else T.ped_step;
            const mb_step: Fx = if (b_car) T.car_step else T.ped_step;
            if (a.movable) {
                const x = ta.x - fx.mul(nx, push_a);
                const y = ta.y - fx.mul(ny, push_a);
                if (!self.circleBlocked(x, y, ta.z, fx.ratio(1, 8), ma_step)) {
                    ta.x = x;
                    ta.y = y;
                }
            }
            if (b.movable) {
                const x = tb.x + fx.mul(nx, push_b);
                const y = tb.y + fx.mul(ny, push_b);
                if (!self.circleBlocked(x, y, tb.z, fx.ratio(1, 8), mb_step)) {
                    tb.x = x;
                    tb.y = y;
                }
            }
            // Exchange normal momentum: car against car bounces with
            // restitution 0.5 (car-collision.md); peds just stop.
            const rel = fx.mul(vb.vx - va.vx, nx) + fx.mul(vb.vy - va.vy, ny);
            if (rel < 0) {
                const e8: i64 = if (a_car) 8 + T.car_restitution_8ths else 8;
                const imp_a: Fx = @intCast(@divTrunc(@as(i64, rel) * mb * e8, total * 8));
                const imp_b: Fx = @intCast(@divTrunc(@as(i64, rel) * ma * e8, total * 8));
                if (a.movable) {
                    va.vx += fx.mul(nx, imp_a);
                    va.vy += fx.mul(ny, imp_a);
                }
                if (b.movable) {
                    vb.vx -= fx.mul(nx, imp_b);
                    vb.vy -= fx.mul(ny, imp_b);
                }
                // Damage from the impulse, both cars alike, credited to the
                // other car (its driver).
                if (a_car and -rel > T.impact_min_speed) {
                    self.scratch.stats.impacts += 1;
                    const m_eff: i64 = @intCast(@divTrunc(@as(i128, ma) * mb, total));
                    const j: i64 = @divTrunc(-@as(i64, rel) * m_eff * e8, 8 << fx.frac_bits);
                    self.damageCar(a.id, j * T.impact_damage, b.id);
                    self.damageCar(b.id, j * T.impact_damage, a.id);
                }
            }
            a.x = ta.x;
            a.y = ta.y;
            b.x = tb.x;
            b.y = tb.y;
        }

        /// A car touching a ped (car-collision.md 3.6): the ped is pushed
        /// clear and, if the car was moving into him, handed a knock-back
        /// of 2 x the car's closing speed x mc / (mc + 0.5) (restitution 1,
        /// ped mass 0.5). The car takes nothing.
        pub fn carPed(self: *Self, car: *Entry, ped: *Entry) void {
            if (!ped.movable) return;
            const w = &self.state.world;
            const tc = w.get(car.id, c.Transform).?;
            const tp = w.get(ped.id, c.Transform).?;
            if (fx.abs(tc.z - tp.z) > fx.half) return;
            const ddx = tp.x - tc.x;
            const ddy = tp.y - tc.y;
            const rr = car.r + ped.r;
            if (fx.abs(ddx) >= rr or fx.abs(ddy) >= rr) return;
            const d = fx.length(ddx, ddy);
            if (d >= rr) return;
            self.scratch.stats.contacts += 1;
            const nx = if (d == 0) fx.one else fx.div(ddx, d);
            const ny = if (d == 0) 0 else fx.div(ddy, d);
            const x = tp.x + fx.mul(nx, rr - d);
            const y = tp.y + fx.mul(ny, rr - d);
            if (!self.circleBlocked(x, y, tp.z, fx.ratio(1, 8), T.ped_step)) {
                tp.x = x;
                tp.y = y;
            }
            ped.x = tp.x;
            ped.y = tp.y;
            const vc = w.get(car.id, c.Velocity).?;
            const closing = fx.mul(vc.vx, nx) + fx.mul(vc.vy, ny);
            if (closing <= T.car_hit_min) return;
            const mc: i64 = car.mass;
            var k: Fx = @intCast(@divTrunc(2 * @as(i64, closing) * mc, mc + T.ped_mass));
            k = @max(k, fx.ratio(1, 16));
            self.carHitPed(car.id, ped.id, nx, ny, k);
        }

        /// What a car hit does to a ped (ped-movement.md 3.8), for a
        /// knock-back of length `k` along (nx, ny).
        pub fn carHitPed(self: *Self, car: EntityId, ped: EntityId, nx: Fx, ny: Fx, k: Fx) void {
            const w = &self.state.world;
            const pd = w.get(ped, c.Pedestrian) orelse return;
            if (!w.get(ped, c.Riding).?.vehicle.isNone()) return;
            const v = w.get(car, c.Vehicle).?;
            if (v.flags & c.Vehicle.flag_ai != 0 and self.writable(car)) v.halt = T.traffic_hit_stop;
            const player = w.get(ped, c.Controller).?.player != c.Controller.no_player;
            const lying = pd.state != c.Pedestrian.state_up and pd.state != c.Pedestrian.state_falling;
            var player_driving = false;
            if (w.get(v.driver, c.Controller)) |dc| player_driving = dc.player != c.Controller.no_player;
            const S = c.Pedestrian;
            if (k < T.knock_light) {
                if (lying) self.killPed(ped, car) else self.knock(ped, S.state_over, nx, ny, k, 0, car);
            } else if (!player or k >= T.knock_hard) {
                self.killPed(ped, car);
            } else if (k < T.knock_mid) {
                self.knock(ped, if (player_driving) S.state_fatal else S.state_down, nx, ny, k >> 1, T.knock_lift_light, car);
            } else if (!player_driving and !lying) {
                self.knock(ped, S.state_down, nx, ny, k >> 1, T.knock_lift_mid, car);
            } else {
                self.killPed(ped, car);
            }
        }
    };
}
