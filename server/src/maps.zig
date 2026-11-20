//! Maps installed by the server operator.
//!
//! The server needs collision data but must never distribute it, so the
//! operator points `--data` at their own copy of the GTA2 data directory,
//! the same way a player picks theirs in the browser. Every `.gmp` there is
//! hashed (SHA-256 of the file bytes, which is what I3 `hello.map_hash`
//! carries) and parsed into an I1 `Grid` the first time a session needs it.

const std = @import("std");
const c = @import("c");
const ifc = @import("interfaces");
const formats = @import("formats");
const util = @import("util.zig");
const abi = ifc.abi;
const gmp = formats.gmp;
const log = std.log.scoped(.maps);

pub const Map = struct {
    /// File name without extension, lowercased: "wil", "ste-multi", ...
    name: []const u8,
    path: []const u8,
    hash: [32]u8,
    size: usize,
    /// Parsed on first use and kept: 1 MiB each, shared by every session on
    /// the map. Never freed while the process runs.
    grid: ?*abi.Grid = null,
    sessions: u32 = 0,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    maps: std.ArrayList(Map) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    /// Adds every .gmp in `dir` (not recursive). Returns how many.
    pub fn scanDir(r: *Registry, dir: []const u8) !usize {
        var zdir: [4096]u8 = undefined;
        if (dir.len >= zdir.len) return error.NameTooLong;
        @memcpy(zdir[0..dir.len], dir);
        zdir[dir.len] = 0;
        const d = c.opendir(@ptrCast(&zdir)) orelse return error.DataDirNotFound;
        defer _ = c.closedir(d);
        var n: usize = 0;
        while (c.readdir(d)) |ent| {
            const fname = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
            if (fname.len < 5 or !std.ascii.eqlIgnoreCase(fname[fname.len - 4 ..], ".gmp")) continue;
            const path = try std.fmt.allocPrint(r.gpa, "{s}/{s}", .{ dir, fname });
            r.addFile(path) catch |e| {
                log.warn("{s}: {}", .{ path, e });
                continue;
            };
            n += 1;
        }
        std.mem.sort(Map, r.maps.items, {}, struct {
            fn lt(_: void, a: Map, b: Map) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        return n;
    }

    pub fn addFile(r: *Registry, path: []const u8) !void {
        const bytes = try util.readFile(r.gpa, path, 64 << 20);
        defer r.gpa.free(bytes);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        const base = std.fs.path.basename(path);
        const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
        const name = try std.ascii.allocLowerString(r.gpa, stem);
        for (r.maps.items) |m| if (std.mem.eql(u8, &m.hash, &hash)) {
            log.info("{s}: same bytes as {s}, skipped", .{ path, m.name });
            r.gpa.free(name);
            return;
        };
        try r.maps.append(r.gpa, .{ .name = name, .path = path, .hash = hash, .size = bytes.len });
    }

    pub fn byHash(r: *Registry, hash: *const [32]u8) ?*Map {
        for (r.maps.items) |*m| if (std.mem.eql(u8, &m.hash, hash)) return m;
        return null;
    }

    pub fn byName(r: *Registry, name: []const u8) ?*Map {
        for (r.maps.items) |*m| if (std.ascii.eqlIgnoreCase(m.name, name)) return m;
        return null;
    }

    /// The map's grid, parsing the file the first time.
    pub fn grid(r: *Registry, m: *Map) !*abi.Grid {
        if (m.grid) |g| return g;
        const bytes = try util.readFile(r.gpa, m.path, 64 << 20);
        defer r.gpa.free(bytes);
        var check: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &check, .{});
        if (!std.mem.eql(u8, &check, &m.hash)) return error.MapChangedOnDisk;
        var parsed = try gmp.parse(r.gpa, bytes);
        defer parsed.deinit();
        const g = try r.gpa.create(abi.Grid);
        // The same builder the browser client uses, so both sides collide
        // against identical cells.
        formats.grid.build(&parsed, g);
        m.grid = g;
        log.info("loaded {s}: {s} {d} block defs", .{ m.name, @tagName(parsed.compression), parsed.blocks.len });
        return g;
    }
};

