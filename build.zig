const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_tui = b.option(bool, "tui", "Build the terminal frontend") orelse true;
    const enable_gui = b.option(bool, "gui", "Build the graphical frontend") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "tui", enable_tui);
    build_options.addOption(bool, "gui", enable_gui);
    const init_template_mod = b.createModule(.{
        .root_source_file = b.path("examples/init_template.zig"),
    });
    const lua_dep = b.dependency("lua", .{});
    const lua = buildLua(b, lua_dep, target, optimize);

    // The engine as a reusable library module. Frontends import this and
    // never reach into engine internals.
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

    const win32_icon: ?std.Build.Module.RcSourceFile = if (target.result.os.tag == .windows)
        .{ .file = b.path("assets/icon/wstudio.rc") }
    else
        null;

    const exe = b.addExecutable(.{
        .name = "wstudio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "init_template", .module = init_template_mod },
            },
        }),
    });
    exe.root_module.addIncludePath(lua_dep.path("src/"));
    exe.root_module.linkLibrary(lua);
    if (win32_icon) |icon| exe.root_module.addWin32ResourceFile(icon);
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

    if (enable_gui) {
        // Both Linux backends compile in (zglfw vendors the generated
        // wayland protocol headers); GLFW picks at runtime and every
        // platform library is dlopened, not linked - see the runtime rpath
        // in flake.nix.
        const zglfw = b.dependency("zglfw", .{
            .target = target,
            .optimize = optimize,
            .wayland = true,
        });
        const zgui = b.dependency("zgui", .{
            .target = target,
            .optimize = optimize,
            .backend = .glfw_opengl3,
            .with_implot = true,
            .use_wchar32 = true,
        });
        zgui.artifact("imgui").root_module.addCMacro("GLFW_INCLUDE_NONE", "1");
        const zopengl = b.dependency("zopengl", .{});
        exe.root_module.addImport("zglfw", zglfw.module("root"));
        exe.root_module.addImport("zgui", zgui.module("root"));
        exe.root_module.addImport("zopengl", zopengl.module("root"));
        exe.root_module.linkLibrary(zglfw.artifact("glfw"));
        exe.root_module.linkLibrary(zgui.artifact("imgui"));
    }

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

    // `zig build stretch-demo` renders fixed test clips through
    // Pad.stretch_ratio at a handful of settings to zig-out/stretch-demo/ for
    // a manual listening pass - see tools/gen_stretch_demo.zig.
    const stretch_demo = b.addExecutable(.{
        .name = "gen-stretch-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_stretch_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_stretch_demo = b.addRunArtifact(stretch_demo);
    const stretch_demo_step = b.step("stretch-demo", "Render stretch_ratio test clips to zig-out/stretch-demo/*.wav");
    stretch_demo_step.dependOn(&run_stretch_demo.step);

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

    const clap_test_plugin = b.addLibrary(.{
        .name = "wstudio-clap-test",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clap/test_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const clap_integration_test = b.addExecutable(.{
        .name = "clap-integration-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clap/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_clap_integration_test = b.addRunArtifact(clap_integration_test);
    run_clap_integration_test.addArtifactArg(clap_test_plugin);
    test_step.dependOn(&run_clap_integration_test.step);

    const check_step = b.step("check", "Build wstudio and run all tests");
    check_step.dependOn(&exe.step);
    check_step.dependOn(test_step);
}

fn buildLua(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lua = b.addLibrary(.{
        .name = "lua",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lua.root_module.addIncludePath(dep.path("src/"));
    lua.root_module.addCSourceFiles(.{
        .root = dep.path("src/"),
        .files = &.{
            "lapi.c",    "lauxlib.c",  "lbaselib.c", "lcode.c",    "lcorolib.c", "lctype.c",
            "ldblib.c",  "ldebug.c",   "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
            "linit.c",   "liolib.c",   "llex.c",     "lmathlib.c", "lmem.c",     "loadlib.c",
            "lobject.c", "lopcodes.c", "loslib.c",   "lparser.c",  "lstate.c",   "lstring.c",
            "lstrlib.c", "ltable.c",   "ltablib.c",  "ltm.c",      "lundump.c",  "lutf8lib.c",
            "lvm.c",     "lzio.c",
        },
    });
    return lua;
}
