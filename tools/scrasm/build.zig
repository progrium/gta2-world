//! scrasm (workstream A1): assemble, disassemble and survey mission
//! scripts. Native only.
//!   zig build
//!   zig-out/bin/scrasm asm in.sasm out/        main.scr plus one .scr per mission
//!   zig-out/bin/scrasm dis file.scr [mission.scr...]
//!   zig-out/bin/scrasm coverage --data <dir>   every level script in the player's data

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const formats = b.dependency("formats", .{ .target = target, .optimize = optimize }).module("formats");
    const sim = b.dependency("sim", .{ .target = target, .optimize = optimize }).module("sim");
    const exe = b.addExecutable(.{
        .name = "scrasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "formats", .module = formats }, .{ .name = "sim", .module = sim } },
        }),
    });
    b.installArtifact(exe);
}
