const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const macos_sdk = if (target.result.os.tag == .macos) b.graph.environ_map.get("SDKROOT") else null;
    // A macOS target that is not this machine: zig only auto-detects an SDK
    // for the native case, so everything else has to be pointed at one.
    const macos_cross = target.result.os.tag == .macos and
        (b.graph.host.result.os.tag != .macos or target.result.cpu.arch != b.graph.host.result.cpu.arch);
    if (b.graph.host.result.os.tag != .macos) {
        if (macos_sdk) |sdk| b.sysroot = sdk;
    }
    const enable_tui = b.option(bool, "tui", "Build the terminal frontend") orelse true;
    const enable_gui = b.option(bool, "gui", "Build the graphical frontend") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "tui", enable_tui);
    build_options.addOption(bool, "gui", enable_gui);
    const init_template_mod = b.createModule(.{
        .root_source_file = b.path("examples/init_template.zig"),
    });
    // Cross-compiling is the one case where a C library cannot come from nix:
    // nixpkgs refuses to build Lua for mingw, and `make mingw` inside it fails
    // even when that refusal is overridden. So the host build links nix's Lua
    // and a cross build falls back to the source drop in build.zig.zon.
    // Architecture counts, not just the OS: the release workflow builds
    // x86_64-macos on an Apple Silicon runner, and the host's libraries are
    // the wrong machine code for it.
    const cross_compiling = target.result.os.tag != b.graph.host.result.os.tag or
        target.result.cpu.arch != b.graph.host.result.cpu.arch;

    // The engine as a reusable library module. Frontends import this and
    // never reach into engine internals.
    const wstudio_mod = b.addModule("wstudio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Sample decoding (core/audio_file.zig) and sinc resampling for sample
    // loads (dsp/pad.zig). System libraries, like asound below: nix supplies
    // them through buildInputs, and zig picks the paths up from
    // NIX_CFLAGS_COMPILE/NIX_LDFLAGS. Those variables describe the *host*
    // though, so a cross-compiled target is handed its own prefix instead -
    // flake.nix exports it the way it already exports SDKROOT for macOS.
    // Rubber Band (dsp/pitch_shift.zig) joins them: C++ inside, so its own
    // runtime comes along through the shared library's dependencies.
    const target_prefix = if (cross_compiling) b.graph.environ_map.get("WSTUDIO_TARGET_PREFIX") else null;
    if (target_prefix) |prefix| {
        wstudio_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        wstudio_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        // pkg-config in a cross build answers for the host, and its `-I` would
        // put the host's headers ahead of the prefix's.
        wstudio_mod.linkSystemLibrary("speexdsp", .{ .preferred_link_mode = .static, .use_pkg_config = .no });
        if (target.result.os.tag == .windows) {
            // mingw builds a DLL plus a `libfoo.dll.a` import library, and
            // zig's system-library search only looks for `foo.dll`, `foo.lib`
            // and `libfoo.a` - so the import library goes to the linker
            // directly. The release archive ships the matching DLLs.
            wstudio_mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", "libsndfile.dll.a" }) });
            // The C-only import library, not the full one: see flake.nix.
            wstudio_mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", "librubberband-c.dll.a" }) });
        } else {
            wstudio_mod.linkSystemLibrary("sndfile", .{ .use_pkg_config = .no });
            wstudio_mod.linkSystemLibrary("rubberband", .{ .use_pkg_config = .no });
        }
    } else {
        wstudio_mod.linkSystemLibrary("sndfile", .{});
        wstudio_mod.linkSystemLibrary("rubberband", .{});
        // Static, so a downloaded build does not need the user to have
        // installed it. libsndfile stays dynamic: static would drag in its
        // whole codec chain (FLAC, ogg, vorbis, opus, mpg123, lame) by hand.
        wstudio_mod.linkSystemLibrary("speexdsp", .{ .preferred_link_mode = .static });
    }
    // Needed on every target for the two C libraries above, not just the two
    // targets that link a system audio API.
    wstudio_mod.link_libc = true;
    if (target.result.os.tag == .linux) {
        wstudio_mod.linkSystemLibrary("asound", .{});
        // glibc's fortified wrappers (active when optimizing) break
        // zig's translate-c on @cImport of alsa headers
        wstudio_mod.addCMacro("_FORTIFY_SOURCE", "0");
    }
    if (target.result.os.tag == .windows) {
        // CoCreateInstance/CoInitializeEx/CoUninitialize for the WASAPI
        // backend; kernel32/user32 are linked by default.
        wstudio_mod.linkSystemLibrary("ole32", .{});
        wstudio_mod.linkSystemLibrary("winmm", .{});
        // mingw's fortified wrappers (active when optimizing) break zig's
        // translate-c on @cImport of windows.h, same as glibc's above.
        wstudio_mod.addCMacro("_FORTIFY_SOURCE", "0");
    }
    if (target.result.os.tag == .macos) {
        wstudio_mod.linkFramework("AudioUnit", .{});
        wstudio_mod.linkFramework("CoreAudio", .{});
        wstudio_mod.linkFramework("CoreMIDI", .{});
        wstudio_mod.linkFramework("CoreFoundation", .{});
        if (macos_sdk) |sdk| addMacosFrameworkPath(b, wstudio_mod, sdk, macos_cross);
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
    if (macos_sdk) |sdk| addMacosFrameworkPath(b, exe.root_module, sdk, macos_cross);
    // src/config.zig is the only Lua caller, and it lives in this module.
    exe.root_module.link_libc = true;
    if (cross_compiling) {
        const lua_dep = b.dependency("lua", .{});
        exe.root_module.addIncludePath(lua_dep.path("src/"));
        exe.root_module.linkLibrary(buildLua(b, lua_dep, target, optimize));
    } else {
        exe.root_module.linkSystemLibrary("lua", .{ .preferred_link_mode = .static });
    }
    if (win32_icon) |icon| exe.root_module.addWin32ResourceFile(icon);
    // The frontend's own module reaches OS-specific code too (the terminal
    // backend, tui/terminal_windows.zig on Windows) via tui/app.zig - not
    // through the wstudio import - so it needs the same linking/macros.
    if (target.result.os.tag == .windows) {
        exe.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    }
    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("src/assets/library"),
        .install_dir = .prefix,
        .install_subdir = "share/wstudio/library",
    });

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
        const glfw = zglfw.artifact("glfw");
        if (macos_sdk) |sdk| {
            addMacosFrameworkPath(b, glfw.root_module, sdk, macos_cross);
            addMacosFrameworkPath(b, zgui.artifact("imgui").root_module, sdk, macos_cross);
        }
        if (target.result.os.tag == .linux) {
            // zglfw adds X11 as a link input to its static archive. Zig 0.16
            // then stores the resolved libX11.so path as an archive member,
            // which LLD correctly rejects as neither an object nor bitcode.
            // GLFW resolves X11 through dlopen, so discard that unnecessary
            // static-library link input until zglfw stops attaching it.
            removeSystemLibrary(glfw.root_module, "X11");
        }
        exe.root_module.addImport("zglfw", zglfw.module("root"));
        exe.root_module.addImport("zgui", zgui.module("root"));
        exe.root_module.addImport("zopengl", zopengl.module("root"));
        exe.root_module.linkLibrary(glfw);
        exe.root_module.linkLibrary(zgui.artifact("imgui"));
    }

    // `zig build genwavetable` renders bundled wavetables. Run once after
    // editing tools/genwavetable.zig, then commit refreshed WAV files.
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
    const genwavetable_step = b.step("genwavetable", "Render bundled wavetables to assets/wavetable/");
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

    const soak = b.addExecutable(.{
        .name = "soak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/soak.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_soak = b.addRunArtifact(soak);
    if (b.args) |args| run_soak.addArgs(args) else run_soak.addArg("demo.wsj");
    const soak_step = b.step("soak", "Run one-hour simulated playback plus save/load/export soak");
    soak_step.dependOn(&run_soak.step);

    // Not part of `zig build test`: it needs a sample corpus on disk that is
    // far too large to ship, so it stays an on-demand check.
    const dspcheck = b.addExecutable(.{
        .name = "dspcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dspcheck.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_dspcheck = b.addRunArtifact(dspcheck);
    if (b.args) |args| run_dspcheck.addArgs(args) else run_dspcheck.addArg("work/audio_refs");
    const dspcheck_step = b.step("dspcheck", "Run a directory of real audio files through decode/detect/render/FX");
    dspcheck_step.dependOn(&run_dspcheck.step);

    // demo.wsj lives above the module root, so no Zig test can @embedFile it;
    // this tiny loader stands in for one and joins `zig build test` below.
    const checkdemo = b.addExecutable(.{
        .name = "checkdemo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/checkdemo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_checkdemo = b.addRunArtifact(checkdemo);
    run_checkdemo.addFileArg(b.path("demo.wsj"));

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
    if (target.result.os.tag == .windows) {
        install_font.root_module.link_libc = true;
        install_font.root_module.linkSystemLibrary("advapi32", .{});
        install_font.root_module.linkSystemLibrary("gdi32", .{});
    }
    const run_install_font = b.addRunArtifact(install_font);
    const install_font_step = b.step("install-font", "Install the TUI's icon font for your user");
    install_font_step.dependOn(&run_install_font.step);

    // The sandboxed-plugin child process (see src/plugin_host/). Installed
    // alongside the main binary so `plugin_host/bridge.zig` can find it via
    // `std.process.executableDirPathAlloc` at the same install prefix.
    const plugin_bridge = b.addExecutable(.{
        .name = "wstudio-plugin-bridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plugin_host/child_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const install_plugin_bridge = b.addInstallArtifact(plugin_bridge, .{});
    b.getInstallStep().dependOn(&install_plugin_bridge.step);
    // Every run/test binary below executes straight out of `.zig-cache`, not
    // the installed prefix, so `bridge.zig`'s default sibling-of-the-running-
    // exe lookup (right for a real `zig-out/bin` deployment) can't find
    // `wstudio-plugin-bridge` - it lives in a different cache-hash directory
    // entirely. Point every one of them at the installed copy instead via
    // `WSTUDIO_PLUGIN_BRIDGE_EXE`, which `Bridge.spawn` checks first.
    const plugin_bridge_path = b.getInstallPath(.bin, plugin_bridge.out_filename);
    run_cmd.step.dependOn(&install_plugin_bridge.step);
    run_cmd.setEnvironmentVariable("WSTUDIO_PLUGIN_BRIDGE_EXE", plugin_bridge_path);

    // `-Dtest-filter=<substring>` narrows both unit-test binaries to the
    // tests whose name contains it, and drops the integration executables
    // (checkdemo, the CLAP/VST3 harnesses) from the `test` step, since they
    // are whole programs with no test names to filter. A full run is minutes;
    // this makes iterating on one test seconds. Never set in CI.
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this substring");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const mod_tests = b.addTest(.{ .root_module = wstudio_mod, .filters = test_filters });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.step.dependOn(&install_plugin_bridge.step);
    run_mod_tests.setEnvironmentVariable("WSTUDIO_PLUGIN_BRIDGE_EXE", plugin_bridge_path);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(&install_plugin_bridge.step);
    run_exe_tests.setEnvironmentVariable("WSTUDIO_PLUGIN_BRIDGE_EXE", plugin_bridge_path);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    if (test_filter == null) test_step.dependOn(&run_checkdemo.step);

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
    run_clap_integration_test.step.dependOn(&install_plugin_bridge.step);
    run_clap_integration_test.setEnvironmentVariable("WSTUDIO_PLUGIN_BRIDGE_EXE", plugin_bridge_path);
    if (test_filter == null) test_step.dependOn(&run_clap_integration_test.step);

    // Drives `Bridge` directly against the same CLAP test plugin, killing
    // (SIGKILL) or freezing (SIGSTOP) the child process from outside to
    // prove a crashed/hung plugin degrades to silence instead of hanging
    // or taking this process down - see plugin_host/crash_hang_test.zig.
    const crash_hang_test = b.addExecutable(.{
        .name = "plugin-crash-hang-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plugin_host/crash_hang_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_crash_hang_test = b.addRunArtifact(crash_hang_test);
    run_crash_hang_test.addArtifactArg(clap_test_plugin);
    run_crash_hang_test.step.dependOn(&install_plugin_bridge.step);
    run_crash_hang_test.setEnvironmentVariable("WSTUDIO_PLUGIN_BRIDGE_EXE", plugin_bridge_path);
    if (test_filter == null) test_step.dependOn(&run_crash_hang_test.step);

    const vst3_test_plugin = b.addLibrary(.{
        .name = "wstudio-vst3-test",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vst3/test_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const vst3_integration_test = b.addExecutable(.{
        .name = "vst3-integration-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vst3/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wstudio", .module = wstudio_mod },
            },
        }),
    });
    const run_vst3_integration_test = b.addRunArtifact(vst3_integration_test);
    // Persistence reopens the saved bundle path, so fixture needs the same
    // on-disk layout as a distributed VST3 bundle on every platform.
    const module_relative = switch (target.result.os.tag) {
        .linux => b.fmt("Contents/{s}-linux/wstudio-test.so", .{@tagName(target.result.cpu.arch)}),
        .windows => b.fmt("Contents/{s}-win/wstudio-test.vst3", .{@tagName(target.result.cpu.arch)}),
        .macos => "Contents/MacOS/wstudio-test",
        else => unreachable,
    };
    const wf = b.addWriteFiles();
    const module = wf.addCopyFile(vst3_test_plugin.getEmittedBin(), b.pathJoin(&.{ "wstudio-test.vst3", module_relative }));
    run_vst3_integration_test.addFileArg(module);
    run_vst3_integration_test.addDirectoryArg(wf.getDirectory().path(b, "wstudio-test.vst3"));
    run_vst3_integration_test.step.dependOn(&install_plugin_bridge.step);
    run_vst3_integration_test.setEnvironmentVariable("WSTUDIO_PLUGIN_BRIDGE_EXE", plugin_bridge_path);
    if (test_filter == null) test_step.dependOn(&run_vst3_integration_test.step);

    const check_step = b.step("check", "Build wstudio and run all tests");
    check_step.dependOn(&exe.step);
    check_step.dependOn(test_step);
}

fn addMacosFrameworkPath(b: *std.Build, module: *std.Build.Module, sdk: []const u8, cross: bool) void {
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    // Only a native build gets the SDK's headers for free. Cross-compiling
    // leaves framework headers that reach for plain system ones
    // (Security.framework wants libDER) with nothing to resolve against.
    if (cross) module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
}

fn removeSystemLibrary(module: *std.Build.Module, name: []const u8) void {
    var i: usize = module.link_objects.items.len;
    while (i > 0) {
        i -= 1;
        const remove = switch (module.link_objects.items[i]) {
            .system_lib => |lib| std.mem.eql(u8, lib.name, name),
            else => false,
        };
        if (remove) _ = module.link_objects.orderedRemove(i);
    }
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
