//! Experimental desktop frontend entry point. The engine remains
//! frontend-neutral; this file owns only the GLFW/ImGui lifecycle, font
//! setup, the audio host, and the frame/reload loop. Application state and
//! view dispatch live in app.zig; per-view rendering in views/<name>.zig.

const std = @import("std");
const ws = @import("wstudio");
const config_mod = @import("../config.zig");
const tui_app = @import("../tui/app.zig");
const app_mod = @import("app.zig");
const gui_style = @import("style.zig");
const glfw = @import("zglfw");
const zgui = @import("zgui");
const zopengl = @import("zopengl");

const App = app_mod.App;
const gl = zopengl.bindings;
const patina = &gui_style.palette;

const icon_glyph_ranges = [_]zgui.Wchar{
    0xec1a,  0xec1a,  0xee32,  0xee32,  0xef9d,  0xef9d,
    0xf005,  0xf005,  0xf025,  0xf025,  0xf04b,  0xf04d,
    0xf071,  0xf071,  0xf0c7,  0xf0c7,  0xf1de,  0xf1de,
    0xf02d7, 0xf02d7, 0xf0547, 0xf0547, 0xf075f, 0xf075f,
    0xf07da, 0xf07da, 0xf0bd1, 0xf0bd1, 0xf0ea2, 0xf0ea2,
    0,
};

fn guiAudio(sample_rate: u32, block_frames: u32, engine: *ws.Engine) ws.AudioHost {
    return ws.AudioHost.init(
        .{ .sample_rate = sample_rate, .block_frames = block_frames },
        renderAudio,
        engine,
    );
}

// On Windows, glfw.pollEvents blocks inside the Win32 modal loop for the
// whole resize/move drag, so the main loop renders nothing until release.
// GLFW delivers refresh/size callbacks from inside that loop; rendering a
// frame there keeps the window live. zglfw doesn't wrap the refresh
// callback, so declare it against the statically linked GLFW.
extern fn glfwSetWindowRefreshCallback(*glfw.Window, ?*const fn (*glfw.Window) callconv(.c) void) ?*const fn (*glfw.Window) callconv(.c) void;

const FrameCtx = struct { window: *glfw.Window, app: *App, audio: *ws.AudioHost };
var frame_ctx: ?FrameCtx = null;

fn onWindowRefresh(_: *glfw.Window) callconv(.c) void {
    drawFrame();
}

fn onFramebufferSize(_: *glfw.Window, _: c_int, _: c_int) callconv(.c) void {
    drawFrame();
}

fn drawFrame() void {
    const ctx = frame_ctx orelse return;
    const fb = ctx.window.getFramebufferSize();
    if (fb[0] <= 0 or fb[1] <= 0) return;
    gl.viewport(0, 0, fb[0], fb[1]);
    gl.clearColor(patina.bg0[0], patina.bg0[1], patina.bg0[2], 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    zgui.backend.newFrame(@intCast(fb[0]), @intCast(fb[1]));
    ctx.app.handleShortcuts();
    ctx.app.draw(ctx.audio.label());
    zgui.backend.draw();
    ctx.window.swapBuffers();
}

pub fn run(init: std.process.Init, init_path: ?[]const u8, runtime: *config_mod.Runtime) !void {
    const user_config = runtime.config;
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    const window = try glfw.Window.create(user_config.gui_window_width, user_config.gui_window_height, "wstudio GUI prototype", null, null);
    defer window.destroy();
    window.setSizeLimits(960, 600, -1, -1);
    glfw.makeContextCurrent(window);
    glfw.swapInterval(if (user_config.gui_vsync) 1 else 0);
    try zopengl.loadCoreProfile(glfw.getProcAddress, 3, 3);

    zgui.init(init.gpa);
    defer zgui.deinit();
    configureFonts(user_config.gui_font_size);
    zgui.plot.init();
    defer zgui.plot.deinit();
    zgui.io.setConfigFlags(.{ .nav_enable_keyboard = true });
    zgui.io.setIniFilename(null);
    gui_style.selectPalette(user_config.gui_theme);
    gui_style.setTheme();
    zgui.backend.init(window);
    defer zgui.backend.deinit();

    var app = App.init(init.gpa, init.io, init_path, user_config) catch |err| {
        if (init_path) |path| std.debug.print("wstudio: cannot load '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer app.deinit();
    // Same hooks as the TUI: `wstudio.notify`/`wstudio.cmd` land on the
    // shared core, and init.lua's queued command lines flush here. The
    // command table must include Lua user commands before the flush, since
    // queued lines may invoke them.
    app.core.lua_runtime = runtime;
    app.core.rebuildCmdTable();
    runtime.app = &app.core;
    runtime.attachHost(tui_app.luaHost(&app.core));
    defer {
        runtime.host = null;
        runtime.app = null;
    }
    // A project opened on the command line loaded before the runtime
    // attached, so its event fires here, right after ConfigDone.
    if (app.core.projectPath()) |p| app.core.emitEvent(.{ .ProjectLoadPost = .{ .path = p } });
    if (init_path) |path| {
        var title_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrintZ(&title_buf, "wstudio GUI prototype - {s}", .{path})) |title| window.setTitle(title) else |_| {}
    }
    var audio = guiAudio(app.core.session.project.sample_rate, user_config.audio_block_frames, app.core.session.engine);
    try audio.start(init.io, user_config.audio_backend);
    defer audio.stop();

    frame_ctx = .{ .window = window, .app = &app, .audio = &audio };
    defer frame_ctx = null;
    _ = glfwSetWindowRefreshCallback(window, onWindowRefresh);
    _ = window.setFramebufferSizeCallback(onFramebufferSize);

    while (!window.shouldClose() and !app.core.should_quit) {
        glfw.pollEvents();
        app.core.tick(std.Io.Timestamp.now(init.io, .awake).nanoseconds);
        if (app.core.pending_reload != .none) {
            const kind = app.core.pending_reload;
            app.core.pending_reload = .none;
            const loaded: ?ws.Session = switch (kind) {
                .blank => ws.Session.initDefault(init.gpa) catch null,
                .load, .restore_backup => ws.persist.load(init.gpa, init.io, app.core.pendingReloadPath()) catch |err| blk: {
                    app.core.setStatus("cannot load '{s}': {s}", .{ app.core.pendingReloadPath(), @errorName(err) });
                    break :blk null;
                },
                .none => unreachable,
            };
            if (loaded) |session| {
                audio.stop();
                app.core.session.deinit();
                app.core.session = session;
                app.core.resetForNewSession();
                switch (kind) {
                    .load => app.core.setProjectPath(app.core.pendingReloadPath()),
                    .restore_backup => app.core.setStatus("restored from autosave backup; :write to keep it", .{}),
                    .blank => app.core.clearProjectPath(),
                    .none => unreachable,
                }
                // A blank session is a new project, not a load - no event.
                if (kind != .blank) app.core.emitEvent(.{ .ProjectLoadPost = .{ .path = app.core.pendingReloadPath() } });
                audio = guiAudio(app.core.session.project.sample_rate, user_config.audio_block_frames, app.core.session.engine);
                try audio.start(init.io, user_config.audio_backend);
            }
        }
        drawFrame();
    }

    // The main loop broke on quit/window close: the session is still alive.
    app.core.emitEvent(.QuitPre);
}

fn configureFonts(size: f32) void {
    var text_config = zgui.FontConfig.init();
    text_config.font_data_owned_by_atlas = false;
    text_config.oversample_h = 2;
    text_config.oversample_v = 2;
    const text_font = zgui.io.addFontFromMemoryWithConfig(ws.gui_font_ttf, size, text_config, null);

    var icon_config = zgui.FontConfig.init();
    icon_config.font_data_owned_by_atlas = false;
    icon_config.merge_mode = true;
    icon_config.pixel_snap_h = true;
    icon_config.pixel_snap_v = true;
    icon_config.glyph_min_advance_x = size;
    _ = zgui.io.addFontFromMemoryWithConfig(ws.icon_font_ttf, size, icon_config, &icon_glyph_ranges);
    zgui.io.setDefaultFont(text_font);
}

fn renderAudio(ctx: *anyopaque, out: []ws.types.Sample) void {
    const engine: *ws.Engine = @ptrCast(@alignCast(ctx));
    engine.process(out);
}

test {
    _ = app_mod;
}
