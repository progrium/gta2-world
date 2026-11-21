//! Commands (join, leave) and per-player input frames.
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
const sp_world = @import("../script/world.zig");

pub fn Sys(comptime Self: type) type {
    return struct {
        const cfg = Self.config;
        const cycleWeapon = Self.cycleWeapon;
        const emptyRow = Self.emptyRow;

        pub fn applyCommand(self: *Self, cmd: abi.Command) void {
            if (cmd.slot >= cfg.max_players) return;
            const row = &self.state.players[cmd.slot];
            switch (cmd.op) {
                .join => {
                    if (row.flags & abi.PlayerRow.flag_active != 0) return;
                    row.* = emptyRow();
                    row.flags = abi.PlayerRow.flag_active | abi.PlayerRow.flag_connected;
                    self.spawnPlayer(cmd.slot, cmd.arg);
                },
                .leave => {
                    if (row.flags & abi.PlayerRow.flag_active == 0) return;
                    const w = &self.state.world;
                    if (w.get(row.ped, c.Riding)) |r| {
                        if (!r.vehicle.isNone()) self.releaseCar(r.vehicle);
                    }
                    if (!row.ped.isNone()) w.despawn(row.ped);
                    row.* = emptyRow();
                },
                else => {},
            }
        }

        pub fn sysInput(self: *Self, frames: []const Frame) void {
            const Ctx = struct { sim: *Self, frames: []const Frame };
            self.state.world.eachFiltered(.{ c.Controller, c.Riding, c.Transform }, self.predicting(), Ctx{ .sim = self, .frames = frames }, struct {
                fn f(ctx: Ctx, id: EntityId, ctl: *c.Controller, ride: *c.Riding, t: *c.Transform) void {
                    _ = t;
                    if (ctl.player == c.Controller.no_player) return;
                    const sim = ctx.sim;
                    var in = if (ctl.player < ctx.frames.len) ctx.frames[ctl.player].sanitize() else Frame.neutral(0);
                    // Script control locks (script-player 2.4, A2).
                    if (comptime Self.single_player) {
                        const locks = ctx.sim.state.sp.world.flags;
                        if (locks & sp_world.State.flag_no_controls != 0) in = Frame.neutral(in.seq);
                        if (locks & sp_world.State.flag_no_enter != 0 and ride.vehicle.isNone()) in.buttons &= ~Button.enter_exit;
                    } else _ = &in;
                    const pressed = in.buttons & ~@as(u16, @truncate(ctl.prev_buttons));
                    ctl.prev_buttons = in.buttons;
                    ctl.in = in;
                    const w = &sim.state.world;
                    const ped = w.get(id, c.Pedestrian);
                    const up = if (ped) |p| p.state == c.Pedestrian.state_up else true;
                    if (pressed & Button.enter_exit != 0) {
                        if (!ride.vehicle.isNone()) sim.tryExit(id) else if (up) sim.tryEnter(id);
                    }
                    if (ride.vehicle.isNone() and pressed & Button.handbrake_jump != 0) {
                        if (ped) |p| p.flags |= c.Pedestrian.flag_jump_pressed;
                    }
                    if (pressed & (Button.weapon_next | Button.weapon_prev) != 0) {
                        if (w.get(id, c.Weapon)) |wpn| cycleWeapon(wpn, pressed & Button.weapon_next != 0);
                    }
                    if (!ride.vehicle.isNone()) {
                        if (w.get(ride.vehicle, c.Controller)) |cc| {
                            if (sim.writable(ride.vehicle)) {
                                cc.prev_buttons = cc.in.buttons;
                                cc.in = in;
                            }
                        }
                    }
                }
            }.f);
        }
    };
}
