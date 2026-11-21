//! Route planning over the road grid (traffic-and-car-ai.md 3.4 "junction
//! shortcut", 3.7). Owner: workstream F; E calls it for crews.
//!
//! The road graph is block-level: a node is a road cell (ground type road,
//! with headroom above it) at map level `l`, the level of the cell itself
//! (a car standing on it is at height l + 1). A move goes one block in a
//! compass direction, to the neighbour at the same level, or one up or
//! down where either end is a ramp, and never through a wall face. The
//! green lane arrows decide which moves are legal:
//!
//!   - out of a cell with no arrows (a junction drawn without them), any
//!     direction; out of an arrowed cell, only along its arrows, or
//!     sideways into a parallel lane with the same single arrow (a lane
//!     change, costing 2);
//!   - into a cell whose green arrows include the move, or one with no
//!     arrows at all (green or red).
//!
//! The one place red (against-the-flow) arrows count: a cell with red
//! arrows and no green ones is closed, except that with
//! `Opts.against_flow_south` a move heading south (+y) may enter it (3.7,
//! the chase allowance; the note leaves open why only south).
//!
//! The search is A* with the Manhattan distance, bounded to
//! `TF.route_max_nodes` expansions. If the bound is hit, or the goal can't
//! be reached, the first step toward the expanded node nearest the goal is
//! returned, so a car always makes progress. Ties break by insertion order,
//! so the result depends only on the grid and the inputs. The buffers are
//! on the stack (about 100 KB).

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const fx = prelude.fx;
const map = prelude.map;
const c = prelude.c;
const T = prelude.T;
const Fx = prelude.Fx;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const TF = @import("../tuning/traffic.zig");

pub const Opts = struct {
    /// The chase allowance (3.7): heading south, a cell with only red
    /// arrows may be entered.
    against_flow_south: bool = false,
    /// Expansion bound (0 means `TF.route_max_nodes`).
    max_nodes: u32 = 0,
};

/// A road cell: block (x, y) at map level l.
pub const Node = struct { x: i32, y: i32, l: i32 };

/// Unit steps for directions 0 +x, 1 +y, 2 -x, 3 -y (as `Vehicle.ai_dir`).
pub const step_x = [4]i32{ 1, 0, -1, 0 };
pub const step_y = [4]i32{ 0, 1, 0, -1 };
/// The green arrow bit for each direction.
pub const dir_arrow = [4]u4{ map.Arrow.pos_x, map.Arrow.pos_y, map.Arrow.neg_x, map.Arrow.neg_y };

/// Is cell (x, y, l) a drivable road cell: road ground, a floor shape, and
/// no matter in the cell above?
pub fn roadAt(g: *const abi.Grid, x: i32, y: i32, l: i32) bool {
    if (x < 0 or y < 0 or l < 0 or x >= map.size_x or y >= map.size_y or l >= map.size_z) return false;
    const cell = map.cellAt(g, x, y, l);
    if (map.groundOf(cell) != map.Ground.road) return false;
    const sh = map.shapeOf(cell);
    if (sh != map.Shape.solid and sh != map.Shape.slope and sh != map.Shape.slab) return false;
    if (sh == map.Shape.solid and map.codeOf(cell) != 0) return false; // diagonal walls
    if (l + 1 < map.size_z) {
        const above = map.shapeOf(map.cellAt(g, x, y, l + 1));
        if (above != map.Shape.air and above != map.Shape.water) return false;
    }
    return true;
}

fn isRamp(g: *const abi.Grid, x: i32, y: i32, l: i32) bool {
    if (x < 0 or y < 0 or l < 0 or x >= map.size_x or y >= map.size_y or l >= map.size_z) return false;
    return map.shapeOf(map.cellAt(g, x, y, l)) == map.Shape.slope;
}

fn greenAt(g: *const abi.Grid, n: Node) u4 {
    return map.arrowsOf(map.cellAt(g, n.x, n.y, n.l));
}

/// The neighbour of `n` one block in direction `d`, if a car may drive
/// there, and the move's cost (1, or 2 for a lane change).
pub fn move(g: *const abi.Grid, n: Node, d: u2, opts: Opts) ?struct { to: Node, cost: u16 } {
    const nx = n.x + step_x[d];
    const ny = n.y + step_y[d];
    // Same level first, then up or down a ramp.
    var to: ?Node = null;
    if (roadAt(g, nx, ny, n.l)) {
        to = .{ .x = nx, .y = ny, .l = n.l };
    } else if (roadAt(g, nx, ny, n.l + 1) and (isRamp(g, n.x, n.y, n.l) or isRamp(g, nx, ny, n.l + 1))) {
        to = .{ .x = nx, .y = ny, .l = n.l + 1 };
    } else if (roadAt(g, nx, ny, n.l - 1) and (isRamp(g, n.x, n.y, n.l) or isRamp(g, nx, ny, n.l - 1))) {
        to = .{ .x = nx, .y = ny, .l = n.l - 1 };
    }
    const t = to orelse return null;
    // Wall faces at the height of a body on the lower of the two cells.
    const wl = @min(n.l, t.l) + 1;
    const blocked = switch (d) {
        0 => map.wallX(g, n.x + 1, n.y, wl, 0),
        2 => map.wallX(g, n.x, n.y, wl, 0),
        1 => map.wallY(g, n.x, n.y + 1, wl, 0),
        3 => map.wallY(g, n.x, n.y, wl, 0),
    };
    if (blocked) return null;
    const a = greenAt(g, n);
    const b = greenAt(g, t);
    const bit = dir_arrow[d];
    // Out of n.
    // A junction cell (no arrows, or several) costs one more, so routes
    // cross junctions by the fewest cells: turns are taken at once.
    const cost: u16 = if (b == 0 or @popCount(b) > 1) 2 else 1;
    const red_only = b == 0 and map.redArrowsOf(map.surfaceAt(g, t.x, t.y, t.l)) != 0;
    if (red_only and opts.against_flow_south and d == 1) return .{ .to = t, .cost = cost };
    if (a != 0 and a & bit == 0) {
        // Only a lane change: one arrow, the same on both sides.
        const back = dir_arrow[(@as(u3, d) + 2) & 3];
        if (@popCount(a) != 1 or b != a or a & back != 0) return null;
        return .{ .to = t, .cost = cost + 1 };
    }
    // Into t. A cell with neither green nor red arrows is a junction drawn
    // without them; one with only red arrows is against the flow.
    if (b == 0) {
        const red = map.redArrowsOf(map.surfaceAt(g, t.x, t.y, t.l));
        if (red != 0 and !(opts.against_flow_south and d == 1)) return null;
    } else if (b & bit == 0) return null;
    return .{ .to = t, .cost = cost };
}

/// The nearest road cell to block (tx, ty), at level `l` or any level if
/// none there, within `radius` blocks (Chebyshev rings, scanned in a fixed
/// order).
pub fn nearestRoad(g: *const abi.Grid, tx: i32, ty: i32, l: i32, radius: i32) ?Node {
    var r: i32 = 0;
    while (r <= radius) : (r += 1) {
        // Prefer the given level, then the highest road in the column.
        var pass: u32 = 0;
        while (pass < 2) : (pass += 1) {
            var dy: i32 = -r;
            while (dy <= r) : (dy += 1) {
                var dx: i32 = -r;
                while (dx <= r) : (dx += 1) {
                    if (@max(@abs(dx), @abs(dy)) != r) continue;
                    const x = tx + dx;
                    const y = ty + dy;
                    if (pass == 0) {
                        if (roadAt(g, x, y, l)) return .{ .x = x, .y = y, .l = l };
                    } else {
                        var ll: i32 = map.size_z - 1;
                        while (ll >= 0) : (ll -= 1) if (roadAt(g, x, y, ll)) return .{ .x = x, .y = y, .l = ll };
                    }
                }
            }
        }
    }
    return null;
}

/// The level of the cell a body at height `z` stands on at (x, y), as
/// `map.floorCell` finds it (the body's feet may be up to `step` above).
pub fn levelUnder(g: *const abi.Grid, x: Fx, y: Fx, z: Fx, step: Fx) i32 {
    var l = fx.toInt(z + step);
    if (l >= map.size_z) l = map.size_z - 1;
    while (l >= 0) : (l -= 1) {
        const cell = map.cellAt(g, fx.toInt(x), fx.toInt(y), l);
        if (map.topInCell(cell, x, y)) |top| {
            if (fx.fromInt(l) + top <= z + step) return l;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// A*

const closed_cap = 8192; // power of two
const open_cap = 4096;

inline fn key(n: Node) u32 {
    return @as(u32, @intCast(n.x)) | (@as(u32, @intCast(n.y)) << 8) | (@as(u32, @intCast(n.l)) << 16);
}
inline fn unkey(k: u32) Node {
    return .{ .x = @intCast(k & 0xFF), .y = @intCast((k >> 8) & 0xFF), .l = @intCast((k >> 16) & 0xFF) };
}
inline fn manhattan(n: Node, gx: i32, gy: i32) u16 {
    return @intCast(@min(@abs(n.x - gx) + @abs(n.y - gy), 0xFFFF));
}

const Search = struct {
    // Closed/seen table: key+1 (0 empty), best g, parent slot.
    keys: [closed_cap]u32 = @splat(0),
    gs: [closed_cap]u16 = undefined,
    parents: [closed_cap]u16 = undefined,
    // Open heap entries: (f << 48) | (seq << 16) | slot.
    heap: [open_cap]u64 = undefined,
    len: u32 = 0,
    seq: u32 = 0,

    const no_parent: u16 = 0xFFFF;

    fn slot(s: *Search, k: u32) ?u32 {
        var i = (k *% 0x9E37_79B1) >> (32 - 13);
        var probes: u32 = 0;
        while (probes < closed_cap) : (probes += 1) {
            if (s.keys[i] == 0 or s.keys[i] == k + 1) return i;
            i = (i + 1) & (closed_cap - 1);
        }
        return null;
    }
    fn push(s: *Search, f: u16, sl: u32) void {
        if (s.len >= open_cap) return;
        const e = (@as(u64, f) << 48) | (@as(u64, s.seq & 0xFFFF_FFFF) << 16) | sl;
        s.seq += 1;
        var i = s.len;
        s.len += 1;
        s.heap[i] = e;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (s.heap[p] <= s.heap[i]) break;
            std.mem.swap(u64, &s.heap[p], &s.heap[i]);
            i = p;
        }
    }
    fn pop(s: *Search) ?u64 {
        if (s.len == 0) return null;
        const top = s.heap[0];
        s.len -= 1;
        s.heap[0] = s.heap[s.len];
        var i: u32 = 0;
        while (true) {
            const l = 2 * i + 1;
            if (l >= s.len) break;
            var m = l;
            if (l + 1 < s.len and s.heap[l + 1] < s.heap[l]) m = l + 1;
            if (s.heap[i] <= s.heap[m]) break;
            std.mem.swap(u64, &s.heap[i], &s.heap[m]);
            i = m;
        }
        return top;
    }
    /// The first three directions of the path from the start to `sl`.
    fn steps(s: *const Search, sl: u32) Steps {
        // Walk back, keeping the last three moves seen (nearest the start).
        var ring: [3]u8 = .{ no_dir, no_dir, no_dir };
        var cur = sl;
        while (s.parents[cur] != no_parent) {
            const p = s.parents[cur];
            const a = unkey(s.keys[p] - 1);
            const b = unkey(s.keys[cur] - 1);
            const d: u8 = if (b.x > a.x) 0 else if (b.y > a.y) 1 else if (b.x < a.x) 2 else 3;
            ring[2] = ring[1];
            ring[1] = ring[0];
            ring[0] = d;
            cur = p;
        }
        return .{ .dirs = ring };
    }
};

pub const no_dir: u8 = 0xFF;

/// The first three moves of a planned route (`no_dir` past its end).
pub const Steps = struct {
    dirs: [3]u8,

    pub fn first(st: Steps) ?u2 {
        return if (st.dirs[0] == no_dir) null else @intCast(st.dirs[0]);
    }
};

/// The start of a route from road cell `from` to block (gx, gy) (any
/// level), or null when `from` is not road, is already there, or no move
/// leads anywhere.
pub fn plan(g: *const abi.Grid, from: Node, gx: i32, gy: i32, opts: Opts) ?Steps {
    if (!roadAt(g, from.x, from.y, from.l)) return null;
    if (from.x == gx and from.y == gy) return null;
    const max_nodes = if (opts.max_nodes == 0) TF.route_max_nodes else opts.max_nodes;
    var s: Search = .{};
    const k0 = key(from);
    const s0 = s.slot(k0).?;
    s.keys[s0] = k0 + 1;
    s.gs[s0] = 0;
    s.parents[s0] = Search.no_parent;
    s.push(manhattan(from, gx, gy), s0);
    var best_h: u16 = 0xFFFF;
    var best: u32 = s0;
    var expanded: u32 = 0;
    while (s.pop()) |e| {
        const sl: u32 = @intCast(e & 0xFFFF);
        const f: u16 = @intCast(e >> 48);
        const n = unkey(s.keys[sl] - 1);
        const gn = s.gs[sl];
        const h = manhattan(n, gx, gy);
        if (f > gn + h) continue; // stale entry
        if (h == 0) return s.steps(sl);
        if (h < best_h and sl != s0) {
            best_h = h;
            best = sl;
        }
        expanded += 1;
        if (expanded >= max_nodes) break;
        var d: u3 = 0;
        while (d < 4) : (d += 1) {
            const m = move(g, n, @intCast(d), opts) orelse continue;
            const k = key(m.to);
            const ts = s.slot(k) orelse continue;
            const ng = gn +| m.cost;
            if (s.keys[ts] != 0 and s.gs[ts] <= ng) continue;
            s.keys[ts] = k + 1;
            s.gs[ts] = ng;
            s.parents[ts] = @intCast(sl);
            s.push(ng +| manhattan(m.to, gx, gy), ts);
        }
    }
    if (best == s0) return null;
    return s.steps(best);
}

/// First direction of a route from road cell `from` to block (gx, gy).
pub fn firstStep(g: *const abi.Grid, from: Node, gx: i32, gy: i32, opts: Opts) ?u2 {
    const st = plan(g, from, gx, gy, opts) orelse return null;
    return st.first();
}

pub fn Sys(comptime Self: type) type {
    return struct {
        /// The next road direction (0 +x, 1 +y, 2 -x, 3 -y) from block
        /// (bx, by) at level bz toward (tx, ty), or null if there is none.
        /// Deterministic and bounded per call. `bz` is the level of the
        /// road cell itself (`levelOf` for a body); if (tx, ty) is not
        /// road, the route goes to the nearest road block to it.
        pub fn nextRoadDir(self: *const Self, bx: i32, by: i32, bz: i32, tx: i32, ty: i32) ?u2 {
            return nextRoadDirOpts(self, bx, by, bz, tx, ty, .{});
        }

        /// `nextRoadDir` with options (the chase allowance, a node bound).
        pub fn nextRoadDirOpts(self: *const Self, bx: i32, by: i32, bz: i32, tx: i32, ty: i32, opts: Opts) ?u2 {
            const goal = nearestRoad(self.grid, tx, ty, bz, TF.route_goal_radius) orelse Node{ .x = tx, .y = ty, .l = bz };
            return firstStep(self.grid, .{ .x = bx, .y = by, .l = bz }, goal.x, goal.y, opts);
        }

        /// The level of the road cell a car or ped stands on (for `bz`).
        pub fn levelOf(self: *const Self, t: *const c.Transform) i32 {
            return levelUnder(self.grid, t.x, t.y, t.z, T.car_step);
        }

        /// The nearest road block to (tx, ty), preferring level `l`.
        pub fn nearestRoadTo(self: *const Self, tx: i32, ty: i32, l: i32) ?Node {
            return nearestRoad(self.grid, tx, ty, l, TF.route_goal_radius);
        }
    };
}
