//! A minimal sim that satisfies I1, for workstreams that need something to
//! link against before `sim/` lands. One ped per player slot, moved by tank
//! controls; no collisions. Not a reference for gameplay.

const std = @import("std");
const abi = @import("abi.zig");
const input = @import("input.zig");

const cap = 16;

pub const Stub = struct {
    const Self = @This();
    pub const config: abi.Config = .{ .name = "stub", .max_players = cap, .car_capacity = 0, .ped_capacity = cap, .projectile_capacity = 0 };

    pub const PedTable = extern struct {
        len: u32,
        _pad: u32 = 0,
        gen: [cap]u16,
        slot: [cap]u8,
        transform: [cap]abi.Transform,
        velocity: [cap]abi.Velocity,
        controller: [cap]abi.Controller,
        predicted: [cap]abi.Predicted,
    };

    pub const State = extern struct {
        tick: u32,
        mode: u32,
        seed: u64,
        players: [cap]abi.PlayerRow,
        ped: PedTable,
    };

    pub const state_size = @sizeOf(State);
    pub const layout_hash = abi.layoutHash(State);

    state: State,
    intent_buf: [4]abi.Intent = undefined,
    intent_len: usize = 0,
    grid: *const abi.Grid = undefined,

    pub fn init(self: *Self, grid: *const abi.Grid, p: abi.InitParams) void {
        self.state = std.mem.zeroes(State);
        self.state.seed = p.seed;
        self.state.mode = @intFromEnum(p.mode);
        self.state.ped.len = cap;
        for (&self.state.players) |*r| r.* = .{ .ped = .none, .car = .none, .kills = 0, .deaths = 0, .score = 0, .respawn_timer = 0, .flags = 0 };
        self.grid = grid;
        self.intent_len = 0;
    }

    pub fn step(self: *Self, frames: []const input.Frame, cmds: []const abi.Command) void {
        self.intent_len = 0;
        const s = &self.state;
        const predict = s.mode == @intFromEnum(abi.Mode.predict);
        for (cmds) |c| {
            if (c.slot >= cap) continue;
            const row = &s.players[c.slot];
            switch (c.op) {
                .join => {
                    row.flags = abi.PlayerRow.flag_active | abi.PlayerRow.flag_connected;
                    row.ped = abi.EntityId.make(.ped, c.slot, s.ped.gen[c.slot]);
                    s.ped.slot[c.slot] = abi.Slot.alive;
                    s.ped.transform[c.slot] = .{ .x = abi.fx_one * 128, .y = abi.fx_one * 128, .z = abi.fx_one, .heading = 0 };
                    s.ped.controller[c.slot] = .{ .player = c.slot, .prev_buttons = 0, .in = input.Frame.neutral(0) };
                },
                .leave => {
                    row.flags = 0;
                    row.ped = .none;
                    s.ped.slot[c.slot] = abi.Slot.free;
                    s.ped.gen[c.slot] +%= 1;
                },
                else => {},
            }
        }
        var i: usize = 0;
        while (i < cap) : (i += 1) {
            if (s.ped.slot[i] != abi.Slot.alive) continue;
            if (predict and s.ped.predicted[i].on == 0) continue;
            const ctl = &s.ped.controller[i];
            if (ctl.player != abi.Controller.no_player and ctl.player < frames.len) {
                ctl.prev_buttons = ctl.in.buttons;
                ctl.in = frames[ctl.player].sanitize();
            }
            const t = &s.ped.transform[i];
            t.heading +%= @bitCast(@as(i16, ctl.in.steer) * 64);
            // Crude: move along the dominant axis of the heading.
            const sp: i32 = @as(i32, ctl.in.throttle) * 64;
            const q = t.heading >> 14;
            const v = &s.ped.velocity[i];
            v.* = .{ .vx = if (q == 0) sp else if (q == 2) -sp else 0, .vy = if (q == 1) sp else if (q == 3) -sp else 0, .vz = 0, .spin = 0 };
            t.x +%= v.vx;
            t.y +%= v.vy;
        }
        s.tick +%= 1;
    }

    pub fn save(self: *const Self, buf: []u8) usize {
        @memcpy(buf[0..state_size], std.mem.asBytes(&self.state));
        return state_size;
    }

    pub fn load(self: *Self, buf: []const u8) error{BadSize}!void {
        if (buf.len != state_size) return error.BadSize;
        @memcpy(std.mem.asBytes(&self.state), buf);
    }

    pub fn hash(self: *const Self) u64 {
        return abi.stateHash(std.mem.asBytes(&self.state));
    }

    pub fn tick(self: *const Self) abi.Tick {
        return self.state.tick;
    }

    pub fn setTick(self: *Self, t: abi.Tick) void {
        self.state.tick = t;
    }

    pub fn stateBytes(self: *const Self) []const u8 {
        return std.mem.asBytes(&self.state);
    }

    const view_table = blk: {
        const base = @offsetOf(State, "ped");
        const k: u8 = @intFromEnum(abi.Kind.ped);
        break :blk [_]abi.ColumnDesc{
            .{ .kind = 0, .component = abi.ColumnDesc.Special.tick, .offset = @offsetOf(State, "tick"), .stride = 4, .count = 1 },
            .{ .kind = @intFromEnum(abi.Kind.player_row), .component = abi.ColumnDesc.Special.player_rows, .offset = @offsetOf(State, "players"), .stride = @sizeOf(abi.PlayerRow), .count = cap },
            .{ .kind = k, .component = abi.ColumnDesc.Special.len, .offset = base + @offsetOf(PedTable, "len"), .stride = 4, .count = 1 },
            .{ .kind = k, .component = abi.ColumnDesc.Special.generation, .offset = base + @offsetOf(PedTable, "gen"), .stride = 2, .count = cap },
            .{ .kind = k, .component = abi.ColumnDesc.Special.slot, .offset = base + @offsetOf(PedTable, "slot"), .stride = 1, .count = cap },
            .{ .kind = k, .component = @intFromEnum(abi.ComponentId.transform), .offset = base + @offsetOf(PedTable, "transform"), .stride = @sizeOf(abi.Transform), .count = cap },
            .{ .kind = k, .component = @intFromEnum(abi.ComponentId.velocity), .offset = base + @offsetOf(PedTable, "velocity"), .stride = @sizeOf(abi.Velocity), .count = cap },
            .{ .kind = k, .component = @intFromEnum(abi.ComponentId.controller), .offset = base + @offsetOf(PedTable, "controller"), .stride = @sizeOf(abi.Controller), .count = cap },
            .{ .kind = k, .component = @intFromEnum(abi.ComponentId.predicted), .offset = base + @offsetOf(PedTable, "predicted"), .stride = @sizeOf(abi.Predicted), .count = cap },
        };
    };

    pub fn views() []const abi.ColumnDesc {
        return &view_table;
    }

    pub fn intents(self: *const Self) []const abi.Intent {
        return self.intent_buf[0..self.intent_len];
    }

    pub fn playerRow(self: *Self, slot: u32) *abi.PlayerRow {
        return &self.state.players[slot];
    }

    pub fn replicaPut(self: *Self, id: abi.EntityId) bool {
        if (id.kind() != @intFromEnum(abi.Kind.ped) or id.index() >= cap) return false;
        const i = id.index();
        if (self.state.ped.gen[i] != id.gen() or self.state.ped.slot[i] != abi.Slot.alive) {
            self.state.ped.gen[i] = id.gen();
            self.state.ped.slot[i] = abi.Slot.alive;
            self.state.ped.transform[i] = std.mem.zeroes(abi.Transform);
            self.state.ped.velocity[i] = std.mem.zeroes(abi.Velocity);
            self.state.ped.controller[i] = std.mem.zeroes(abi.Controller);
            self.state.ped.predicted[i] = .{ .on = 0 };
        }
        return true;
    }

    pub fn replicaRemove(self: *Self, id: abi.EntityId) void {
        if (id.kind() != @intFromEnum(abi.Kind.ped) or id.index() >= cap) return;
        const i = id.index();
        if (self.state.ped.gen[i] != id.gen()) return;
        self.state.ped.slot[i] = abi.Slot.free;
    }
};

test "stub steps and round-trips state" {
    var grid: abi.Grid = undefined;
    var s: Stub = undefined;
    s.init(&grid, .{ .seed = 1, .mode = .authoritative });
    const join = [_]abi.Command{.{ .op = .join, .slot = 0, .arg = 0 }};
    var frames: [cap]input.Frame = @splat(input.Frame.neutral(0));
    s.step(&frames, &join);
    frames[0].throttle = 127;
    var buf: [Stub.state_size]u8 = undefined;
    _ = s.save(&buf);
    const h0 = s.hash();
    s.step(&frames, &.{});
    const h1 = s.hash();
    try s.load(&buf);
    try std.testing.expectEqual(h0, s.hash());
    s.step(&frames, &.{});
    try std.testing.expectEqual(h1, s.hash());
    try std.testing.expect(s.state.ped.transform[0].x > abi.fx_one * 128);
}
