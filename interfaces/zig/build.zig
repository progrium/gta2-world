const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("interfaces", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run interface tests").dependOn(&run_tests.step);

    const vec = b.addExecutable(.{
        .name = "vectors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vectors.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_vec = b.addRunArtifact(vec);
    b.step("vectors", "Print cross-language test vectors").dependOn(&run_vec.step);

    // The interfaces must also compile for the browser target.
    const wasm = b.addLibrary(.{
        .name = "interfaces",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    b.step("wasm", "Check the interfaces build for wasm32").dependOn(&wasm.step);
}
