//! Compiled mission scripts (`.scr`): the main file, mission sub-scripts,
//! the string table, a type table, and `scrasm`, a small assembler that
//! writes scripts from text so tests and CI never need game data.
//! Workstream A1 (docs/behaviour/mission-scripts.md 2).
//!
//! Main file: 6000 u16 command offsets, 65536 bytes of commands, a u16
//! string table size, then the string table. Each command starts with four
//! 16-bit fields: its own number, its type, the next command (0xFFFF ends
//! the thread) and the "return value" field (1 marks a WHILE_EXEC line).
//!
//! Mission sub-script: u16 first slot, u16 start command, u32 data length,
//! 1536 u16 offsets (3072 bytes) for slots `first..first+1535`, then the
//! data, which the game copies into the main command area at the first
//! offset. Offsets are into that shared area.
//!
//! String table entry: u32 key (the number of the command the name belongs
//! to; commands name strings by that key), u32 kind (21 mission, 10 zone,
//! 17 gang, as seen in the player's files), u8 length, then that many bytes
//! (NUL padded).

const std = @import("std");
const ifaces = @import("interfaces");
const lv = ifaces.level;

pub const slots = 6000;
pub const code_size = 65536;
pub const mission_slots = 1536;
pub const header_size = 8;
pub const level_end: u16 = 0xFFFF;

pub const string_mission: u32 = 21;
pub const string_zone: u32 = 10;
pub const string_gang: u32 = 17;

pub const Header = struct {
    num: u16,
    kind: u16,
    next: u16,
    ret: i16,
};

pub fn rd16(b: []const u8, off: usize) u16 {
    if (off + 2 > b.len) return 0;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

pub fn rd32(b: []const u8, off: usize) u32 {
    if (off + 4 > b.len) return 0;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// A command found in a script: where its bytes are.
pub const Found = struct {
    header: Header,
    /// The bytes after the header, to the end of the code (a handler reads
    /// only its own layout).
    params: []const u8,
};

/// Command `num` in `s`, or null.
pub fn find(s: *const lv.Script, num: u16) ?Found {
    if (num < s.first) return null;
    const i = num - s.first;
    if (i >= s.pointers.len) return null;
    const p = s.pointers[i];
    if (p == 0 and !(s.first == 0 and i == 0)) return null;
    if (p < s.base) return null;
    const off: usize = p - s.base;
    if (off + header_size > s.code.len) return null;
    const c = s.code;
    return .{
        .header = .{ .num = rd16(c, off), .kind = rd16(c, off + 2), .next = rd16(c, off + 4), .ret = @bitCast(rd16(c, off + 6)) },
        .params = c[off + header_size .. @min(c.len, off + header_size + 64)],
    };
}

/// A string table entry.
pub const Entry = struct { key: u32, kind: u32, text: []const u8 };

pub const StringIter = struct {
    b: []const u8,
    p: usize = 0,
    pub fn next(it: *StringIter) ?Entry {
        if (it.p + 9 > it.b.len) return null;
        const key = rd32(it.b, it.p);
        const kind = rd32(it.b, it.p + 4);
        const n = it.b[it.p + 8];
        const start = it.p + 9;
        const end = @min(it.b.len, start + n);
        it.p = start + n;
        const raw = it.b[start..end];
        const z = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        return .{ .key = key, .kind = kind, .text = raw[0..z] };
    }
};

pub fn strings(table: []const u8) StringIter {
    return .{ .b = table };
}

/// The string table entry with this key, if any.
pub fn stringByKey(table: []const u8, key: u32) ?Entry {
    var it = strings(table);
    while (it.next()) |e| if (e.key == key) return e;
    return null;
}

/// "wil_le1.mis" -> "wil_le1".
pub fn stem(name: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| name[i + 1 ..] else name;
    return if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[0..i] else base;
}

pub const Parsed = struct {
    script: lv.Script,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(p: *Parsed) void {
        p.arena.deinit();
        p.* = undefined;
    }
};

/// Parse a main `.scr` file. The result owns copies of everything.
pub fn parseMain(gpa: std.mem.Allocator, bytes: []const u8) !Parsed {
    const head = slots * 2 + code_size + 2;
    if (bytes.len < head) return error.Truncated;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const ptrs = try a.alloc(u16, slots);
    for (ptrs, 0..) |*p, i| p.* = rd16(bytes, i * 2);
    const code = try a.dupe(u8, bytes[slots * 2 ..][0..code_size]);
    const n: usize = rd16(bytes, slots * 2 + code_size);
    if (head + n > bytes.len) return error.Truncated;
    const st = try a.dupe(u8, bytes[head..][0..n]);
    return .{ .script = .{ .code = code, .pointers = ptrs, .strings = st }, .arena = arena };
}

/// Parse a mission sub-script file; `name` is its stem ("wil_le1").
pub fn parseMission(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8) !Parsed {
    const head = 8 + mission_slots * 2;
    if (bytes.len < head) return error.Truncated;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const first = rd16(bytes, 0);
    const start = rd16(bytes, 2);
    const len = rd32(bytes, 4);
    if (head + len > bytes.len) return error.Truncated;
    const ptrs = try a.alloc(u16, mission_slots);
    for (ptrs, 0..) |*p, i| p.* = rd16(bytes, 8 + i * 2);
    var base: u16 = 0xFFFF;
    for (ptrs) |p| if (p != 0 and p < base) {
        base = p;
    };
    if (base == 0xFFFF) base = 0;
    const code = try a.dupe(u8, bytes[head..][0..len]);
    return .{ .script = .{ .code = code, .pointers = ptrs, .first = first, .base = base, .start = start, .name = try a.dupe(u8, name) }, .arena = arena };
}

// ---------------------------------------------------------------------------
// Command types

pub const Owner = enum { a1, a2, unknown };

/// A command type: its number, the name scrasm uses, its size in bytes
/// (header included) as compiled in the player's files, who handles it, and
/// whether the number is confirmed from data (`guess` = not seen in any of
/// the player's level scripts; picked by A1 and listed in the coverage
/// files).
pub const TypeInfo = struct {
    kind: u16,
    name: []const u8,
    size: u16,
    owner: Owner = .a2,
    guess: bool = false,
};

/// Every type in the player's level scripts (sizes from those files), plus
/// the A1 types the notes describe but no level uses (`guess`). Names are
/// ours. Numbers named by the notes are marked there; the unnamed flow and
/// counter types were identified from how the level scripts use them
/// (docs/coverage/script-flow-control.md and script-counters.md).
pub const types = [_]TypeInfo{
    // --- A1: flow control (script-flow-control.md)
    .{ .kind = 59, .name = "level_start", .size = 8, .owner = .a1 },
    .{ .kind = 60, .name = "level_end", .size = 8, .owner = .a1 },
    .{ .kind = 63, .name = "exec", .size = 8, .owner = .a1 },
    .{ .kind = 64, .name = "endexec", .size = 8, .owner = .a1 },
    .{ .kind = 67, .name = "label", .size = 8, .owner = .a1 },
    .{ .kind = 68, .name = "return", .size = 8, .owner = .a1 },
    .{ .kind = 71, .name = "not", .size = 8, .owner = .a1 },
    .{ .kind = 77, .name = "endwhile", .size = 12, .owner = .a1 },
    .{ .kind = 78, .name = "gosub", .size = 12, .owner = .a1 },
    .{ .kind = 98, .name = "if", .size = 12, .owner = .a1 },
    .{ .kind = 61, .name = "wait", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 62, .name = "delay", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 207, .name = "start_thread", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 208, .name = "stop_thread", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 210, .name = "thread_decl", .size = 8, .owner = .a1, .guess = true },
    .{ .kind = 215, .name = "trigger_on", .size = 12, .owner = .a1 },
    .{ .kind = 216, .name = "trigger_off", .size = 12, .owner = .a1 },
    // --- A1: the HUD arrow (script-declarations.md 2.6 declares it; the
    // point and remove commands are ours, from the player's files)
    .{ .kind = 23, .name = "arrow", .size = 12, .owner = .a1 },
    .{ .kind = 113, .name = "arrow_at", .size = 16, .owner = .a1, .guess = true },
    .{ .kind = 114, .name = "arrow_pos", .size = 24, .owner = .a1, .guess = true },
    .{ .kind = 116, .name = "arrow_clear", .size = 12, .owner = .a1, .guess = true },
    // --- A1: counters (script-counters.md)
    .{ .kind = 21, .name = "counter", .size = 12, .owner = .a1 },
    .{ .kind = 22, .name = "counter_bare", .size = 8, .owner = .a1, .guess = true },
    .{ .kind = 276, .name = "counter_v", .size = 12, .owner = .a1 },
    .{ .kind = 24, .name = "save_counter_bare", .size = 8, .owner = .a1, .guess = true },
    .{ .kind = 340, .name = "set", .size = 12, .owner = .a1 },
    .{ .kind = 341, .name = "copy", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 96, .name = "inc", .size = 12, .owner = .a1 },
    .{ .kind = 97, .name = "dec", .size = 12, .owner = .a1 },
    .{ .kind = 86, .name = "lt", .size = 12, .owner = .a1 },
    .{ .kind = 87, .name = "lt_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 88, .name = "le", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 89, .name = "le_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 90, .name = "gt", .size = 12, .owner = .a1 },
    .{ .kind = 91, .name = "gt_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 92, .name = "ge", .size = 12, .owner = .a1 },
    .{ .kind = 93, .name = "ge_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 94, .name = "eq", .size = 12, .owner = .a1 },
    .{ .kind = 95, .name = "eq_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 84, .name = "sum_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 85, .name = "diff_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 108, .name = "add_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 109, .name = "sub_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 110, .name = "mul_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 111, .name = "div_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 112, .name = "mod_c", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 79, .name = "add", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 80, .name = "sub", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 81, .name = "mul", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 82, .name = "div", .size = 12, .owner = .a1, .guess = true },
    .{ .kind = 83, .name = "mod", .size = 12, .owner = .a1, .guess = true },
    // --- A1: messages (script-messages.md)
    .{ .kind = 117, .name = "message", .size = 12, .owner = .a1 },
    .{ .kind = 118, .name = "brief", .size = 12, .owner = .a1 },
    .{ .kind = 279, .name = "brief_now", .size = 12, .owner = .a1 },
    .{ .kind = 321, .name = "brief_soon", .size = 12, .owner = .a1 },
    .{ .kind = 317, .name = "clear_briefs", .size = 8, .owner = .a1 },
    .{ .kind = 325, .name = "brief_showing", .size = 8, .owner = .a1 },
    .{ .kind = 233, .name = "display_decl", .size = 12, .owner = .a1 },
    .{ .kind = 413, .name = "counter_display_decl", .size = 12, .owner = .a1 },
    .{ .kind = 119, .name = "timer", .size = 12, .owner = .a1 },
    .{ .kind = 433, .name = "timer_add", .size = 12, .owner = .a1 },
    .{ .kind = 120, .name = "timer_clear", .size = 12, .owner = .a1 },
    .{ .kind = 416, .name = "clock_clear", .size = 12, .owner = .a1 },
    .{ .kind = 414, .name = "show_counter", .size = 12, .owner = .a1 },
    .{ .kind = 415, .name = "counter_clear", .size = 12, .owner = .a1 },
    // --- A1: missions (script-missions.md)
    .{ .kind = 274, .name = "mission", .size = 12, .owner = .a1 },
    .{ .kind = 263, .name = "gang_phone", .size = 32, .owner = .a1 },
    .{ .kind = 329, .name = "gang_phone_open", .size = 32, .owner = .a1 },
    .{ .kind = 272, .name = "mission_begin", .size = 8, .owner = .a1 },
    .{ .kind = 273, .name = "mission_end", .size = 8, .owner = .a1 },
    .{ .kind = 391, .name = "mission_cleanup", .size = 8, .owner = .a1 },
    .{ .kind = 288, .name = "challenge", .size = 28, .owner = .a1 },
    .{ .kind = 289, .name = "challenge_b", .size = 28, .owner = .a1, .guess = true },
    .{ .kind = 290, .name = "challenge_c", .size = 28, .owner = .a1 },
    .{ .kind = 291, .name = "challenge_d", .size = 28, .owner = .a1, .guess = true },
    .{ .kind = 292, .name = "challenge_passed", .size = 12, .owner = .a1 },
    .{ .kind = 293, .name = "challenge_failed", .size = 12, .owner = .a1 },
    .{ .kind = 294, .name = "challenge_done", .size = 12, .owner = .a1 },
    .{ .kind = 401, .name = "challenge_dead", .size = 12, .owner = .a1 },
    .{ .kind = 402, .name = "challenge_progress", .size = 12, .owner = .a1 },
    .{ .kind = 422, .name = "frenzy", .size = 20, .owner = .a1 },
    .{ .kind = 423, .name = "frenzy_run", .size = 32, .owner = .a1 },
    // --- A2 (script-declarations, -cars, -characters, -objects, -player):
    // sizes from the player's files; A2 names them.
    .{ .kind = 5, .name = "player_ped", .size = 28 },
    .{ .kind = 211, .name = "car_trigger", .size = 20 },
    .{ .kind = 213, .name = "phone_trigger", .size = 20 },
    .{ .kind = 214, .name = "area_trigger", .size = 40 },
} ++ a2_sizes;

/// Sizes of the remaining types seen in the player's files, by number.
const a2_sizes = blk: {
    const pairs = [_][2]u16{
        .{ 6, 36 },   .{ 9, 32 },   .{ 10, 32 },  .{ 11, 32 },  .{ 14, 28 },  .{ 15, 28 },  .{ 16, 28 },  .{ 18, 32 },  .{ 20, 32 },
        .{ 26, 36 },  .{ 27, 36 },  .{ 30, 36 },  .{ 32, 36 },  .{ 35, 32 },  .{ 38, 40 },  .{ 39, 28 },  .{ 40, 20 },  .{ 41, 32 },
        .{ 42, 32 },  .{ 43, 32 },  .{ 44, 32 },  .{ 45, 32 },  .{ 46, 32 },  .{ 47, 32 },  .{ 49, 28 },  .{ 52, 28 },  .{ 100, 12 },
        .{ 101, 8 },  .{ 102, 32 }, .{ 103, 16 }, .{ 104, 16 }, .{ 105, 16 }, .{ 106, 16 }, .{ 107, 16 },
        .{ 121, 12 }, .{ 122, 12 }, .{ 123, 12 }, .{ 126, 12 }, .{ 127, 12 }, .{ 128, 12 }, .{ 129, 12 }, .{ 131, 12 },
        .{ 132, 16 }, .{ 133, 24 }, .{ 134, 12 }, .{ 138, 12 }, .{ 139, 24 }, .{ 140, 12 }, .{ 141, 16 }, .{ 142, 20 }, .{ 144, 12 },
        .{ 145, 32 }, .{ 146, 32 }, .{ 147, 32 }, .{ 151, 12 }, .{ 152, 12 }, .{ 153, 12 }, .{ 154, 12 }, .{ 157, 12 }, .{ 158, 12 },
        .{ 160, 12 }, .{ 161, 12 }, .{ 162, 12 }, .{ 163, 12 }, .{ 164, 12 }, .{ 165, 12 }, .{ 166, 12 }, .{ 167, 12 }, .{ 171, 12 },
        .{ 173, 12 }, .{ 175, 12 }, .{ 177, 12 }, .{ 178, 12 }, .{ 179, 12 }, .{ 180, 12 }, .{ 182, 16 }, .{ 183, 12 }, .{ 184, 12 },
        .{ 185, 16 }, .{ 186, 16 }, .{ 187, 16 }, .{ 188, 12 }, .{ 189, 32 }, .{ 190, 12 }, .{ 194, 16 }, .{ 195, 12 }, .{ 198, 16 },
        .{ 205, 24 }, .{ 218, 12 }, .{ 223, 32 }, .{ 224, 16 }, .{ 226, 16 }, .{ 229, 12 }, .{ 230, 16 }, .{ 231, 16 }, .{ 232, 12 },
        .{ 234, 12 }, .{ 235, 12 }, .{ 236, 12 }, .{ 237, 12 }, .{ 238, 12 }, .{ 240, 12 }, .{ 241, 12 }, .{ 242, 12 }, .{ 243, 12 },
        .{ 244, 12 }, .{ 245, 12 }, .{ 246, 12 }, .{ 247, 12 }, .{ 248, 12 }, .{ 249, 12 }, .{ 251, 12 }, .{ 253, 12 }, .{ 254, 12 },
        .{ 256, 12 }, .{ 257, 8 },  .{ 258, 12 }, .{ 259, 12 }, .{ 260, 12 }, .{ 261, 8 },  .{ 262, 16 }, .{ 264, 12 }, .{ 265, 12 },
        .{ 266, 16 }, .{ 267, 12 }, .{ 268, 12 }, .{ 270, 32 }, .{ 271, 12 }, .{ 275, 12 }, .{ 278, 12 }, .{ 282, 12 },
        .{ 283, 20 }, .{ 284, 20 }, .{ 285, 16 }, .{ 286, 16 }, .{ 287, 20 }, .{ 299, 12 }, .{ 300, 8 },  .{ 301, 36 }, .{ 302, 36 },
        .{ 303, 16 }, .{ 304, 12 }, .{ 305, 12 }, .{ 306, 12 }, .{ 307, 16 }, .{ 308, 16 }, .{ 309, 16 }, .{ 310, 12 }, .{ 311, 12 },
        .{ 312, 12 }, .{ 313, 12 }, .{ 315, 20 }, .{ 316, 12 }, .{ 318, 12 }, .{ 319, 12 }, .{ 326, 28 }, .{ 327, 28 }, .{ 328, 28 },
        .{ 330, 20 }, .{ 334, 16 }, .{ 335, 16 }, .{ 338, 16 }, .{ 342, 16 }, .{ 343, 12 }, .{ 344, 12 }, .{ 345, 12 }, .{ 346, 12 },
        .{ 347, 12 }, .{ 348, 12 }, .{ 349, 12 }, .{ 350, 12 }, .{ 353, 28 }, .{ 355, 12 }, .{ 356, 12 }, .{ 357, 24 }, .{ 358, 16 },
        .{ 359, 16 }, .{ 360, 12 }, .{ 361, 12 }, .{ 362, 16 }, .{ 363, 12 }, .{ 364, 16 }, .{ 365, 12 }, .{ 366, 12 }, .{ 367, 20 },
        .{ 368, 12 }, .{ 369, 12 }, .{ 370, 12 }, .{ 371, 12 }, .{ 373, 12 }, .{ 375, 44 }, .{ 378, 44 }, .{ 381, 20 }, .{ 382, 20 },
        .{ 386, 12 }, .{ 387, 12 }, .{ 388, 12 }, .{ 389, 12 }, .{ 390, 12 }, .{ 392, 16 }, .{ 393, 16 }, .{ 395, 32 }, .{ 398, 12 },
        .{ 399, 20 }, .{ 400, 12 }, .{ 403, 12 }, .{ 406, 20 }, .{ 407, 12 }, .{ 408, 16 }, .{ 410, 16 }, .{ 417, 12 },
        .{ 418, 12 }, .{ 419, 12 }, .{ 421, 12 }, .{ 424, 12 }, .{ 425, 32 }, .{ 426, 32 }, .{ 429, 12 }, .{ 430, 12 }, .{ 431, 12 },
        .{ 432, 12 }, .{ 435, 16 }, .{ 436, 16 }, .{ 437, 16 }, .{ 438, 32 }, .{ 439, 16 }, .{ 441, 24 }, .{ 442, 12 }, .{ 443, 8 },
        .{ 444, 12 },
    };
    var out: [pairs.len]TypeInfo = undefined;
    for (pairs, &out) |p, *o| o.* = .{ .kind = p[0], .name = "", .size = p[1] };
    break :blk out;
};

pub fn typeInfo(kind: u16) ?TypeInfo {
    inline for (types) |t| if (t.kind == kind) return t;
    return null;
}

pub fn typeByName(name: []const u8) ?TypeInfo {
    for (types) |t| if (t.name.len > 0 and std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// Size in bytes of a command of `kind` (header included); unknown types
/// get 8 + the given parameter bytes, rounded up to 4.
pub fn sizeOf(kind: u16, param_bytes: usize) usize {
    if (typeInfo(kind)) |t| return @max(t.size, std.mem.alignForward(usize, header_size + param_bytes, 4));
    return std.mem.alignForward(usize, header_size + param_bytes, 4);
}

/// Every command of a script, in command-number order (for tools).
pub fn forEach(s: *const lv.Script, ctx: anytype, comptime f: fn (@TypeOf(ctx), u16, Found) void) void {
    for (s.pointers, 0..) |_, i| {
        const num: u16 = @intCast(s.first + i);
        if (num == 0) continue;
        if (find(s, num)) |c| f(ctx, num, c);
    }
}

// ---------------------------------------------------------------------------
// scrasm: text to scripts
//
//   # comment (also ; to end of line)
//   .main                         following lines are main-script commands
//   .mission NAME FIRST START     following lines belong to mission NAME,
//                                 slots from FIRST, starting at START
//   .string KEY KIND TEXT         a main string-table entry (KIND: mission,
//                                 zone, gang or a number)
//   NUM TYPE PARAM... [-> NEXT] [!]
//
// TYPE is a number or a name from `types`. A PARAM is a 16-bit word
// (decimal, negative or 0x hex), `L:n` a 32-bit value (two words), or
// `B:a,b` two bytes in one word. The command is zero-padded to its type's
// size. NEXT defaults to the following command line of the same section
// (`end` or 0xFFFF for the end); `!` sets the return-value field to 1
// (a WHILE_EXEC line).

pub const Assembled = struct {
    main: lv.Script,
    missions: []lv.Script,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(a: *Assembled) void {
        a.arena.deinit();
        a.* = undefined;
    }

    pub fn level(a: *const Assembled) lv.Level {
        return .{ .script = a.main, .missions = a.missions };
    }
};

pub const AsmError = error{ BadLine, BadType, BadNumber, Duplicate, TooBig, OutOfMemory };

const Line = struct { num: u16, kind: u16, next: ?u16, ret: bool, words: [32]u16, n: u8, section: u16 };

fn parseNum(t: []const u8) AsmError!i64 {
    if (std.mem.startsWith(u8, t, "0x")) return std.fmt.parseInt(i64, t[2..], 16) catch error.BadNumber;
    if (std.mem.startsWith(u8, t, "-0x")) return -(std.fmt.parseInt(i64, t[3..], 16) catch return error.BadNumber);
    return std.fmt.parseInt(i64, t, 10) catch error.BadNumber;
}

fn word(v: i64) AsmError!u16 {
    if (v < -32768 or v > 65535) return error.BadNumber;
    return @truncate(@as(u64, @bitCast(v)));
}

/// Assemble `text`. `err_line`, if given, receives the failing line number.
pub fn assemble(gpa: std.mem.Allocator, text: []const u8, err_line: ?*usize) AsmError!Assembled {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lines: std.ArrayList(Line) = .empty;
    var strs: std.ArrayList(u8) = .empty;
    const MissionHead = struct { name: []const u8, first: u16, start: u16 };
    var missions: std.ArrayList(MissionHead) = .empty;
    var section: u16 = 0; // 0 = main, i + 1 = mission i

    var it = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    errdefer if (err_line) |e| {
        e.* = lineno;
    };
    while (it.next()) |raw| {
        lineno += 1;
        var l = raw;
        if (std.mem.indexOfAny(u8, l, "#;")) |i| l = l[0..i];
        var tok = std.mem.tokenizeAny(u8, l, " \t\r,");
        const first = tok.next() orelse continue;
        if (std.mem.eql(u8, first, ".main")) {
            section = 0;
            continue;
        }
        if (std.mem.eql(u8, first, ".mission")) {
            const name = tok.next() orelse return error.BadLine;
            const f: u16 = @intCast(try parseNum(tok.next() orelse return error.BadLine));
            const s: u16 = @intCast(try parseNum(tok.next() orelse return error.BadLine));
            try missions.append(a, .{ .name = try a.dupe(u8, name), .first = f, .start = s });
            section = @intCast(missions.items.len);
            continue;
        }
        if (std.mem.eql(u8, first, ".string")) {
            const key: u32 = @intCast(try parseNum(tok.next() orelse return error.BadLine));
            const ks = tok.next() orelse return error.BadLine;
            const kind: u32 = if (std.mem.eql(u8, ks, "mission")) string_mission else if (std.mem.eql(u8, ks, "zone")) string_zone else if (std.mem.eql(u8, ks, "gang")) string_gang else @intCast(try parseNum(ks));
            const s = tok.next() orelse return error.BadLine;
            var hdr: [9]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], key, .little);
            std.mem.writeInt(u32, hdr[4..8], kind, .little);
            const n = std.mem.alignForward(usize, s.len + 1, 2);
            hdr[8] = @intCast(n);
            try strs.appendSlice(a, &hdr);
            try strs.appendSlice(a, s);
            try strs.appendNTimes(a, 0, n - s.len);
            continue;
        }
        var ln: Line = .{ .num = @intCast(try parseNum(first)), .kind = 0, .next = null, .ret = false, .words = @splat(0), .n = 0, .section = section };
        const ts = tok.next() orelse return error.BadLine;
        ln.kind = if (typeByName(ts)) |t| t.kind else @intCast(parseNum(ts) catch return error.BadType);
        while (tok.next()) |p| {
            if (std.mem.eql(u8, p, "!")) {
                ln.ret = true;
            } else if (std.mem.eql(u8, p, "->")) {
                const t = tok.next() orelse return error.BadLine;
                ln.next = if (std.mem.eql(u8, t, "end")) level_end else try word(try parseNum(t));
            } else if (std.mem.startsWith(u8, p, "L:")) {
                const v: u32 = @truncate(@as(u64, @bitCast(try parseNum(p[2..]))));
                if (ln.n + 2 > ln.words.len) return error.TooBig;
                ln.words[ln.n] = @truncate(v);
                ln.words[ln.n + 1] = @truncate(v >> 16);
                ln.n += 2;
            } else if (std.mem.startsWith(u8, p, "B:")) {
                var bt = std.mem.splitScalar(u8, p[2..], ':');
                const lo: u8 = @truncate(@as(u64, @bitCast(try parseNum(bt.next() orelse return error.BadLine))));
                const hi: u8 = @truncate(@as(u64, @bitCast(try parseNum(bt.next() orelse "0"))));
                if (ln.n + 1 > ln.words.len) return error.TooBig;
                ln.words[ln.n] = @as(u16, lo) | (@as(u16, hi) << 8);
                ln.n += 1;
            } else {
                if (ln.n + 1 > ln.words.len) return error.TooBig;
                ln.words[ln.n] = try word(try parseNum(p));
                ln.n += 1;
            }
        }
        try lines.append(a, ln);
    }
    lineno = 0;

    // Main script.
    const main_code = try a.alloc(u8, code_size);
    @memset(main_code, 0);
    const main_ptrs = try a.alloc(u16, slots);
    @memset(main_ptrs, 0);
    var used: usize = header_size; // command 0 is a dummy at offset 0
    try emit(lines.items, 0, main_code, main_ptrs, 0, &used);

    const out_missions = try a.alloc(lv.Script, missions.items.len);
    for (missions.items, out_missions, 0..) |m, *o, i| {
        const base: usize = std.mem.alignForward(usize, used, 4);
        var mused: usize = 0;
        const buf = try a.alloc(u8, code_size - base);
        @memset(buf, 0);
        const ptrs = try a.alloc(u16, mission_slots);
        @memset(ptrs, 0);
        try emitMission(lines.items, @intCast(i + 1), buf, ptrs, m.first, base, &mused);
        o.* = .{ .code = buf[0..mused], .pointers = ptrs, .first = m.first, .base = @intCast(base), .start = m.start, .name = m.name };
    }
    return .{
        .main = .{ .code = main_code, .pointers = main_ptrs, .strings = try strs.toOwnedSlice(a) },
        .missions = out_missions,
        .arena = arena,
    };
}

fn nextOf(lines: []const Line, i: usize, section: u16) u16 {
    if (lines[i].next) |n| return n;
    var j = i + 1;
    while (j < lines.len) : (j += 1) if (lines[j].section == section) return lines[j].num;
    return level_end;
}

fn put(code: []u8, off: usize, ln: Line, next: u16) AsmError!usize {
    const size = sizeOf(ln.kind, @as(usize, ln.n) * 2);
    if (off + size > code.len) return error.TooBig;
    @memset(code[off..][0..size], 0);
    std.mem.writeInt(u16, code[off..][0..2], ln.num, .little);
    std.mem.writeInt(u16, code[off + 2 ..][0..2], ln.kind, .little);
    std.mem.writeInt(u16, code[off + 4 ..][0..2], next, .little);
    std.mem.writeInt(u16, code[off + 6 ..][0..2], if (ln.ret) 1 else 0, .little);
    for (ln.words[0..ln.n], 0..) |w, k| std.mem.writeInt(u16, code[off + 8 + k * 2 ..][0..2], w, .little);
    return size;
}

fn emit(lines: []const Line, section: u16, code: []u8, ptrs: []u16, first: u16, used: *usize) AsmError!void {
    for (lines, 0..) |ln, i| {
        if (ln.section != section) continue;
        if (ln.num < first or ln.num - first >= ptrs.len or ln.num == 0) return error.BadLine;
        if (ptrs[ln.num - first] != 0) return error.Duplicate;
        ptrs[ln.num - first] = @intCast(used.*);
        used.* += try put(code, used.*, ln, nextOf(lines, i, section));
    }
}

fn emitMission(lines: []const Line, section: u16, code: []u8, ptrs: []u16, first: u16, base: usize, used: *usize) AsmError!void {
    for (lines, 0..) |ln, i| {
        if (ln.section != section) continue;
        if (ln.num < first or ln.num - first >= ptrs.len) return error.BadLine;
        if (ptrs[ln.num - first] != 0) return error.Duplicate;
        if (base + used.* > 0xFFFF) return error.TooBig;
        ptrs[ln.num - first] = @intCast(base + used.*);
        used.* += try put(code, used.*, ln, nextOf(lines, i, section));
    }
}

/// The bytes of a main `.scr` file for `s` (code area padded to 64 KB).
pub fn writeMain(gpa: std.mem.Allocator, s: *const lv.Script) ![]u8 {
    const n = slots * 2 + code_size + 2 + s.strings.len;
    const out = try gpa.alloc(u8, n);
    @memset(out, 0);
    for (0..slots) |i| std.mem.writeInt(u16, out[i * 2 ..][0..2], if (i < s.pointers.len) s.pointers[i] else 0, .little);
    @memcpy(out[slots * 2 ..][0..@min(code_size, s.code.len)], s.code[0..@min(code_size, s.code.len)]);
    std.mem.writeInt(u16, out[slots * 2 + code_size ..][0..2], @intCast(s.strings.len), .little);
    @memcpy(out[slots * 2 + code_size + 2 ..], s.strings);
    return out;
}

/// The bytes of a mission sub-script file for `s`.
pub fn writeMission(gpa: std.mem.Allocator, s: *const lv.Script) ![]u8 {
    const out = try gpa.alloc(u8, 8 + mission_slots * 2 + s.code.len);
    @memset(out, 0);
    std.mem.writeInt(u16, out[0..2], s.first, .little);
    std.mem.writeInt(u16, out[2..4], s.start, .little);
    std.mem.writeInt(u32, out[4..8], @intCast(s.code.len), .little);
    for (0..mission_slots) |i| std.mem.writeInt(u16, out[8 + i * 2 ..][0..2], if (i < s.pointers.len) s.pointers[i] else 0, .little);
    @memcpy(out[8 + mission_slots * 2 ..], s.code);
    return out;
}

// ---------------------------------------------------------------------------

test "assemble, write, parse back" {
    const gpa = std.testing.allocator;
    var asmd = try assemble(gpa,
        \\.string 20 mission demo_m1.mis
        \\.main
        \\1 counter 5
        \\2 level_start
        \\3 set 1 7 !
        \\4 mission 20 -> end
        \\.mission demo_m1 100 101
        \\100 counter 0
        \\101 eq 1 L:70000
    , null);
    defer asmd.deinit();
    const m = asmd.main;
    const c1 = find(&m, 1).?;
    try std.testing.expectEqual(@as(u16, 21), c1.header.kind);
    try std.testing.expectEqual(@as(u16, 2), c1.header.next);
    try std.testing.expectEqual(@as(u16, 5), rd16(c1.params, 0));
    try std.testing.expectEqual(@as(i16, 1), find(&m, 3).?.header.ret);
    try std.testing.expectEqual(level_end, find(&m, 4).?.header.next);
    try std.testing.expectEqualStrings("demo_m1.mis", stringByKey(m.strings, 20).?.text);
    try std.testing.expectEqualStrings("demo_m1", stem(stringByKey(m.strings, 20).?.text));

    const bytes = try writeMain(gpa, &m);
    defer gpa.free(bytes);
    var p = try parseMain(gpa, bytes);
    defer p.deinit();
    try std.testing.expectEqual(@as(u16, 59), find(&p.script, 2).?.header.kind);

    const mb = try writeMission(gpa, &asmd.missions[0]);
    defer gpa.free(mb);
    var pm = try parseMission(gpa, mb, "demo_m1");
    defer pm.deinit();
    try std.testing.expectEqual(@as(u16, 101), pm.script.start);
    const c = find(&pm.script, 101).?;
    try std.testing.expectEqual(@as(u16, 94), c.header.kind);
    try std.testing.expectEqual(@as(u32, 70000), rd32(c.params, 2));
    try std.testing.expect(find(&pm.script, 99) == null);
}
