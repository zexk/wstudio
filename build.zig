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
    if (target.result.os.tag == .windows) {
        wstudio_mod.link_libc = true;
        // CoCreateInstance/CoInitializeEx/CoUninitialize for the WASAPI
        // backend; kernel32/user32 are linked by default.
        wstudio_mod.linkSystemLibrary("ole32", .{});
        // mingw's fortified wrappers (active when optimizing) break zig's
        // translate-c on @cImport of windows.h, same as glibc's above.
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
    // The frontend's own module reaches OS-specific code too (the terminal
    // backend, tui/terminal_windows.zig on Windows) via tui/app.zig - not
    // through the wstudio import - so it needs the same linking/macros.
    if (target.result.os.tag == .windows) {
        exe.root_module.link_libc = true;
        exe.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run wstudio");
    run_step.dependOn(&run_cmd.step);

    // GUI prototype. Kept as a separate artifact so the stable TUI and its
    // dependency surface remain unchanged while the desktop frontend evolves.
    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
        .wayland = false,
    });
    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_opengl3,
        .with_implot = true,
    });
    zgui.artifact("imgui").root_module.addCMacro("GLFW_INCLUDE_NONE", "1");
    const zopengl = b.dependency("zopengl", .{});
    const gui_exe = b.addExecutable(.{
        .name = "wstudio-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
                .{ .name = "zglfw", .module = zglfw.module("root") },
                .{ .name = "zgui", .module = zgui.module("root") },
                .{ .name = "zopengl", .module = zopengl.module("root") },
            },
        }),
    });
    gui_exe.root_module.linkLibrary(zglfw.artifact("glfw"));
    gui_exe.root_module.linkLibrary(zgui.artifact("imgui"));
    const install_gui = b.addInstallArtifact(gui_exe, .{});
    const gui_check_step = b.step("gui-check", "Build the experimental GUI frontend");
    gui_check_step.dependOn(&gui_exe.step);
    const gui_install_step = b.step("gui-install", "Install the experimental GUI frontend");
    gui_install_step.dependOn(&install_gui.step);
    const run_gui_cmd = b.addRunArtifact(gui_exe);
    run_gui_cmd.step.dependOn(&install_gui.step);
    if (b.args) |args| run_gui_cmd.addArgs(args);
    const gui_step = b.step("gui", "Run the experimental GLFW + ImGui frontend");
    gui_step.dependOn(&run_gui_cmd.step);

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

    // `zig build genwavetable` renders the default wavetable to
    // assets/wavetable/basic_shapes.wav. Run once after editing the shape
    // math in tools/genwavetable.zig, then commit the refreshed WAV.
    const genwavetable = b.addExecutable(.{
        .name = "genwavetable",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/genwavetable.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_genwavetable = b.addRunArtifact(genwavetable);
    const genwavetable_step = b.step("genwavetable", "Render the default wavetable to assets/wavetable/basic_shapes.wav");
    genwavetable_step.dependOn(&run_genwavetable.step);

    // `zig build gendemo` writes the curated, fully arranged demo song to
    // demo.wsj. Run once after editing tools/gendemo.zig, then commit the
    // refreshed demo.wsj.
    const gendemo = b.addExecutable(.{
        .name = "gendemo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gendemo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_gendemo = b.addRunArtifact(gendemo);
    const gendemo_step = b.step("gendemo", "Write the demo project to demo.wsj");
    gendemo_step.dependOn(&run_gendemo.step);

    // `zig build install-font` writes the TUI's bundled icon font to the
    // user's font directory (see tools/install_font.zig for why it's needed).
    const install_font = b.addExecutable(.{
        .name = "install-font",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/install_font.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_install_font = b.addRunArtifact(install_font);
    const install_font_step = b.step("install-font", "Install the TUI's icon font for your user");
    install_font_step.dependOn(&run_install_font.step);

    const mod_tests = b.addTest(.{ .root_module = wstudio_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const check_step = b.step("check", "Build wstudio and run all tests");
    check_step.dependOn(&exe.step);
    check_step.dependOn(test_step);
}
