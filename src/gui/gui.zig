//! Experimental desktop frontend entry point. The engine remains
//! frontend-neutral; this file owns only the GLFW/ImGui lifecycle, font
//! setup, the audio host, and the frame/reload loop. Application state and
//! view dispatch live in app.zig; per-view rendering in views/<name>.zig.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const config_mod = @import("../config.zig");
const app_mod = @import("app.zig");
const gui_style = @import("style.zig");
const glfw = @import("zglfw");
const zgui = @import("zgui");
const zopengl = @import("zopengl");

const App = app_mod.App;
const gl = zopengl.bindings;
const theme = &gui_style.palette;

const icon_glyph_ranges = [_]zgui.Wchar{
    0xec1a,  0xec1a,  0xee32,  0xee32,  0xef9d,  0xef9d,
    0xf005,  0xf005,  0xf025,  0xf025,  0xf04b,  0xf04d,
    0xf071,  0xf071,  0xf0c7,  0xf0c7,  0xf1de,  0xf1de,
    0xf0190, 0xf0190, 0xf02d7, 0xf02d7, 0xf0333, 0xf0333,
    0xf0547, 0xf0547, 0xf075f, 0xf075f, 0xf07da, 0xf07da,
    0xf0bd1, 0xf0bd1, 0xf0ea2, 0xf0ea2, 0,
};

/// Keep the window title on the project that is actually open. It used to be
/// set once, from the command-line path, so it went stale the moment the
/// project changed - `:e`, `:w <newname>`, `:new`. `last`/`last_len` hold the
/// title it was last set to, so this is a string compare on an unchanged
/// frame. Comparing the built title rather than the path matters: a blank
/// session's path is empty, which used to be indistinguishable from "never
/// set" and left the window on its placeholder creation title forever.
fn syncWindowTitle(window: *glfw.Window, app: *const App, last: []u8, last_len: *usize) void {
    var title_buf: [1024]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s} - wstudio", .{app.core.projectDisplayName()}) catch return;
    if (std.mem.eql(u8, last[0..last_len.*], title)) return;
    if (title.len > last.len) return;
    @memcpy(last[0..title.len], title);
    last_len.* = title.len;
    window.setTitle(title);
}

fn guiAudio(sample_rate: u32, block_frames: u32, output_device: []const u8, engine: *ws.Engine) ws.AudioHost {
    return ws.AudioHost.init(
        .{ .sample_rate = sample_rate, .block_frames = block_frames, .output_device = output_device },
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

// zgui.backend.init installs ImGui's own GLFW char callback; replacing it
// here (glfwSetCharCallback only keeps one) means we must forward the
// codepoint to ImGui ourselves so widgets that take typed text (inputFloat,
// sliderFloat's ctrl-click edit) keep working. app_mod.pushChar stashes the
// same codepoint for the modal layer - see its doc comment for why that
// beats guessing the character from the named OEM key.
fn onChar(_: *glfw.Window, codepoint: u32) callconv(.c) void {
    const cp = std.math.cast(u21, codepoint) orelse return;
    app_mod.pushChar(cp);
    var buf: [5]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, buf[0..4]) catch return;
    buf[len] = 0;
    zgui.io.addInputCharactersUTF8(buf[0..len :0]);
}

// Same takeover-and-reforward as onChar: zgui.backend.init installs ImGui's
// own GLFW scroll callback (GLFW keeps one slot per window, so ours replaces
// it). Stash the delta until custom controls can claim it; drawFrame forwards
// unclaimed input to ImGui one frame later for list/child scrolling.
fn onScroll(_: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    gui_style.wheel_x_delta += @floatCast(xoffset);
    gui_style.wheel_delta += @floatCast(yoffset);
}

fn drawFrame() void {
    const ctx = frame_ctx orelse return;
    const fb = ctx.window.getFramebufferSize();
    if (fb[0] <= 0 or fb[1] <= 0) return;
    gl.viewport(0, 0, fb[0], fb[1]);
    gl.clearColor(theme.bg0[0], theme.bg0[1], theme.bg0[2], 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    zgui.backend.newFrame(@intCast(fb[0]), @intCast(fb[1]));
    ctx.app.handleShortcuts();
    ctx.app.draw(ctx.audio.label());
    const imgu_wheel_y: f32 = if (gui_style.wheel_consumed) 0 else gui_style.wheel_delta;
    if (gui_style.wheel_x_delta != 0 or imgu_wheel_y != 0)
        zgui.io.addMouseWheelEvent(gui_style.wheel_x_delta, imgu_wheel_y);
    gui_style.wheel_x_delta = 0;
    gui_style.wheel_delta = 0;
    gui_style.wheel_consumed = false;
    zgui.backend.draw();
    ctx.window.swapBuffers();
}

pub fn run(init: std.process.Init, init_path: ?[]const u8, runtime: *config_mod.Runtime) !void {
    var user_config = runtime.config;
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    // Placeholder only: `syncWindowTitle` replaces it with
    // "<project> - wstudio" before the first frame is presented.
    const window = try glfw.Window.create(user_config.gui_window_width, user_config.gui_window_height, "wstudio", null, null);
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
    // Keyboard nav is deliberately left off: ImGui's arrow-key widget
    // highlighting steals the same keys the modal editors bind for
    // cursor movement (h/j/k/l and the arrows), so leaving it on made
    // buttons light up instead of moving the app cursor.
    zgui.io.setIniFilename(null);
    gui_style.selectIdentity(runtime.resolvedTheme(user_config.gui_theme));
    gui_style.setTheme(user_config.gui_panel_border);
    gui_style.knob_drag_pixels = user_config.gui_knob_drag_pixels;
    gui_style.envelope_drag_pixels = user_config.gui_envelope_drag_pixels;
    gui_style.piano_row_height = user_config.gui_piano_row_height;
    gui_style.meter_decay_db_per_s = user_config.gui_meter_decay_db_s;
    zgui.backend.init(window);
    defer zgui.backend.deinit();
    // Takes over from the char/scroll callbacks zgui.backend.init just
    // installed - see onChar/onScroll's doc comments for why, and why they
    // re-forward to ImGui.
    _ = window.setCharCallback(onChar);
    _ = window.setScrollCallback(onScroll);

    // `App.init` reports an unreadable project before returning its error.
    var app = try App.init(init.gpa, init.io, init_path, user_config);
    defer app.deinit();
    app.core.scanExternalPlugins(init.environ_map);
    app.core.attachRuntime(runtime);
    defer app.core.detachRuntime(runtime);
    var title_path_buf: [1024]u8 = undefined;
    var title_path_len: usize = 0;
    syncWindowTitle(window, &app, &title_path_buf, &title_path_len);
    var audio = guiAudio(app.core.session.project.sample_rate, user_config.audio_block_frames, user_config.audio_output_device.slice(), app.core.session.engine);
    try audio.start(init.io, user_config.audio_backend);
    defer audio.stop();

    // Live MIDI input, same wiring as tui/tui.zig - a hardware keyboard
    // auditions and records here exactly as it does in the terminal. Bound
    // to the session's engine, so `:e` has to rebind it below alongside the
    // audio host. Failing to open a MIDI port is not fatal: the app runs
    // without one, same as with no audio backend.
    const has_midi = builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .windows;
    const MidiIn = if (has_midi) ws.midi_in.MidiIn else void;
    var midi_in: MidiIn = undefined;
    var using_midi = false;
    if (has_midi) {
        midi_in = .{ .engine = app.core.session.engine, .velocity_curve = .init(user_config.default_midi_velocity_curve) };
        if (midi_in.start(user_config.midi_input_device.slice())) {
            using_midi = true;
        } else |_| {}
    }
    defer if (has_midi) {
        if (using_midi) midi_in.stop();
    };

    frame_ctx = .{ .window = window, .app = &app, .audio = &audio };
    defer frame_ctx = null;
    _ = glfwSetWindowRefreshCallback(window, onWindowRefresh);
    _ = window.setFramebufferSizeCallback(onFramebufferSize);

    while (!window.shouldClose() and !app.core.should_quit) {
        glfw.pollEvents();
        if (window.shouldClose() and !app.core.requestQuit()) window.setShouldClose(false);
        app.core.tick(std.Io.Timestamp.now(init.io, .awake).nanoseconds);
        app.core.reportAudioHealth(audio.takeHealth());
        if (app.core.preparePendingReload()) |prepared| {
            audio.stop();
            // Both readers point at the engine `deinit` is about to
            // free - stop them before it, restart them on the new one.
            if (has_midi and using_midi) {
                midi_in.stop();
                using_midi = false;
            }
            app.core.installPreparedReload(prepared);
            audio = guiAudio(app.core.session.project.sample_rate, user_config.audio_block_frames, user_config.audio_output_device.slice(), app.core.session.engine);
            // A restart failure here leaves the session silent rather
            // than tearing down a running app with unsaved work in it -
            // same call as tui/tui.zig's.
            audio.start(init.io, user_config.audio_backend) catch {};
            if (has_midi) {
                midi_in = .{ .engine = app.core.session.engine, .velocity_curve = .init(user_config.default_midi_velocity_curve) };
                if (midi_in.start(user_config.midi_input_device.slice())) {
                    using_midi = true;
                } else |_| {}
            }
        }
        // `:reload-config` - re-source init.lua and re-apply whatever it
        // changed that startup only set up once. `audio_backend`/
        // `audio_block_frames`/`gui_font_size`/`gui_window_*` deliberately
        // aren't among these (font atlas rebuilds and backend restarts are
        // out of scope for a rare, frame-loop-triggered reload) - see
        // tui/tui.zig's matching block for the same call.
        if (app.core.pending_config_reload) {
            app.core.pending_config_reload = false;
            const reloaded = app.core.reloadConfig(runtime);
            user_config = runtime.config;
            if (reloaded) {
                gui_style.selectIdentity(runtime.resolvedTheme(user_config.gui_theme));
                gui_style.setTheme(user_config.gui_panel_border);
                gui_style.knob_drag_pixels = user_config.gui_knob_drag_pixels;
                gui_style.envelope_drag_pixels = user_config.gui_envelope_drag_pixels;
                gui_style.piano_row_height = user_config.gui_piano_row_height;
                gui_style.meter_decay_db_per_s = user_config.gui_meter_decay_db_s;
                glfw.swapInterval(if (user_config.gui_vsync) 1 else 0);
                if (has_midi and using_midi) midi_in.velocity_curve.store(user_config.default_midi_velocity_curve, .monotonic);
            }
        }
        // `:colorscheme` - narrower than the block above: `cmdColorscheme`
        // already wrote the new `gui_theme` into `runtime.config`, this
        // just repaints from it.
        if (app.core.pending_colorscheme) {
            app.core.pending_colorscheme = false;
            user_config.gui_theme = runtime.config.gui_theme;
            gui_style.selectIdentity(runtime.resolvedTheme(user_config.gui_theme));
            gui_style.setTheme(user_config.gui_panel_border);
        }

        syncWindowTitle(window, &app, &title_path_buf, &title_path_len);

        if (has_midi and using_midi) {
            app.core.serviceMidiInput(&midi_in);
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
    engine.renderRealtime(out);
}

test {
    _ = app_mod;
}
