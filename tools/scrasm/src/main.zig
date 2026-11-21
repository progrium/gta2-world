//! scrasm (workstream A1): assemble, disassemble and survey mission scripts.
//!
//!   scrasm asm <in.sasm> <outdir>            main.scr plus <mission>.scr
//!   scrasm dis <file.scr> [--mission]        text scrasm can assemble again
//!   scrasm coverage --data <dir> [--out f.md] [--ticks N]
//!
//! `coverage` reads every level script in the player's own data (never
//! committed), lists each command type the scripts use with its count and
//! who handles it (A1's VM, A2's world families: done or stubbed, or
//! nobody), then loads each level into the sim on the synthetic test map,
//! runs the declaration pass and N ticks, and reports threads, unhandled
//! commands met and threads stuck on one command. The report holds type
//! numbers and counts only, no game data.

const std = @import("std");
const formats = @import("formats");
const sim = @import("sim");
const scr = formats.scr;
const lv = sim.level;
const print = std.debug.print;

const SpSim = sim.Sim(sim.config_sp);
const world = sim.sp_state.script.world;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();
    const cwd = std.Io.Dir.cwd();
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "asm")) {
        if (args.len < 4) return usage();
        const text = try cwd.readFileAlloc(io, args[2], gpa, .unlimited);
        defer gpa.free(text);
        var line: usize = 0;
        var a = scr.assemble(gpa, text, &line) catch |e| {
            print("{s}:{d}: {s}\n", .{ args[2], line, @errorName(e) });
            std.process.exit(1);
        };
        defer a.deinit();
        try cwd.createDirPath(io, args[3]);
        const main_bytes = try scr.writeMain(gpa, &a.main);
        defer gpa.free(main_bytes);
        const p = try std.fmt.allocPrint(arena, "{s}/main.scr", .{args[3]});
        try cwd.writeFile(io, .{ .sub_path = p, .data = main_bytes });
        for (a.missions) |*m| {
            const b = try scr.writeMission(gpa, m);
            defer gpa.free(b);
            const mp = try std.fmt.allocPrint(arena, "{s}/{s}.scr", .{ args[3], m.name });
            try cwd.writeFile(io, .{ .sub_path = mp, .data = b });
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "dis")) {
        if (args.len < 3) return usage();
        const bytes = try cwd.readFileAlloc(io, args[2], gpa, .unlimited);
        defer gpa.free(bytes);
        const is_mission = args.len > 3 and std.mem.eql(u8, args[3], "--mission");
        var out: std.ArrayList(u8) = .empty;
        if (is_mission) {
            var p = try scr.parseMission(gpa, bytes, scr.stem(args[2]));
            defer p.deinit();
            try appendf(&out, arena, ".mission {s} {d} {d}\n", .{ p.script.name, p.script.first, p.script.start });
            try dis(&out, arena, &p.script);
        } else {
            var p = try scr.parseMain(gpa, bytes);
            defer p.deinit();
            var it = scr.strings(p.script.strings);
            while (it.next()) |e| try appendf(&out, arena, ".string {d} {d} {s}\n", .{ e.key, e.kind, e.text });
            try appendf(&out, arena, ".main\n", .{});
            try dis(&out, arena, &p.script);
        }
        print("{s}", .{out.items});
        return;
    }
    if (std.mem.eql(u8, cmd, "coverage")) return coverage(io, gpa, arena, args[2..]);
    return usage();
}

fn usage() void {
    print("usage: scrasm asm <in.sasm> <outdir> | dis <file.scr> [--mission] | coverage --data <dir> [--out f.md] [--ticks N]\n", .{});
}

fn appendf(l: *std.ArrayList(u8), a: std.mem.Allocator, comptime f: []const u8, v: anytype) !void {
    try l.appendSlice(a, try std.fmt.allocPrint(a, f, v));
}

fn dis(out: *std.ArrayList(u8), a: std.mem.Allocator, s: *const lv.Script) !void {
    for (0..s.pointers.len) |i| {
        const num: u16 = @intCast(s.first + i);
        if (num == 0) continue;
        const f = scr.find(s, num) orelse continue;
        const info = scr.typeInfo(f.header.kind);
        const size: usize = if (info) |t| t.size else 8;
        if (info != null and info.?.name.len > 0) try appendf(out, a, "{d} {s}", .{ num, info.?.name }) else try appendf(out, a, "{d} {d}", .{ num, f.header.kind });
        var w: usize = 0;
        while (w * 2 + 8 < size) : (w += 1) try appendf(out, a, " {d}", .{scr.rd16(f.params, w * 2)});
        try appendf(out, a, " -> {d}", .{f.header.next});
        if (f.header.ret == 1) try appendf(out, a, " !", .{});
        try appendf(out, a, "\n", .{});
    }
}

const Counts = std.AutoArrayHashMapUnmanaged(u16, u32);

fn tally(counts: *Counts, a: std.mem.Allocator, s: *const lv.Script) !void {
    for (0..s.pointers.len) |i| {
        const num: u16 = @intCast(s.first + i);
        if (num == 0) continue;
        const f = scr.find(s, num) orelse continue;
        const g = try counts.getOrPut(a, f.header.kind);
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* += 1;
    }
}

fn status(kind: u16) []const u8 {
    const a1 = for (scr.types) |t| {
        if (t.kind == kind and t.owner == .a1) break true;
    } else false;
    if (a1) return "A1 done";
    return switch (world.coverage(kind)) {
        .done => "A2 done",
        .stubbed => "A2 stubbed",
        else => "unhandled",
    };
}

fn coverage(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, args: []const []const u8) !void {
    var data: []const u8 = "";
    var out_path: ?[]const u8 = null;
    var ticks: u32 = 3000;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const val = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, args[i], "--data")) {
            data = val;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out")) {
            out_path = val;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--ticks")) {
            ticks = try std.fmt.parseInt(u32, val, 10);
            i += 1;
        }
    }
    if (data.len == 0) return usage();
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, data, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.ascii.endsWithIgnoreCase(e.name, ".scr")) try names.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var counts: Counts = .empty;
    var report: std.ArrayList(u8) = .empty;
    try appendf(&report, a, "# Script coverage\n\nWritten by `tools/scrasm coverage` (workstream A1) from the player's own level scripts: type numbers and counts only. Each level is also loaded into the sim on the synthetic test map and run for {d} ticks with no player.\n\n## Levels\n\n| level | missions | commands | threads at end | unhandled met | stuck threads |\n|---|---|---|---|---|---|\n", .{ticks});

    const grid = try gpa.create(sim.map.Grid);
    defer gpa.destroy(grid);
    sim.testmap.build(grid);
    const s = try gpa.create(SpSim);
    defer gpa.destroy(s);

    for (names.items) |name| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ data, name });
        const bytes = try cwd.readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(bytes);
        var main_p = scr.parseMain(gpa, bytes) catch |e| {
            try appendf(&report, a, "| {s} | could not parse: {s} | | | | |\n", .{ name, @errorName(e) });
            continue;
        };
        defer main_p.deinit();
        var n_cmds: usize = 0;
        for (main_p.script.pointers, 0..) |p, k| {
            if (p != 0 and k != 0) n_cmds += 1;
        }
        try tally(&counts, a, &main_p.script);

        // Mission sub-scripts: <dir>/<stem>/*.scr
        var missions: std.ArrayList(lv.Script) = .empty;
        var parsed: std.ArrayList(scr.Parsed) = .empty;
        defer for (parsed.items) |*p| p.deinit();
        const sub = try std.fmt.allocPrint(a, "{s}/{s}", .{ data, scr.stem(name) });
        if (cwd.openDir(io, sub, .{ .iterate = true })) |d0| {
            var d = d0;
            defer d.close(io);
            var it2 = d.iterate();
            while (try it2.next(io)) |e| {
                if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".scr")) continue;
                const mp = try std.fmt.allocPrint(a, "{s}/{s}", .{ sub, e.name });
                const mb = try cwd.readFileAlloc(io, mp, gpa, .unlimited);
                defer gpa.free(mb);
                const lower = try std.ascii.allocLowerString(a, scr.stem(e.name));
                const pm = scr.parseMission(gpa, mb, lower) catch continue;
                try parsed.append(a, pm);
                try tally(&counts, a, &parsed.items[parsed.items.len - 1].script);
            }
        } else |_| {}
        for (parsed.items) |*p| try missions.append(a, p.script);

        const level: lv.Level = .{ .script = main_p.script, .missions = missions.items };
        s.init(grid, .{ .seed = 1, .mode = .authoritative });
        s.attachLevel(&level);
        var frames = [_]sim.input.Frame{sim.input.Frame.neutral(0)};
        for (0..ticks) |_| s.step(&frames, &.{});
        const vs = &s.state.sp.script;
        var stuck: u32 = 0;
        for (vs.thread[0..vs.threads]) |t| {
            if (t.same > 3000) stuck += 1;
        }
        try appendf(&report, a, "| {s} | {d} | {d} | {d} | {d} | {d} |\n", .{ scr.stem(name), missions.items.len, n_cmds, vs.threads, vs.unhandled, stuck });
    }

    // Types
    const Row = struct { kind: u16, n: u32 };
    var rows: std.ArrayList(Row) = .empty;
    var cit = counts.iterator();
    while (cit.next()) |e| try rows.append(a, .{ .kind = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, x: Row, y: Row) bool {
            return x.kind < y.kind;
        }
    }.lt);
    var summary = [_]u32{ 0, 0, 0, 0 };
    try appendf(&report, a, "\n## Command types used\n\n| type | name | uses | handler |\n|---|---|---|---|\n", .{});
    for (rows.items) |r| {
        const st = status(r.kind);
        const idx: usize = if (std.mem.eql(u8, st, "A1 done")) 0 else if (std.mem.eql(u8, st, "A2 done")) 1 else if (std.mem.eql(u8, st, "A2 stubbed")) 2 else 3;
        summary[idx] += 1;
        const nm = if (scr.typeInfo(r.kind)) |t| t.name else "";
        try appendf(&report, a, "| {d} | {s} | {d} | {s} |\n", .{ r.kind, nm, r.n, st });
    }
    try appendf(&report, a, "\n{d} types: {d} A1 done, {d} A2 done, {d} A2 stubbed, {d} unhandled.\n", .{ rows.items.len, summary[0], summary[1], summary[2], summary[3] });
    print("{s}", .{report.items});
    if (out_path) |p| try cwd.writeFile(io, .{ .sub_path = p, .data = report.items });
}
