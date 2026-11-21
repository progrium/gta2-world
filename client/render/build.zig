const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = moduleFor(b, target, optimize, true);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run renderer tests").dependOn(&b.addRunArtifact(tests).step);

    // Native tool: inspect a map's mesh, write synthetic fixtures, record
    // the traffic stub.
    const tool = b.addExecutable(.{
        .name = "render-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tool.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "render", .module = mod }, .{ .name = "formats", .module = formatsModule(b, target, optimize) }, .{ .name = "interfaces", .module = interfacesModule(b, target, optimize) } },
        }),
    });
    b.installArtifact(tool);
    const run = b.addRunArtifact(tool);
    run.addPassthruArgs();
    b.step("run", "Run render-tool").dependOn(&run.step);

    // WASM for the demo page.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = moduleFor(b, wasm_target, optimize, false);
    const wasm = b.addExecutable(.{
        .name = "render-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "render", .module = wasm_mod }, .{ .name = "formats", .module = formatsModule(b, wasm_target, optimize) }, .{ .name = "interfaces", .module = interfacesModule(b, wasm_target, optimize) } },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const web = b.step("web", "Build the demo page into zig-out/web (run tsc in ts/ first)");
    web.dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, "render-demo.wasm").step);
    web.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("demo"), .install_dir = .{ .custom = "web" }, .install_subdir = "" }).step);
    web.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("ts/dist"), .install_dir = .{ .custom = "web" }, .install_subdir = "js" }).step);
    const gen = b.addRunArtifact(tool);
    gen.addArg("fixtures");
    const fixtures = gen.addOutputDirectoryArg("fixtures");
    web.dependOn(&b.addInstallDirectory(.{ .source_dir = fixtures, .install_dir = .{ .custom = "web" }, .install_subdir = "fixtures" }).step);
}

fn interfacesModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.dependency("interfaces", .{ .target = target, .optimize = optimize }).module("interfaces");
}

fn formatsModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.dependency("formats", .{ .target = target, .optimize = optimize }).module("formats");
}

/// The `render` module, for this build and for hosts (client/wasm) that
/// depend on this package. The demo's own wasm copy is private.
fn moduleFor(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, public: bool) *std.Build.Module {
    const opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "formats", .module = formatsModule(b, target, optimize) }, .{ .name = "interfaces", .module = interfacesModule(b, target, optimize) } },
    };
    return if (public) b.addModule("render", opts) else b.createModule(opts);
}
