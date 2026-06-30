const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The engine as a reusable library module. Frontends (CLI today,
    // GUI later) import this and never reach into engine internals.
    const wstudio_mod = b.addModule("wstudio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .linux) {
        wstudio_mod.link_libc = true;
        wstudio_mod.linkSystemLibrary("asound", .{});
        // glibc's fortified wrappers (active when optimizing) break
        // zig's translate-c on @cImport of alsa headers
        wstudio_mod.addCMacro("_FORTIFY_SOURCE", "0");
    }

    const exe = b.addExecutable(.{
        .name = "wstudio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run wstudio");
    run_step.dependOn(&run_cmd.step);

    // `zig build genkit` renders the drum kit to assets/kit/*.wav. Run once
    // after editing src/dsp/drum_kit.zig, then commit the refreshed WAVs.
    const genkit = b.addExecutable(.{
        .name = "genkit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/genkit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_genkit = b.addRunArtifact(genkit);
    const genkit_step = b.step("genkit", "Render the drum kit to assets/kit/*.wav");
    genkit_step.dependOn(&run_genkit.step);

    const mod_tests = b.addTest(.{ .root_module = wstudio_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
