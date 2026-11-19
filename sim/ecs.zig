//! In-house ECS with static archetypes, resolved at comptime.
//!
//! * Each entity kind is a fixed-capacity struct-of-arrays table.
//! * The whole world is one `extern struct` with no pointers, so it can be
//!   saved with a memcpy and hashed byte-for-byte on any target.
//! * Systems iterate with `each(.{A, B}, ctx, f)`: comptime picks every table
//!   that has all of A and B and emits a plain loop over it. No runtime queries.
//! * Entities never change kind. Spawns and despawns are deferred: `spawn`
//!   reserves a slot immediately (so ids are allocated deterministically) but the
//!   entity becomes visible to systems only at `applyPending`, which also frees
//!   despawned slots. The free list lives inside the saved state.
//!
//! A component is any `extern struct` that declares `pub const name = "...";`
//! (the column name) and contains only fixed-size integers or nested extern
//! structs, so its layout is identical on wasm32 and 64-bit native.

const std = @import("std");

/// index (12 bits) | kind (4 bits) | generation (16 bits)
pub const EntityId = extern struct {
    raw: u32,

    pub const none: EntityId = .{ .raw = 0xFFFF_FFFF };

    pub inline fn make(kind_idx: u32, idx: u32, generation: u16) EntityId {
        return .{ .raw = (idx & 0xFFF) | ((kind_idx & 0xF) << 12) | (@as(u32, generation) << 16) };
    }
    pub inline fn index(id: EntityId) u32 {
        return id.raw & 0xFFF;
    }
    pub inline fn kind(id: EntityId) u32 {
        return (id.raw >> 12) & 0xF;
    }
    pub inline fn gen(id: EntityId) u16 {
        return @truncate(id.raw >> 16);
    }
    pub inline fn isNone(id: EntityId) bool {
        return id.raw == none.raw;
    }
    pub inline fn eql(a: EntityId, b: EntityId) bool {
        return a.raw == b.raw;
    }
};

pub const max_capacity = 4096;

/// Slot states. Only `alive` slots are visited by `each`.
pub const Slot = struct {
    pub const free: u8 = 0;
    pub const alive: u8 = 1;
    pub const spawning: u8 = 2;
    pub const dying: u8 = 3;
};

/// Declare an entity kind (archetype): a name, a capacity and its components.
pub fn Kind(comptime kind_name: []const u8, comptime capacity_: u16, comptime components_: []const type) type {
    if (capacity_ % 4 != 0) @compileError("capacity must be a multiple of 4 so tables have no padding");
    if (capacity_ > max_capacity) @compileError("capacity exceeds entity id index bits");
    return struct {
        pub const name = kind_name;
        pub const capacity = capacity_;
        pub const components = components_;

        pub fn has(comptime C: type) bool {
            inline for (components) |K| {
                if (K == C) return true;
            }
            return false;
        }
    };
}

fn checkComponent(comptime C: type) void {
    const info = @typeInfo(C);
    if (info != .@"struct" or info.@"struct".layout != .@"extern")
        @compileError(@typeName(C) ++ " must be an extern struct");
    if (!@hasDecl(C, "name")) @compileError(@typeName(C) ++ " must declare `pub const name`");
    if (@sizeOf(C) % 4 != 0) @compileError(@typeName(C) ++ " size must be a multiple of 4");
}

/// Struct-of-arrays columns for one kind: one `[capacity]C` field per component.
fn Columns(comptime K: type) type {
    const n = K.components.len;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    for (K.components, 0..) |C, i| {
        checkComponent(C);
        names[i] = C.name;
        types[i] = [K.capacity]C;
    }
    return @Struct(.@"extern", null, &names, &types, &@splat(.{}));
}

pub fn Table(comptime K: type) type {
    return extern struct {
        const Self = @This();
        pub const kind = K;

        /// High-water mark: slots [0, len) have been used at least once.
        len: u32,
        /// Number of entries on the free stack.
        free_len: u32,
        /// Number of live entities (alive + spawning).
        live: u32,
        _pad: u32,
        gen: [K.capacity]u16,
        free: [K.capacity]u16,
        slot: [K.capacity]u8,
        cols: Columns(K),

        pub inline fn col(self: *Self, comptime C: type) *[K.capacity]C {
            return &@field(self.cols, C.name);
        }
        pub inline fn colConst(self: *const Self, comptime C: type) *const [K.capacity]C {
            return &@field(self.cols, C.name);
        }

        /// Reserve a slot. Returns null when the table is full.
        pub fn reserve(self: *Self) ?u32 {
            var i: u32 = undefined;
            if (self.free_len > 0) {
                self.free_len -= 1;
                i = self.free[self.free_len];
            } else if (self.len < K.capacity) {
                i = self.len;
                self.len += 1;
            } else return null;
            self.slot[i] = Slot.spawning;
            self.live += 1;
            return i;
        }

        pub fn applyPending(self: *Self) void {
            var i: u32 = 0;
            while (i < self.len) : (i += 1) {
                switch (self.slot[i]) {
                    Slot.spawning => self.slot[i] = Slot.alive,
                    Slot.dying => {
                        self.slot[i] = Slot.free;
                        self.gen[i] +%= 1;
                        self.free[self.free_len] = @intCast(i);
                        self.free_len += 1;
                        self.live -= 1;
                        // Zero the components so freed slots hash identically
                        // no matter what they held.
                        inline for (K.components) |C| {
                            self.col(C)[i] = std.mem.zeroes(C);
                        }
                    },
                    else => {},
                }
            }
        }
    };
}

pub fn World(comptime kinds: []const type) type {
    if (kinds.len > 16) @compileError("at most 16 kinds (4 id bits)");

    const Tables = blk: {
        var names: [kinds.len][]const u8 = undefined;
        var types: [kinds.len]type = undefined;
        for (kinds, 0..) |K, i| {
            names[i] = K.name;
            types[i] = Table(K);
        }
        break :blk @Struct(.@"extern", null, &names, &types, &@splat(.{}));
    };

    return extern struct {
        const Self = @This();
        pub const Kinds = kinds;

        tables: Tables,

        pub fn kindIndex(comptime K: type) u32 {
            inline for (kinds, 0..) |Kk, i| {
                if (Kk == K) return i;
            }
            @compileError("unknown kind " ++ @typeName(K));
        }

        pub inline fn table(self: *Self, comptime K: type) *Table(K) {
            return &@field(self.tables, K.name);
        }

        /// Reserve an entity of kind K. Its components start zeroed and may be
        /// written right away through the returned id; systems see it after the
        /// next `applyPending`.
        pub fn spawn(self: *Self, comptime K: type) ?EntityId {
            const t = self.table(K);
            const i = t.reserve() orelse return null;
            inline for (K.components) |C| t.col(C)[i] = std.mem.zeroes(C);
            return EntityId.make(kindIndex(K), i, t.gen[i]);
        }

        /// Queue a despawn. Safe to call more than once in a tick.
        pub fn despawn(self: *Self, id: EntityId) void {
            if (id.isNone()) return;
            inline for (kinds, 0..) |K, ki| {
                if (id.kind() == ki) {
                    const t = self.table(K);
                    const i = id.index();
                    if (i < t.len and t.gen[i] == id.gen() and t.slot[i] != Slot.free)
                        t.slot[i] = Slot.dying;
                    return;
                }
            }
        }

        pub fn isAlive(self: *Self, id: EntityId) bool {
            if (id.isNone()) return false;
            inline for (kinds, 0..) |K, ki| {
                if (id.kind() == ki) {
                    const t = self.table(K);
                    const i = id.index();
                    return i < t.len and t.gen[i] == id.gen() and t.slot[i] == Slot.alive;
                }
            }
            return false;
        }

        /// Component pointer for a live (or just-spawned) entity, or null.
        pub fn get(self: *Self, id: EntityId, comptime C: type) ?*C {
            if (id.isNone()) return null;
            inline for (kinds, 0..) |K, ki| {
                if (comptime K.has(C)) {
                    if (id.kind() == ki) {
                        const t = self.table(K);
                        const i = id.index();
                        if (i < t.len and t.gen[i] == id.gen() and
                            (t.slot[i] == Slot.alive or t.slot[i] == Slot.spawning))
                            return &t.col(C)[i];
                        return null;
                    }
                }
            }
            return null;
        }

        pub fn applyPending(self: *Self) void {
            inline for (kinds) |K| self.table(K).applyPending();
        }

        pub fn count(self: *Self, comptime K: type) u32 {
            return self.table(K).live;
        }

        fn hasAll(comptime K: type, comptime query: anytype) bool {
            inline for (query) |C| {
                if (!K.has(C)) return false;
            }
            return true;
        }

        /// Call `f(ctx, id, *C0, *C1, ...)` for every alive entity in every
        /// kind that has all components in `query`, in kind order then index
        /// order. Comptime selects the tables; each one becomes a plain loop.
        pub inline fn each(self: *Self, comptime query: anytype, ctx: anytype, comptime f: anytype) void {
            inline for (kinds, 0..) |K, ki| {
                if (comptime hasAll(K, query)) {
                    const t = self.table(K);
                    var cols: ColPtrs(K, query) = undefined;
                    inline for (query, 0..) |C, qi| cols[qi] = t.col(C);
                    var i: u32 = 0;
                    while (i < t.len) : (i += 1) {
                        if (t.slot[i] != Slot.alive) continue;
                        var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
                        args[0] = ctx;
                        args[1] = EntityId.make(ki, i, t.gen[i]);
                        inline for (query, 0..) |_, qi| args[qi + 2] = &cols[qi][i];
                        @call(.always_inline, f, args);
                    }
                }
            }
        }

        fn ColPtrs(comptime K: type, comptime query: anytype) type {
            var types: [query.len]type = undefined;
            for (query, 0..) |C, i| types[i] = *[K.capacity]C;
            return @Tuple(&types);
        }
    };
}

// ---------------------------------------------------------------------------

const T = extern struct {
    pub const name = "t";
    x: i32,
};
const V = extern struct {
    pub const name = "v";
    dx: i32,
};
const A = Kind("a", 8, &.{ T, V });
const B = Kind("b", 4, &.{T});
const W = World(&.{ A, B });

test "spawn, iterate, despawn, reuse" {
    var w = std.mem.zeroes(W);
    const a0 = w.spawn(A).?;
    w.get(a0, V).?.dx = 3;
    _ = w.spawn(B).?;
    w.applyPending();

    var n: u32 = 0;
    w.each(.{T}, &n, struct {
        fn f(c: *u32, _: EntityId, _: *T) void {
            c.* += 1;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 2), n);

    w.each(.{ T, V }, {}, struct {
        fn f(_: void, _: EntityId, t: *T, v: *V) void {
            t.x += v.dx;
        }
    }.f);
    try std.testing.expectEqual(@as(i32, 3), w.get(a0, T).?.x);

    w.despawn(a0);
    w.applyPending();
    try std.testing.expect(!w.isAlive(a0));
    const a1 = w.spawn(A).?;
    try std.testing.expectEqual(a0.index(), a1.index());
    try std.testing.expect(a0.gen() != a1.gen());
    try std.testing.expect(w.get(a0, T) == null);
}
