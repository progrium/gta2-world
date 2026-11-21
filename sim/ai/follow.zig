//! Following (ped-ai.md 3.10): a ped on foot following another ped, and
//! a driver following in a car through F's car tasks. Group formation and
//! the tight-follow check (3.11) are D2's and call these through the
//! objectives API. Owner: workstream D1.

const std = @import("std");
const prelude = @import("../prelude.zig");
const fx = prelude.fx;
const c = prelude.c;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const eql = prelude.eql;
const A = @import("../tuning/ped_ai.zig");
const O = c.Objective;
const P = @import("move.zig").P;

pub fn Sys(comptime Self: type) type {
    return struct {
        const move = @import("move.zig").Sys(Self);
        const threat = @import("threat.zig").Sys(Self);
        pub const Progress = threat.Progress;

        /// Follow `target`. `.passed` means close enough this tick; the
        /// caller keeps the objective so the ped follows again once the
        /// target moves off.
        pub fn follow(self: *Self, p: P, target: EntityId) Progress {
            if (!threat.eligible(self, target)) return .failed;
            const w = &self.state.world;
            const tpos = threat.posOf(self, target) orelse return .failed;
            // Driving: follow in the car (traffic-and-car-ai.md car task).
            if (!p.ride.vehicle.isNone()) {
                const v = w.get(p.ride.vehicle, c.Vehicle) orelse return .failed;
                if (!eql(v.driver, p.id)) return .running;
                const tr = w.get(target, c.Riding);
                const tgt = if (tr != null and !tr.?.vehicle.isNone()) tr.?.vehicle else target;
                if (Self.car_tasks.carTaskOf(self, p.ride.vehicle) != .follow) {
                    Self.car_tasks.setCarTask(self, p.ride.vehicle, .follow, tgt, tpos.x, tpos.y);
                }
                return .running;
            }
            const dist = fx.length(tpos.x - p.t.x, tpos.y - p.t.y);
            const tp = w.get(target, c.Pedestrian);
            const jumping = tp != null and tp.?.jump > 0;
            if (dist <= A.follow_stop + 2 * prelude.T.ped_radius and fx.abs(tpos.z - p.t.z) <= A.same_height) {
                // Deferred while the target is mid-jump; the wait counter
                // builds and resets after 200 ticks or on panic.
                if (jumping) {
                    p.o.wait += 1;
                    if (p.o.wait >= A.follow_wait_reset or p.o.flags & O.flag_panic != 0) p.o.wait = 0;
                    move.halt(p);
                    return .running;
                }
                p.o.wait = 0;
                move.halt(p);
                return .passed;
            }
            const run = dist > A.follow_walk;
            move.goToward(self, p, tpos.x, tpos.y, 127, run);
            return .running;
        }
    };
}
