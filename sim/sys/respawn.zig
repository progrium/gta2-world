//! Respawning dead players.
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
        pub fn sysRespawn(self: *Self) void {
            if (self.predicting()) return;
            for (&self.state.players, 0..) |*pl, i| {
                if (pl.flags & abi.PlayerRow.flag_active == 0 or !pl.ped.isNone()) continue;
                if (pl.respawn_timer > 0) {
                    pl.respawn_timer -= 1;
                    continue;
                }
                self.spawnPlayer(@intCast(i), 0);
            }
        }
    };
}
