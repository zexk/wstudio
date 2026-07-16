//! Experimental desktop frontend. The engine remains frontend-neutral; this
//! file owns only GLFW/ImGui lifecycle and GUI-specific presentation state.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const config_mod = @import("../config.zig");
const tui_app = @import("../tui/app.zig");
const tui_cmd = @import("../tui/cmd.zig");
const tui_commands = @import("../tui/commands.zig");
const tui = @import("../tui/tui.zig");
const icons = @import("../tui/icons.zig");
const automation_ed = @import("../tui/editors/automation.zig");
const piano_ed = @import("../tui/editors/piano.zig");
const spectrum_ed = @import("../tui/editors/spectrum.zig");
const synth_ed = @import("../tui/editors/synth.zig");
const synth_layout = @import("../tui/synth_layout.zig");
const gui_style = @import("style.zig");
const automation_view = @import("views/automation.zig");
const file_browser_view = @import("views/file_browser.zig");
const fx_view = @import("views/fx.zig");
const help_view = @import("views/help.zig");
const picker_view = @import("views/picker.zig");
const sampler_view = @import("views/sampler.zig");
const slicer_view = @import("views/slicer.zig");
const step_grid = @import("views/step_grid.zig");
const widgets = @import("widgets.zig");
const glfw = @import("zglfw");
const zgui = @import("zgui");
const zopengl = @import("zopengl");

const gl = zopengl.bindings;
const color = gui_style.color;
const rgb = gui_style.rgb;
const trackColor = gui_style.trackColor;
const patina = &gui_style.palette;

const icon_glyph_ranges = [_]zgui.Wchar{
    0xec1a,  0xec1a,  0xee32,  0xee32,  0xef9d,  0xef9d,
    0xf005,  0xf005,  0xf025,  0xf025,  0xf04b,  0xf04d,
    0xf071,  0xf071,  0xf0c7,  0xf0c7,  0xf1de,  0xf1de,
    0xf02d7, 0xf02d7, 0xf0547, 0xf0547, 0xf075f, 0xf075f,
    0xf07da, 0xf07da, 0xf0bd1, 0xf0bd1, 0xf0ea2, 0xf0ea2,
    0,
};

const PianoMouseEdit = struct {
    kind: enum { move, resize },
    source_pitch: u7,
    source_step: u16,
    grab_step_offset: u16 = 0,
};

pub const App = struct {
    core: tui_app.App,
    picker_return_view: tui_app.AppView = .tracks,
    arrangement_clip: ?struct { track: usize, clip: usize } = null,
    piano_top_pitch: u7 = 84,
    piano_mouse_edit: ?PianoMouseEdit = null,
    eq_drag_band: ?u8 = null,
    eq_analyzer_key: ?u32 = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8, user_config: config_mod.Config) !App {
        var core = try tui_app.App.initWithSampleRate(allocator, io, user_config.default_sample_rate);
        errdefer core.deinit();
        if (init_path) |path| {
            const session = try ws.persist.load(allocator, io, path);
            core.session.deinit();
            core.session = session;
            core.setProjectPath(path);
        }
        core.applyUserConfig(user_config, init_path == null);
        return .{ .core = core };
    }

    fn deinit(self: *App) void {
        self.core.deinit();
    }

    fn draw(self: *App, audio_label: []const u8) void {
        self.clampTrackCursor();
        if (self.core.view != .piano_roll) self.piano_mouse_edit = null;
        drawTransport(self, audio_label);
        drawWorkspace(self);
        drawStatus(self);
        drawCommandPrompt(self);
    }

    fn handleShortcuts(self: *App) void {
        if (zgui.isAnyItemActive()) return;
        if (zgui.isKeyPressed(.f1, false)) {
            self.core.handleKey(.{ .char = '?' }, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
            return;
        }
        if (pressedModalKey(self.core.modal.mode)) |key| {
            self.core.handleKey(key, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
            self.clampTrackCursor();
        }
    }

    fn clampTrackCursor(self: *App) void {
        if (self.core.view != .tracks) return;
        const clamped = guiTrackCursor(self.core.cursor, self.core.session.project.tracks.items.len);
        if (clamped == self.core.cursor) return;
        self.core.cursor = clamped;
        self.core.invalidateTrackRow();
    }

    pub fn openPicker(self: *App, picker: tui_app.AppView) void {
        if (!isPicker(picker)) return;
        if (!isPicker(self.core.view)) self.picker_return_view = self.core.view;
        if (picker == .fx_picker) self.core.fx_picker_return = self.picker_return_view;
        self.core.view = picker;
    }

    pub fn closePicker(self: *App, destination: ?tui_app.AppView) void {
        self.core.view = destination orelse self.picker_return_view;
    }
};

fn guiTrackCursor(cursor: usize, track_count: usize) usize {
    if (track_count == 0) return 0;
    return @min(cursor, track_count - 1);
}

test "GUI tracks cursor excludes the TUI master sentinel" {
    try std.testing.expectEqual(@as(usize, 3), guiTrackCursor(4, 4));
    try std.testing.expectEqual(@as(usize, 3), guiTrackCursor(3, 4));
    try std.testing.expectEqual(@as(usize, 0), guiTrackCursor(1, 0));
}

test "GUI status text strips terminal styling" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(" N   1/5  oct 4", stripAnsi("\x1b[42m\x1b[30m N \x1b[0m  \x1b[2m1/5  oct \x1b[0m4", &out));
}

fn isPicker(view: tui_app.AppView) bool {
    return view == .instrument_picker or view == .fx_picker or view == .preset_picker;
}

fn workspaceView(app: *const App) tui_app.AppView {
    return if (isPicker(app.core.view)) app.picker_return_view else app.core.view;
}

fn pressedModalKey(_: ws.input.Mode) ?ws.input.Key {
    const ctrl = zgui.isKeyDown(.mod_ctrl);
    if (ctrl and zgui.isKeyPressed(.c, false)) return .ctrl_c;
    if (ctrl and zgui.isKeyPressed(.r, false)) return .ctrl_r;
    if (ctrl and zgui.isKeyPressed(.w, false)) return .ctrl_w;
    const special = [_]struct { gui: zgui.Key, modal: ws.input.Key }{
        .{ .gui = .escape, .modal = .escape },
        .{ .gui = .enter, .modal = .enter },
        .{ .gui = .tab, .modal = .tab },
        .{ .gui = .back_space, .modal = .backspace },
        .{ .gui = .home, .modal = .home },
        .{ .gui = .end, .modal = .end },
        .{ .gui = .up_arrow, .modal = .arrow_up },
        .{ .gui = .down_arrow, .modal = .arrow_down },
        .{ .gui = .left_arrow, .modal = .arrow_left },
        .{ .gui = .right_arrow, .modal = .arrow_right },
    };
    for (special) |entry| if (zgui.isKeyPressed(entry.gui, false)) return entry.modal;

    if (zgui.isKeyPressed(.space, false)) return .{ .char = ' ' };
    const shifted = zgui.isKeyDown(.mod_shift);
    const letters = "abcdefghijklmnopqrstuvwxyz";
    inline for (letters, 0..) |c, i| {
        const key: zgui.Key = @enumFromInt(@intFromEnum(zgui.Key.a) + i);
        if (zgui.isKeyPressed(key, false)) return .{ .char = if (shifted) std.ascii.toUpper(c) else c };
    }
    const digits = "0123456789";
    inline for (digits, 0..) |c, i| {
        const key: zgui.Key = @enumFromInt(@intFromEnum(zgui.Key.zero) + i);
        if (zgui.isKeyPressed(key, false)) return .{ .char = c };
    }
    const punctuation = [_]struct { key: zgui.Key, plain: u8, shifted: u8 }{
        .{ .key = .apostrophe, .plain = '\'', .shifted = '"' },
        .{ .key = .comma, .plain = ',', .shifted = '<' },
        .{ .key = .minus, .plain = '-', .shifted = '_' },
        .{ .key = .period, .plain = '.', .shifted = '>' },
        .{ .key = .semicolon, .plain = ';', .shifted = ':' },
        .{ .key = .slash, .plain = '/', .shifted = '?' },
        .{ .key = .equal, .plain = '=', .shifted = '+' },
        .{ .key = .left_bracket, .plain = '[', .shifted = '{' },
        .{ .key = .back_slash, .plain = '\\', .shifted = '|' },
        .{ .key = .right_bracket, .plain = ']', .shifted = '}' },
        .{ .key = .grave_accent, .plain = '`', .shifted = '~' },
    };
    for (punctuation) |entry| if (zgui.isKeyPressed(entry.key, false))
        return .{ .char = if (shifted) entry.shifted else entry.plain };
    return null;
}

const NativeBackend = if (builtin.os.tag == .linux)
    ws.alsa.AlsaBackend
else if (builtin.os.tag == .windows)
    ws.wasapi.WasapiBackend
else
    ws.backend.NullBackend;

const GuiAudio = struct {
    native: NativeBackend,
    fallback: ws.backend.NullBackend,
    using_native: bool = false,

    fn init(sample_rate: u32, block_frames: u32, engine: *ws.Engine) GuiAudio {
        const config: ws.backend.Config = .{ .sample_rate = sample_rate, .block_frames = block_frames };
        return .{
            .native = .{ .config = config, .render = renderAudio, .ctx = engine },
            .fallback = .{ .config = config, .render = renderAudio, .ctx = engine },
        };
    }

    fn start(self: *GuiAudio, io: std.Io) !void {
        if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
            self.native.start() catch {
                try self.fallback.start(io);
                return;
            };
            self.using_native = true;
        } else {
            try self.fallback.start(io);
        }
    }

    fn stop(self: *GuiAudio) void {
        if (self.using_native) self.native.stop() else self.fallback.stop();
        self.using_native = false;
    }

    fn label(self: *const GuiAudio) []const u8 {
        if (!self.using_native) return "none (silent)";
        return if (builtin.os.tag == .linux) "alsa" else "wasapi";
    }
};

fn bodyHeight(prompt_open: bool) f32 {
    return zgui.io.getDisplaySize()[1] - 98 - @as(f32, if (prompt_open) 38 else 0);
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
    var audio = GuiAudio.init(app.core.session.project.sample_rate, user_config.audio_block_frames, app.core.session.engine);
    try audio.start(init.io);
    defer audio.stop();

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
                app.core.cursor = 0;
                switch (kind) {
                    .load => app.core.setProjectPath(app.core.pendingReloadPath()),
                    .restore_backup => app.core.setStatus("restored from autosave backup; :write to keep it", .{}),
                    .blank => app.core.clearProjectPath(),
                    .none => unreachable,
                }
                // A blank session is a new project, not a load - no event.
                if (kind != .blank) app.core.emitEvent(.{ .ProjectLoadPost = .{ .path = app.core.pendingReloadPath() } });
                audio = GuiAudio.init(app.core.session.project.sample_rate, user_config.audio_block_frames, app.core.session.engine);
                try audio.start(init.io);
            }
        }
        const fb = window.getFramebufferSize();
        if (fb[0] <= 0 or fb[1] <= 0) continue;
        gl.viewport(0, 0, fb[0], fb[1]);
        gl.clearColor(patina.bg0[0], patina.bg0[1], patina.bg0[2], 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        zgui.backend.newFrame(@intCast(fb[0]), @intCast(fb[1]));
        app.handleShortcuts();
        app.draw(audio.label());
        zgui.backend.draw();
        window.swapBuffers();
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

fn drawTransport(app: *App, audio_label: []const u8) void {
    const snap = app.core.session.engine.uiSnapshot();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = 64, .cond = .always });
    if (zgui.begin("Transport", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true, .no_scrollbar = true, .no_scroll_with_mouse = true } })) {
        const beat = ws.types.framesToSeconds(snap.position_frames, app.core.session.project.sample_rate) * app.core.session.project.tempo_bpm / 60.0;
        const beat_index: u32 = @intFromFloat(beat);
        var tempo_buf: [32]u8 = undefined;
        const tempo = std.fmt.bufPrint(&tempo_buf, "{d:.1} BPM", .{app.core.session.project.tempo_bpm}) catch "tempo";
        var position_buf: [32]u8 = undefined;
        const position = std.fmt.bufPrint(&position_buf, "{d:0>3}.{d}", .{
            beat_index / app.core.session.project.beats_per_bar + 1,
            beat_index % app.core.session.project.beats_per_bar + 1,
        }) catch "position";
        var meter_buf: [32]u8 = undefined;
        const meter = std.fmt.bufPrint(&meter_buf, "{d}/4", .{app.core.session.project.beats_per_bar}) catch "meter";
        var rate_buf: [32]u8 = undefined;
        const rate = std.fmt.bufPrint(&rate_buf, "{d:.1} kHz", .{@as(f32, @floatFromInt(app.core.session.project.sample_rate)) / 1000.0}) catch "rate";

        drawTransportReadout(icons.tempo ++ "  TEMPO", tempo, true);
        drawTransportReadout("POSITION", position, false);
        drawTransportReadout("METER", meter, false);
        drawTransportReadout("RATE", rate, false);
        drawTransportReadout(icons.save ++ "  PROJECT", app.core.session.project.name, false);
        drawTransportReadout(icons.master ++ "  AUDIO", audio_label, false);
    }
    zgui.end();
}

fn drawTransportReadout(label: []const u8, value: []const u8, first: bool) void {
    if (!first) zgui.sameLine(.{ .spacing = 24 });
    zgui.beginGroup();
    zgui.textColored(patina.fg3, "{s}", .{label});
    zgui.textColored(patina.fg0, "{s}", .{value});
    zgui.endGroup();
}

fn drawTrackBadge(draw: zgui.DrawList, x: f32, y: f32, label: []const u8, bg: [4]f32) void {
    draw.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + 15, y + 18 }, .col = color(bg), .rounding = 2 });
    draw.addText(.{ x + 4, y + 2 }, color(patina.bg0), "{s}", .{label});
}

fn drawWorkspace(app: *App) void {
    if (app.core.view != .track_spectrum and app.core.view != .master_spectrum and app.core.view != .group_spectrum and app.eq_analyzer_key != null) {
        _ = app.core.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
        app.eq_analyzer_key = null;
    }
    const body_h = bodyHeight(app.core.modal.mode == .command or app.core.modal.mode == .search);
    zgui.setNextWindowPos(.{ .x = 0, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = body_h, .cond = .always });
    if (zgui.begin("Workspace", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        switch (app.core.view) {
            .tracks => drawTrackOverview(app),
            .arrangement => drawArrangement(app),
            .piano_roll => drawPianoRoll(app),
            .drum_grid => drawDrumGrid(app),
            .slicer_grid => slicer_view.draw(app),
            .synth_editor => drawSynth(app),
            .sampler_editor => sampler_view.draw(app),
            .track_spectrum, .master_spectrum, .group_spectrum => fx_view.draw(app),
            .automation => automation_view.draw(app),
            .instrument_picker => picker_view.drawInstrument(app),
            .fx_picker, .synth_fx_picker => picker_view.drawFx(app),
            .preset_picker => picker_view.drawPreset(app),
            .automation_param_picker => automation_view.drawParamPicker(app),
            .file_browser => file_browser_view.draw(app),
            .help => help_view.draw(app),
        }
    }
    zgui.end();
}

fn drawTrackOverview(app: *App) void {
    zgui.textDisabled(icons.master ++ "  MIXER OVERVIEW", .{});
    zgui.sameLine(.{});
    zgui.textColored(patina.fg2, "{d} channels", .{app.core.session.project.tracks.items.len});
    zgui.separator();
    for (app.core.session.project.tracks.items, 0..) |track, i| {
        drawMixerRow(app, track, app.core.session.racks.items[i], i);
    }
}

fn drawMixerRow(app: *App, track: ws.Track, rack: *ws.Rack, index: usize) void {
    const height: f32 = 44;
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "mixer-row-{d}", .{index}) catch return;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const selected = app.core.cursor == index;
    const visual_anchor = app.core.tracks_visual_anchor orelse app.core.cursor;
    const in_visual = app.core.modal.mode == .visual and index >= @min(visual_anchor, app.core.cursor) and index <= @max(visual_anchor, app.core.cursor);
    const draw = zgui.getWindowDrawList();
    const accent = trackColor(track.color);
    const colored = track.color > 0 and track.color <= ws.track_color_count;
    const row_bg = if (colored) accent else if (selected) patina.bg3 else if (hovered) patina.bg2 else patina.bg1;
    const row_fg = if (colored) patina.bg0 else if (selected) patina.fg0 else patina.fg1;
    const row_muted = if (colored)
        [4]f32{ patina.bg0[0], patina.bg0[1], patina.bg0[2], 0.62 }
    else
        patina.fg3;

    draw.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height - 2 },
        .col = color(row_bg),
        .rounding = 3,
    });
    if (selected) {
        draw.addRectFilled(.{
            .pmin = .{ origin[0] + 1, origin[1] + 1 },
            .pmax = .{ origin[0] + width - 1, origin[1] + height - 3 },
            .col = color(.{ patina.focus[0], patina.focus[1], patina.focus[2], 0.18 }),
            .rounding = 2,
        });
        draw.addRect(.{
            .pmin = .{ origin[0] + 1, origin[1] + 1 },
            .pmax = .{ origin[0] + width - 1, origin[1] + height - 3 },
            .col = color(patina.focus),
            .rounding = 2,
            .thickness = 2,
        });
    } else if (in_visual or hovered) {
        draw.addRect(.{
            .pmin = origin,
            .pmax = .{ origin[0] + width, origin[1] + height - 2 },
            .col = color(if (in_visual) patina.fg0 else patina.focus),
            .rounding = 2,
            .thickness = if (in_visual) 2 else 1,
        });
    }
    draw.addText(.{ origin[0] + 13, origin[1] + 5 }, color(row_fg), "{d:0>2}  {s}", .{ index + 1, track.name });
    draw.addText(.{ origin[0] + 41, origin[1] + 23 }, color(row_muted), "{s}", .{rack.label});

    var gain_buf: [24]u8 = undefined;
    const gain = std.fmt.bufPrint(&gain_buf, "{d:.1} dB", .{track.gain_db}) catch "gain";
    var pan_buf: [24]u8 = undefined;
    const pan = if (@abs(track.pan) < 0.005)
        "C"
    else
        std.fmt.bufPrint(&pan_buf, "{c}{d:.2}", .{ if (track.pan < 0) @as(u8, 'L') else 'R', @abs(track.pan) }) catch "pan";
    draw.addText(.{ origin[0] + width - 190, origin[1] + 14 }, color(row_fg), "{s}", .{gain});
    draw.addText(.{ origin[0] + width - 112, origin[1] + 14 }, color(row_muted), "{s}", .{pan});

    var badge_x = origin[0] + width - 9;
    if (track.soloed) {
        badge_x -= 18;
        drawTrackBadge(draw, badge_x, origin[1] + 12, "S", patina.rhythm);
    }
    if (track.muted) {
        badge_x -= 18;
        drawTrackBadge(draw, badge_x, origin[1] + 12, "M", patina.danger);
    }
    if (clicked) app.core.cursor = index;
}

fn drawArrangement(app: *App) void {
    zgui.textDisabled(icons.arrangement ++ "  ARRANGEMENT", .{});
    const track_count = app.core.session.project.tracks.items.len;
    const ticks_per_beat = ws.time_grid.ticks_per_beat;
    const beats_per_bar: u32 = app.core.session.project.beats_per_bar;
    const ticks_per_bar = ws.time_grid.barTicks(app.core.session.project.beats_per_bar);
    const content_ticks = app.core.session.arrangement.lengthTicks();
    const cursor_tick = app.core.arr_cursor_bar * app.core.arr_grid.ticks();
    const cursor_bar_count = cursor_tick / ticks_per_bar + 1;
    const bar_count: u32 = @max(8, @max((content_ticks + ticks_per_bar - 1) / ticks_per_bar, cursor_bar_count));
    zgui.text("{d} tracks   {d} bars   grid {s}", .{ track_count, bar_count, app.core.arr_grid.label() });
    zgui.sameLine(.{ .spacing = 18 });
    zgui.textDisabled("click a clip to select", .{});

    const gutter_w: f32 = 132;
    const ruler_h: f32 = 30;
    const lane_h: f32 = 58;
    const available = zgui.getContentRegionAvail();
    const canvas_w = @max(420, available[0]);
    const canvas_h = ruler_h + lane_h * @as(f32, @floatFromInt(track_count));
    const origin = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton("arrangement-canvas", .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw = zgui.getWindowDrawList();
    const timeline_x = origin[0] + gutter_w;
    const timeline_w = canvas_w - gutter_w;
    const total_beats: f32 = @floatFromInt(bar_count * beats_per_bar);
    const beat_w = timeline_w / total_beats;

    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(patina.bg0) });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + ruler_h }, .col = color(patina.bg2) });

    for (0..track_count) |ti| {
        const y = origin[1] + ruler_h + @as(f32, @floatFromInt(ti)) * lane_h;
        const selected = ti == app.core.cursor;
        draw.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ timeline_x, y + lane_h }, .col = color(if (selected) patina.bg4 else patina.bg2) });
        draw.addRectFilled(.{ .pmin = .{ timeline_x, y }, .pmax = .{ origin[0] + canvas_w, y + lane_h }, .col = color(if (selected) patina.bg3 else if (ti % 2 == 0) patina.bg1 else patina.bg0) });
        draw.addText(.{ origin[0] + 10, y + 11 }, color(if (selected) patina.fg0 else patina.fg1), "{d:0>2}  {s}", .{ ti + 1, app.core.session.project.tracks.items[ti].name });
        draw.addText(.{ origin[0] + 34, y + 32 }, color(patina.fg3), "{s}", .{@tagName(app.core.session.project.tracks.items[ti].kind)});
        draw.addLine(.{ .p1 = .{ origin[0], y + lane_h }, .p2 = .{ origin[0] + canvas_w, y + lane_h }, .col = color(patina.line), .thickness = 1 });
    }

    for (0..bar_count * beats_per_bar + 1) |beat_index| {
        const x = timeline_x + @as(f32, @floatFromInt(beat_index)) * beat_w;
        const on_bar = beat_index % beats_per_bar == 0;
        draw.addLine(.{ .p1 = .{ x, if (on_bar) origin[1] else origin[1] + ruler_h }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) patina.bg5 else patina.line), .thickness = if (on_bar) 1.5 else 1 });
        if (on_bar and beat_index < bar_count * beats_per_bar) draw.addText(.{ x + 7, origin[1] + 7 }, color(patina.fg2), "{d}", .{beat_index / beats_per_bar + 1});
    }

    if (app.core.modal.mode == .visual and app.core.cursor < track_count) {
        const anchor = (app.core.arr_visual_anchor orelse app.core.arr_cursor_bar) * app.core.arr_grid.ticks();
        const lo = @min(anchor, cursor_tick);
        const hi = @max(anchor, cursor_tick) + app.core.arr_grid.ticks();
        const x1 = timeline_x + @as(f32, @floatFromInt(lo)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const x2 = timeline_x + @as(f32, @floatFromInt(hi)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const y = origin[1] + ruler_h + @as(f32, @floatFromInt(app.core.cursor)) * lane_h;
        draw.addRectFilled(.{ .pmin = .{ x1, y }, .pmax = .{ x2, y + lane_h }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.14 }) });
        draw.addRect(.{ .pmin = .{ x1 + 1, y + 1 }, .pmax = .{ x2 - 1, y + lane_h - 1 }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.6 }), .thickness = 1 });
    }

    for (app.core.session.arrangement.lanes.items, 0..) |lane, ti| {
        if (ti >= track_count) break;
        const lane_y = origin[1] + ruler_h + @as(f32, @floatFromInt(ti)) * lane_h;
        for (lane.clips.items, 0..) |clip, ci| {
            const x = timeline_x + @as(f32, @floatFromInt(clip.start_tick)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
            const clip_w = @max(8, @as(f32, @floatFromInt(clip.length_ticks)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w - 2);
            const pmin = [2]f32{ x + 1, lane_y + 5 };
            const pmax = [2]f32{ @min(x + clip_w, origin[0] + canvas_w - 1), lane_y + lane_h - 5 };
            const selected = if (app.arrangement_clip) |selection| selection.track == ti and selection.clip == ci else false;
            const clip_color: [4]f32 = switch (clip.content) {
                .melodic => .{ patina.audio[0], patina.audio[1], patina.audio[2], if (selected) 1 else 0.68 },
                .drum => .{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], if (selected) 1 else 0.68 },
            };
            draw.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = color(clip_color), .rounding = 4 });
            if (selected) draw.addRect(.{ .pmin = pmin, .pmax = pmax, .col = color(patina.fg0), .rounding = 4, .thickness = 2 });
            switch (clip.content) {
                .melodic => |melodic| {
                    draw.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(patina.fg0), "MIDI  {d}", .{melodic.notes.len});
                    var min_pitch: u7 = 127;
                    var max_pitch: u7 = 0;
                    for (melodic.notes) |note| {
                        min_pitch = @min(min_pitch, note.pitch);
                        max_pitch = @max(max_pitch, note.pitch);
                    }
                    const pitch_span: f32 = @floatFromInt(@max(12, max_pitch -| min_pitch));
                    for (melodic.notes) |note| {
                        const note_x = pmin[0] + @as(f32, @floatCast(note.start_beat / melodic.length_beats)) * (pmax[0] - pmin[0]);
                        const note_y = pmin[1] + 23 + @as(f32, @floatFromInt(max_pitch - note.pitch)) / pitch_span * 17;
                        const note_w = @max(2, @as(f32, @floatCast(note.duration_beat / melodic.length_beats)) * (pmax[0] - pmin[0]));
                        draw.addLine(.{ .p1 = .{ note_x, note_y }, .p2 = .{ @min(note_x + note_w, pmax[0] - 2), note_y }, .col = color(.{ patina.fg0[0], patina.fg0[1], patina.fg0[2], 0.72 }), .thickness = 2 });
                    }
                },
                .drum => |drum| {
                    draw.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(patina.bg0), "PATTERN {c}", .{'A' + drum.variant});
                    for (0..drum.step_count) |step| {
                        var hits: u8 = 0;
                        for (drum.pattern) |pattern| hits += @intCast((pattern >> @intCast(step)) & 1);
                        if (hits == 0) continue;
                        const hit_x = pmin[0] + (@as(f32, @floatFromInt(step)) + 0.5) / @as(f32, @floatFromInt(drum.step_count)) * (pmax[0] - pmin[0]);
                        const hit_h = @min(15, @as(f32, @floatFromInt(hits)) * 2);
                        draw.addLine(.{ .p1 = .{ hit_x, pmax[1] - 6 }, .p2 = .{ hit_x, pmax[1] - 6 - hit_h }, .col = color(.{ patina.bg0[0], patina.bg0[1], patina.bg0[2], 0.72 }), .thickness = 2 });
                    }
                },
            }
            if (clip.automation.gain.len + clip.automation.pan.len + clip.automation.synth_params.items.len > 0) draw.addText(.{ pmax[0] - 16, pmin[1] + 4 }, color(patina.modulation), "A", .{});
        }
    }

    if (app.core.cursor < track_count) {
        const cursor_x = timeline_x + @as(f32, @floatFromInt(cursor_tick)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const cursor_w = @max(2, @as(f32, @floatFromInt(app.core.arr_grid.ticks())) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w);
        const cursor_y = origin[1] + ruler_h + @as(f32, @floatFromInt(app.core.cursor)) * lane_h;
        draw.addRectFilled(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ @min(cursor_x + cursor_w, origin[0] + canvas_w - 1), cursor_y + lane_h - 1 },
            .col = color(.{ patina.focus[0], patina.focus[1], patina.focus[2], 0.16 }),
        });
        draw.addRect(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ @min(cursor_x + cursor_w, origin[0] + canvas_w - 1), cursor_y + lane_h - 1 },
            .col = color(patina.focus),
            .thickness = 2,
        });
    }

    const snap = app.core.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = ws.types.framesToSeconds(snap.position_frames, app.core.session.project.sample_rate) * app.core.session.project.tempo_bpm / 60.0;
        const x = timeline_x + @as(f32, @floatCast(play_beat)) * beat_w;
        if (x <= origin[0] + canvas_w) draw.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(patina.danger), .thickness = 2 });
    }

    if (clicked and hovered and mouse[1] >= origin[1] + ruler_h) {
        const ti = @min(track_count - 1, @as(usize, @intFromFloat((mouse[1] - origin[1] - ruler_h) / lane_h)));
        app.core.cursor = ti;
        app.arrangement_clip = null;
        if (mouse[0] >= timeline_x and ti < app.core.session.arrangement.lanes.items.len) {
            const tick: u32 = @intFromFloat((mouse[0] - timeline_x) / beat_w * @as(f32, @floatFromInt(ticks_per_beat)));
            app.core.arr_cursor_bar = tick / app.core.arr_grid.ticks();
            for (app.core.session.arrangement.lanes.items[ti].clips.items, 0..) |clip, ci| {
                if (tick >= clip.start_tick and tick < clip.start_tick + clip.length_ticks) {
                    app.arrangement_clip = .{ .track = ti, .clip = ci };
                    break;
                }
            }
        }
    }
}

fn drawPianoToolbar(app: *App) void {
    var scale_on = app.core.piano_scale != null;
    if (zgui.checkbox("SCALE", .{ .v = &scale_on })) {
        app.core.piano_scale = if (scale_on) .{} else null;
    }
    if (app.core.piano_scale) |scale| {
        zgui.sameLine(.{ .spacing = 8 });
        var root: i32 = scale.root;
        zgui.setNextItemWidth(72);
        if (zgui.combo("##piano-scale-root", .{
            .current_item = &root,
            .items_separated_by_zeros = "C\x00C#\x00D\x00D#\x00E\x00F\x00F#\x00G\x00G#\x00A\x00A#\x00B\x00",
        })) app.core.piano_scale.?.root = @intCast(root);

        zgui.sameLine(.{ .spacing = 8 });
        var kind = scale.kind;
        zgui.setNextItemWidth(112);
        if (zgui.comboFromEnum("##piano-scale-kind", &kind)) app.core.piano_scale.?.kind = kind;
    }

    zgui.sameLine(.{ .spacing = 14 });
    _ = zgui.checkbox("GHOST NOTES", .{ .v = &app.core.piano_ghost });

    zgui.sameLine(.{ .spacing = 14 });
    var triplet = app.core.piano_grid == .triplet;
    if (zgui.checkbox("TRIPLET", .{ .v = &triplet })) {
        app.core.handleKey(.{ .char = 'T' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }

    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.button("- GRID##piano-grid-down", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = 'Z' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
    zgui.sameLine(.{ .spacing = 4 });
    zgui.textColored(patina.audio, "{s}", .{app.core.piano_division.label()});
    zgui.sameLine(.{ .spacing = 4 });
    if (zgui.button("+ GRID##piano-grid-up", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = 'z' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }

    zgui.sameLine(.{ .spacing = 12 });
    if (zgui.button("- LEN##piano-len-down", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = '[' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
    zgui.sameLine(.{ .spacing = 4 });
    if (zgui.button("+ LEN##piano-len-up", .{ .h = 27 })) {
        app.core.handleKey(.{ .char = ']' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
    }
}

fn drawPianoRoll(app: *App) void {
    zgui.textDisabled(icons.synth ++ "  PIANO ROLL", .{});
    if (app.core.piano_track >= app.core.session.racks.items.len) return;
    const rack = app.core.session.racks.items[app.core.piano_track];
    const pp = if (rack.pattern_player) |*p| p else {
        zgui.textDisabled("This instrument has no melodic pattern. Choose Synth or Sampler.", .{});
        return;
    };
    zgui.text("{d} notes   {d:.1} beats", .{ pp.note_count, pp.length_beats });
    zgui.sameLine(.{ .spacing = 18 });
    zgui.textDisabled("click empty to draw   drag note to move   drag handle to resize   right-click to erase", .{});
    drawPianoToolbar(app);

    const gutter_w: f32 = 58;
    const ruler_h: f32 = 24;
    const row_h: f32 = 18;
    const row_count: usize = 37;
    const cursor_pitch: usize = app.core.piano_cursor_pitch;
    const current_top: usize = app.piano_top_pitch;
    const current_bottom = current_top -| (row_count - 1);
    if (cursor_pitch > current_top) app.piano_top_pitch = @intCast(cursor_pitch);
    if (cursor_pitch < current_bottom) app.piano_top_pitch = @intCast(@min(127, cursor_pitch + row_count - 1));
    const top_pitch: u7 = app.piano_top_pitch;
    const bottom_pitch: u7 = top_pitch -| @as(u7, @intCast(row_count - 1));
    const available = zgui.getContentRegionAvail();
    const canvas_w = @max(320, available[0]);
    const canvas_h = ruler_h + row_h * @as(f32, @floatFromInt(row_count));
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("piano-roll-canvas", .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw = zgui.getWindowDrawList();
    const grid_x = origin[0] + gutter_w;
    const grid_y = origin[1] + ruler_h;
    const grid_w = canvas_w - gutter_w;
    const beats: f32 = @floatCast(@max(1.0, pp.length_beats));
    const beat_w = grid_w / beats;

    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(patina.bg0) });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + gutter_w, origin[1] + ruler_h }, .col = color(patina.bg2) });

    for (0..row_count) |row| {
        const pitch: u7 = top_pitch - @as(u7, @intCast(row));
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        const black = isBlackKey(pitch);
        const in_scale = if (app.core.piano_scale) |scale| scale.contains(pitch) else true;
        const scale_root = if (app.core.piano_scale) |scale| pitch % 12 == scale.root else false;
        const row_color = if (!in_scale)
            patina.line_soft
        else if (scale_root)
            patina.bg3
        else if (black)
            patina.bg1
        else
            patina.bg2;
        draw.addRectFilled(.{ .pmin = .{ grid_x, y }, .pmax = .{ origin[0] + canvas_w, y + row_h }, .col = color(row_color) });
        draw.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ grid_x, y + row_h }, .col = color(if (!in_scale) patina.bg3 else if (scale_root) patina.focus else if (black) patina.bg1 else patina.fg1) });
        if (black) draw.addRectFilled(.{ .pmin = .{ origin[0], y + 1 }, .pmax = .{ origin[0] + 37, y + row_h - 1 }, .col = color(patina.bg0) });
        draw.addLine(.{ .p1 = .{ origin[0], y + row_h }, .p2 = .{ origin[0] + canvas_w, y + row_h }, .col = color(patina.line), .thickness = if (@mod(pitch, 12) == 0) 1.5 else 1 });
        var note_buf: [5]u8 = undefined;
        const note_name = ws.midi.noteName(pitch, &note_buf);
        draw.addText(.{ origin[0] + 39, y + 1 }, color(if (!in_scale) patina.fg3 else if (scale_root) patina.bg0 else if (black) patina.fg2 else patina.bg0), "{s}", .{note_name});
    }

    const steps_per_beat: usize = app.core.pianoStepsPerBeat();
    const steps: usize = @intFromFloat(@ceil(beats * @as(f32, @floatFromInt(steps_per_beat))));
    if (app.core.modal.mode == .visual) {
        const anchor = @min(@as(usize, app.core.piano_visual_anchor orelse app.core.piano_cursor_step), steps - 1);
        const cursor_step = @min(@as(usize, app.core.piano_cursor_step), steps - 1);
        const lo = @min(anchor, cursor_step);
        const hi = @max(anchor, cursor_step);
        const x1 = grid_x + @as(f32, @floatFromInt(lo)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const x2 = grid_x + @as(f32, @floatFromInt(hi + 1)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        draw.addRectFilled(.{ .pmin = .{ x1, grid_y }, .pmax = .{ x2, origin[1] + canvas_h }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.12 }) });
        draw.addRect(.{ .pmin = .{ x1 + 1, grid_y + 1 }, .pmax = .{ x2 - 1, origin[1] + canvas_h - 1 }, .col = color(.{ patina.rhythm[0], patina.rhythm[1], patina.rhythm[2], 0.55 }), .thickness = 1 });
    }
    for (0..steps + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const on_beat = step % steps_per_beat == 0;
        const on_bar = step % (steps_per_beat * app.core.session.project.beats_per_bar) == 0;
        draw.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) patina.bg5 else if (on_beat) patina.bg4 else patina.line), .thickness = if (on_bar) 2 else 1 });
        if (on_beat and step < steps) draw.addText(.{ x + 5, origin[1] + 4 }, color(patina.fg2), "{d}.{d}", .{ step / (steps_per_beat * app.core.session.project.beats_per_bar) + 1, step / steps_per_beat % app.core.session.project.beats_per_bar + 1 });
    }

    if (app.core.piano_ghost) {
        for (app.core.session.racks.items, 0..) |other_rack, track_index| {
            if (track_index == app.core.piano_track) continue;
            const ghost_pp = if (other_rack.pattern_player) |*p| p else continue;
            const accent = trackColor(app.core.session.project.tracks.items[track_index].color);
            while (!ghost_pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
            for (ghost_pp.notes[0..ghost_pp.note_count]) |note| {
                if (note.pitch < bottom_pitch or note.pitch > top_pitch) continue;
                const x = grid_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
                const width = @max(3, @as(f32, @floatCast(note.duration_beat)) * beat_w - 2);
                const y = grid_y + @as(f32, @floatFromInt(top_pitch - note.pitch)) * row_h + 3;
                const right = @min(x + width, origin[0] + canvas_w - 1);
                draw.addRectFilled(.{ .pmin = .{ x + 1, y }, .pmax = .{ right, y + row_h - 6 }, .col = color(.{ accent[0], accent[1], accent[2], 0.13 }), .rounding = 2 });
                draw.addRect(.{ .pmin = .{ x + 1, y }, .pmax = .{ right, y + row_h - 6 }, .col = color(.{ accent[0], accent[1], accent[2], 0.48 }), .rounding = 2, .thickness = 1 });
            }
            ghost_pp.notes_lock.unlock();
        }
    }

    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    for (pp.notes[0..pp.note_count]) |note| {
        if (note.pitch < bottom_pitch or note.pitch > top_pitch) continue;
        const x = grid_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
        const width = @max(3, @as(f32, @floatCast(note.duration_beat)) * beat_w - 2);
        const y = grid_y + @as(f32, @floatFromInt(top_pitch - note.pitch)) * row_h + 2;
        const right = @min(x + width, origin[0] + canvas_w - 1);
        const start_step: u16 = @intFromFloat(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
        const selected = app.core.piano_cursor_pitch == note.pitch and app.core.piano_cursor_step == start_step;
        const note_alpha = 0.62 + std.math.clamp(note.velocity, 0, 1) * 0.38;
        draw.addRectFilled(.{ .pmin = .{ x + 1, y }, .pmax = .{ right, y + row_h - 4 }, .col = color(.{ patina.audio[0], patina.audio[1], patina.audio[2], note_alpha }), .rounding = 3 });
        draw.addLine(.{ .p1 = .{ x + 3, y + 2 }, .p2 = .{ x + 3, y + row_h - 6 }, .col = color(.{ patina.fg0[0], patina.fg0[1], patina.fg0[2], 0.72 }), .thickness = 2 });
        if (selected) {
            draw.addRect(.{ .pmin = .{ x, y - 1 }, .pmax = .{ right + 1, y + row_h - 3 }, .col = color(patina.rhythm), .rounding = 3, .thickness = 2 });
            draw.addRectFilled(.{ .pmin = .{ @max(x + 2, right - 5), y + 2 }, .pmax = .{ right, y + row_h - 6 }, .col = color(patina.rhythm), .rounding = 1 });
        }
    }
    pp.notes_lock.unlock();

    if (app.core.piano_cursor_pitch >= bottom_pitch and app.core.piano_cursor_pitch <= top_pitch and app.core.piano_cursor_step < steps) {
        const cursor_x = grid_x + @as(f32, @floatFromInt(app.core.piano_cursor_step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const cursor_y = grid_y + @as(f32, @floatFromInt(top_pitch - app.core.piano_cursor_pitch)) * row_h;
        const cursor_w = beat_w / @as(f32, @floatFromInt(steps_per_beat));
        draw.addRectFilled(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ cursor_x + cursor_w - 1, cursor_y + row_h - 1 },
            .col = color(.{ patina.focus[0], patina.focus[1], patina.focus[2], 0.18 }),
            .rounding = 2,
        });
        draw.addRect(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ cursor_x + cursor_w - 1, cursor_y + row_h - 1 },
            .col = color(patina.focus),
            .rounding = 2,
            .thickness = 2,
        });
    }

    const snap = app.core.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = @mod(ws.types.framesToSeconds(snap.position_frames, app.core.session.project.sample_rate) * app.core.session.project.tempo_bpm / 60.0, pp.length_beats);
        const x = grid_x + @as(f32, @floatCast(play_beat)) * beat_w;
        draw.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(patina.danger), .thickness = 2 });
    }

    const cell_w = beat_w / @as(f32, @floatFromInt(steps_per_beat));
    const pointer_step: usize = @intFromFloat(std.math.clamp(@floor((mouse[0] - grid_x) / cell_w), 0, @as(f32, @floatFromInt(steps - 1))));
    const pointer_row: usize = @intFromFloat(std.math.clamp(@floor((mouse[1] - grid_y) / row_h), 0, @as(f32, @floatFromInt(row_count - 1))));
    const pointer_pitch: u7 = top_pitch - @as(u7, @intCast(pointer_row));

    if (hovered and mouse[0] >= grid_x and mouse[1] >= grid_y) {
        const step = pointer_step;
        const row = pointer_row;
        const x = grid_x + @as(f32, @floatFromInt(step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        draw.addRectFilled(.{ .pmin = .{ x + 1, y + 1 }, .pmax = .{ x + beat_w / @as(f32, @floatFromInt(steps_per_beat)) - 1, y + row_h - 1 }, .col = color(.{ patina.focus[0], patina.focus[1], patina.focus[2], 0.18 }), .rounding = 2 });

        const pointer_beat = @as(f64, @floatCast((mouse[0] - grid_x) / beat_w));
        if (zgui.isMouseClicked(.left)) {
            if (pianoNoteCovering(pp, pointer_pitch, pointer_beat)) |note| {
                const source_step: u16 = @intFromFloat(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
                const end_x = grid_x + @as(f32, @floatCast(note.start_beat + note.duration_beat)) * beat_w;
                app.core.piano_cursor_pitch = note.pitch;
                app.core.piano_cursor_step = source_step;
                app.piano_mouse_edit = .{
                    .kind = if (mouse[0] >= end_x - 7) .resize else .move,
                    .source_pitch = note.pitch,
                    .source_step = source_step,
                    .grab_step_offset = @intCast(pointer_step -| source_step),
                };
            } else {
                app.core.piano_cursor_pitch = pointer_pitch;
                app.core.piano_cursor_step = @intCast(pointer_step);
                app.core.handleKey(.enter, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
        } else if (zgui.isMouseClicked(.right)) {
            if (pianoNoteCovering(pp, pointer_pitch, pointer_beat)) |note| {
                app.core.piano_cursor_pitch = note.pitch;
                app.core.piano_cursor_step = @intFromFloat(@round(note.start_beat * @as(f64, @floatFromInt(steps_per_beat))));
                app.core.handleKey(.{ .char = 'x' }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
            }
        }
    }

    if (zgui.isMouseReleased(.left)) {
        if (app.piano_mouse_edit) |edit| {
            switch (edit.kind) {
                .move => {
                    const target_step: u16 = @intCast(pointer_step -| edit.grab_step_offset);
                    _ = piano_ed.moveNoteTo(&app.core, edit.source_pitch, edit.source_step, pointer_pitch, target_step);
                },
                .resize => {
                    const duration: u16 = @intCast(@max(1, pointer_step + 1 -| edit.source_step));
                    _ = piano_ed.resizeNoteSteps(&app.core, edit.source_pitch, edit.source_step, duration);
                },
            }
            app.piano_mouse_edit = null;
        }
    }
}

fn pianoNoteCovering(pp: *ws.dsp.PatternPlayer, pitch: u7, beat: f64) ?ws.dsp.pattern.Note {
    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    defer pp.notes_lock.unlock();
    for (pp.notes[0..pp.note_count]) |note| {
        if (note.pitch == pitch and beat >= note.start_beat and beat < note.start_beat + note.duration_beat) return note;
    }
    return null;
}

const isBlackKey = ws.theory.isBlackKey;

fn drawDrumGrid(app: *App) void {
    const track = app.core.drum_track;
    if (track >= app.core.session.racks.items.len) return;
    const rack = app.core.session.racks.items[track];
    const drum = switch (rack.instrument) {
        .drum_machine => |*d| d,
        else => {
            zgui.textDisabled("Select a Drum Machine track.", .{});
            return;
        },
    };
    const snap = app.core.session.engine.uiSnapshot();
    const play_step: ?usize = if (snap.playing) drum.currentStep() else null;
    drawDrumHeader(app, drum, snap.playing);
    zgui.spacing();
    step_grid.draw(
        .drum,
        drum,
        drum.pads.len,
        drum.step_count,
        play_step,
        &app.core.drum_cursor,
        if (app.core.modal.mode == .visual) app.core.drum_visual_anchor else null,
    );
}

fn drawDrumHeader(app: *App, drum: *ws.dsp.DrumMachine, playing: bool) void {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("drum-header", .{ .w = width, .h = 62 });
    const draw = zgui.getWindowDrawList();
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 62 }, .col = color(patina.bg2), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + 62 }, .col = color(if (playing) patina.danger else patina.rhythm), .rounding = 3 });
    draw.addText(.{ origin[0] + 17, origin[1] + 9 }, color(patina.fg3), "DRUM MACHINE", .{});
    draw.addText(.{ origin[0] + 17, origin[1] + 31 }, color(patina.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.drum_track].name});

    const mode = if (drum.song_mode) "SONG" else "PATTERN";
    const state = if (playing) "PLAYING" else "STOPPED";
    draw.addText(.{ origin[0] + width - 360, origin[1] + 11 }, color(if (playing) patina.danger else patina.fg2), "{s}", .{state});
    draw.addText(.{ origin[0] + width - 270, origin[1] + 11 }, color(patina.rhythm), "{s} {c}", .{ mode, 'A' + drum.variant });
    draw.addText(.{ origin[0] + width - 150, origin[1] + 11 }, color(patina.fg1), "{d} STEPS", .{drum.step_count});
    draw.addText(.{ origin[0] + width - 360, origin[1] + 34 }, color(patina.fg3), "1/{d} GRID", .{drum.steps_per_beat * 4});
    draw.addText(.{ origin[0] + width - 270, origin[1] + 34 }, color(patina.fg3), "{d:.0}% SWING", .{drum.swing.load(.monotonic)});
    draw.addText(.{ origin[0] + width - 150, origin[1] + 34 }, color(patina.fg3), "VARIANT {d}/{d}", .{ drum.variant + 1, drum.variant_count });
}

fn drawSynth(app: *App) void {
    const track = app.core.synth_track;
    if (track >= app.core.session.racks.items.len) return;
    const synth = switch (app.core.session.racks.items[track].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a Synth track.", .{});
            return;
        },
    };
    drawSynthHeader(app, synth);
    zgui.spacing();
    drawSynthTabs(app);
    zgui.spacing();
    switch (app.core.synth_subview) {
        .main => drawSynthSections(app, synth, &synth_layout.main_sections, "synth-main"),
        .mod => drawSynthSections(app, synth, &synth_layout.mod_sections, "synth-mod"),
        .fx => drawSynthFx(app, synth),
    }
}

fn drawSynthTabs(app: *App) void {
    const tabs = [_]struct { label: [:0]const u8, subview: synth_ed.Subview }{
        .{ .label = "MAIN", .subview = .main },
        .{ .label = "MODULATION", .subview = .mod },
        .{ .label = "INTERNAL FX", .subview = .fx },
    };
    for (tabs, 0..) |tab, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 5 });
        const active = app.core.synth_subview == tab.subview;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) patina.focus else patina.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) patina.bg0 else patina.fg2 });
        if (zgui.button(tab.label, .{ .w = 125, .h = 30 })) setSynthSubview(app, tab.subview);
        zgui.popStyleColor(.{ .count = 2 });
    }
}

fn setSynthSubview(app: *App, subview: synth_ed.Subview) void {
    app.core.synth_subview = subview;
    var candidates_buf: [synth_ed.max_search_candidates]synth_ed.SearchCandidate = undefined;
    for (synth_ed.searchCandidates(&app.core, &candidates_buf)) |candidate| {
        if (candidate.subview == subview) {
            app.core.synth_cursor = candidate.id;
            break;
        }
    }
}

fn drawSynthSections(app: *App, synth: *ws.dsp.PolySynth, comptime sections: []const synth_layout.SectionDef, comptime child_prefix: []const u8) void {
    const gap: f32 = 10;
    const column_w = @max(300, (zgui.getContentRegionAvail()[0] - gap) / 2);
    inline for (0..2) |column| {
        if (column > 0) zgui.sameLine(.{ .spacing = gap });
        const child_id = child_prefix ++ if (column == 0) "-left" else "-right";
        if (zgui.beginChild(child_id, .{ .w = if (column == 0) column_w else 0, .h = 0, .child_flags = .{ .border = true } })) {
            inline for (sections, 0..) |section, section_index| {
                if (section_index % 2 != column) continue;
                widgets.sectionTitle(section.title, synthSectionColor(section_index));
                inline for (section.params) |entry| {
                    inline for (0..entry.fields) |field| {
                        var label_buf: [48]u8 = undefined;
                        const id = entry.id + field;
                        drawSynthAnyParam(app, synth, id, synth_ed.paramLabel(id, &label_buf));
                    }
                }
                zgui.spacing();
            }
        }
        zgui.endChild();
    }
}

fn synthSectionColor(index: usize) [4]f32 {
    return switch (index % 5) {
        0 => patina.focus,
        1 => patina.audio,
        2 => patina.modulation,
        3 => patina.rhythm,
        else => patina.danger,
    };
}

fn drawSynthFx(app: *App, synth: *ws.dsp.PolySynth) void {
    var order_buf: [14]ws.dsp.synth.FxUnitKind = undefined;
    const order = synth_ed.fxOnOrder(&app.core, &order_buf);
    zgui.textDisabled("SIGNAL FLOW", .{});
    zgui.sameLine(.{ .spacing = 12 });
    zgui.textColored(patina.audio, "IN", .{});
    for (order) |kind| {
        zgui.sameLine(.{ .spacing = 7 });
        zgui.textDisabled(">", .{});
        zgui.sameLine(.{ .spacing = 7 });
        zgui.textColored(patina.fg1, "{s}", .{spectrum_ed.stripLabel(synth_ed.asFxKind(kind))});
    }
    zgui.sameLine(.{ .spacing = 7 });
    zgui.textDisabled(">", .{});
    zgui.sameLine(.{ .spacing = 7 });
    zgui.textColored(patina.audio, "OUT", .{});
    if (order.len == 0) {
        zgui.spacing();
        zgui.textDisabled("No internal effects are enabled. Press i to insert one.", .{});
        return;
    }
    zgui.spacing();
    if (zgui.beginChild("synth-fx-params", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        var candidates_buf: [synth_ed.max_search_candidates]synth_ed.SearchCandidate = undefined;
        var previous_kind: ?ws.dsp.synth.FxUnitKind = null;
        for (synth_ed.searchCandidates(&app.core, &candidates_buf)) |candidate| {
            if (candidate.subview != .fx) continue;
            const kind = synth_ed.fxKindOfId(candidate.id) orelse continue;
            if (previous_kind == null or previous_kind.? != kind) {
                if (previous_kind != null) zgui.spacing();
                widgets.sectionTitle(spectrum_ed.unitLabel(synth_ed.asFxKind(kind)), patina.audio);
                previous_kind = kind;
            }
            drawSynthAnyParam(app, synth, candidate.id, synth_ed.fxParamLabel(candidate.id));
        }
    }
    zgui.endChild();
}

fn drawSynthAnyParam(app: *App, synth: *ws.dsp.PolySynth, id: u8, label_text: []const u8) void {
    if (ws.dsp.PolySynth.findAutomatableParam(id)) |param| {
        var value = synth.paramValue(id) orelse return;
        var label_buf: [96]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{s}##gui-synth-{d}", .{ label_text, id }) catch return;
        const focused = app.core.synth_cursor == id;
        gui_style.pushControlFocus(focused, patina.focus);
        defer gui_style.popControlFocus(focused);
        if (zgui.sliderFloat(label, .{ .v = &value, .min = param.range[0], .max = param.range[1], .cfmt = "%.3f" })) {
            _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = app.core.synth_track, .id = id, .value = value } });
        }
        if (zgui.isItemActivated()) app.core.synth_cursor = id;
        return;
    }
    const value = synth.paramValue(id) orelse return;
    zgui.text("{s}", .{label_text});
    zgui.sameLine(.{ .spacing = 8 });
    var minus_buf: [32]u8 = undefined;
    const minus = std.fmt.bufPrintZ(&minus_buf, "-##synth-minus-{d}", .{id}) catch return;
    if (zgui.smallButton(minus)) nudgeSynthParam(app, id, 'h');
    zgui.sameLine(.{ .spacing = 5 });
    zgui.textColored(if (app.core.synth_cursor == id) patina.focus else patina.fg1, "{d:.2}", .{value});
    zgui.sameLine(.{ .spacing = 5 });
    var plus_buf: [32]u8 = undefined;
    const plus = std.fmt.bufPrintZ(&plus_buf, "+##synth-plus-{d}", .{id}) catch return;
    if (zgui.smallButton(plus)) nudgeSynthParam(app, id, 'l');
}

fn nudgeSynthParam(app: *App, id: u8, key: u8) void {
    app.core.synth_cursor = id;
    app.core.handleKey(.{ .char = key }, std.Io.Timestamp.now(app.core.io, .awake).nanoseconds);
}

fn drawSynthHeader(app: *App, synth: *ws.dsp.PolySynth) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 156;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("synth-overview", .{ .w = width, .h = height });
    const draw = zgui.getWindowDrawList();
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(patina.bg2), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(patina.focus), .rounding = 3 });
    draw.addText(.{ origin[0] + 17, origin[1] + 10 }, color(patina.fg3), "POLYPHONIC SYNTH", .{});
    draw.addText(.{ origin[0] + 17, origin[1] + 31 }, color(patina.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.synth_track].name});

    const panel_y = origin[1] + 59;
    const panel_h: f32 = 80;
    const panel_gap: f32 = 9;
    const panel_w = (width - 43 - panel_gap * 2) / 3;
    drawSynthOverviewPanel(draw, .{ origin[0] + 17, panel_y }, .{ panel_w, panel_h }, "OSCILLATOR", patina.focus);
    drawSynthOverviewPanel(draw, .{ origin[0] + 17 + panel_w + panel_gap, panel_y }, .{ panel_w, panel_h }, "ENVELOPE", patina.rhythm);
    drawSynthOverviewPanel(draw, .{ origin[0] + 17 + (panel_w + panel_gap) * 2, panel_y }, .{ panel_w, panel_h }, "FILTER", patina.audio);
    drawOscillatorShape(draw, .{ origin[0] + 29, panel_y + 31 }, .{ panel_w - 24, 35 }, synth.waveform);
    drawEnvelopeShape(draw, .{ origin[0] + 29 + panel_w + panel_gap, panel_y + 31 }, .{ panel_w - 24, 35 }, synth);
    drawFilterShape(draw, .{ origin[0] + 29 + (panel_w + panel_gap) * 2, panel_y + 31 }, .{ panel_w - 24, 35 }, synth);
}

fn drawSynthOverviewPanel(draw: zgui.DrawList, pos: [2]f32, size: [2]f32, label: []const u8, accent: [4]f32) void {
    draw.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + size[0], pos[1] + size[1] }, .col = color(patina.bg1), .rounding = 3 });
    draw.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + 3, pos[1] + size[1] }, .col = color(accent), .rounding = 2 });
    draw.addText(.{ pos[0] + 12, pos[1] + 8 }, color(patina.fg3), "{s}", .{label});
}

fn drawOscillatorShape(draw: zgui.DrawList, pos: [2]f32, size: [2]f32, waveform: ws.dsp.synth.Waveform) void {
    var prev = pos;
    for (1..49) |i| {
        const phase = @as(f32, @floatFromInt(i)) / 48.0 * 2.0;
        const sample: f32 = switch (waveform) {
            .sine => @sin(phase * std.math.pi * 2.0),
            .saw, .wavetable => phase - @floor(phase) * 2.0 - 1.0,
            .triangle => 1.0 - 4.0 * @abs(@round(phase) - phase),
            .square => if (@mod(phase, 1.0) < 0.5) 1.0 else -1.0,
        };
        const point = [2]f32{ pos[0] + size[0] * @as(f32, @floatFromInt(i)) / 48.0, pos[1] + size[1] * (0.5 - sample * 0.42) };
        if (i > 1) draw.addLine(.{ .p1 = prev, .p2 = point, .col = color(patina.focus), .thickness = 2 });
        prev = point;
    }
}

fn drawEnvelopeShape(draw: zgui.DrawList, pos: [2]f32, size: [2]f32, synth: *const ws.dsp.PolySynth) void {
    const ad_total = @max(0.01, synth.attack_s + synth.decay_s);
    const attack_x = pos[0] + size[0] * 0.55 * synth.attack_s / ad_total;
    const decay_x = pos[0] + size[0] * 0.55;
    const release_x = pos[0] + size[0] * 0.78;
    const sustain_y = pos[1] + size[1] * (1.0 - synth.sustain);
    const points = [_][2]f32{ .{ pos[0], pos[1] + size[1] }, .{ attack_x, pos[1] }, .{ decay_x, sustain_y }, .{ release_x, sustain_y }, .{ pos[0] + size[0], pos[1] + size[1] } };
    for (0..points.len - 1) |i| draw.addLine(.{ .p1 = points[i], .p2 = points[i + 1], .col = color(patina.rhythm), .thickness = 2 });
}

fn drawFilterShape(draw: zgui.DrawList, pos: [2]f32, size: [2]f32, synth: *const ws.dsp.PolySynth) void {
    const cutoff = std.math.clamp(@log10(synth.filter_cutoff / 20.0) / 3.0, 0, 1);
    const knee_x = pos[0] + size[0] * cutoff;
    const peak_y = pos[1] + size[1] * (0.45 - synth.filter_res * 0.35);
    const left = [2]f32{ pos[0], pos[1] + size[1] * 0.45 };
    const right = [2]f32{ pos[0] + size[0], pos[1] + size[1] * 0.45 };
    const bottom_left = [2]f32{ pos[0], pos[1] + size[1] };
    const bottom_right = [2]f32{ pos[0] + size[0], pos[1] + size[1] };
    switch (synth.filter_type) {
        .lp, .ladder, .diode => {
            draw.addLine(.{ .p1 = left, .p2 = .{ knee_x, peak_y }, .col = color(patina.audio), .thickness = 2 });
            draw.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = bottom_right, .col = color(patina.audio), .thickness = 2 });
        },
        .hp => {
            draw.addLine(.{ .p1 = bottom_left, .p2 = .{ knee_x, peak_y }, .col = color(patina.audio), .thickness = 2 });
            draw.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = right, .col = color(patina.audio), .thickness = 2 });
        },
        .bp, .formant => {
            draw.addLine(.{ .p1 = bottom_left, .p2 = .{ knee_x, peak_y }, .col = color(patina.audio), .thickness = 2 });
            draw.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = bottom_right, .col = color(patina.audio), .thickness = 2 });
        },
        .notch, .comb => {
            draw.addLine(.{ .p1 = left, .p2 = .{ knee_x, pos[1] + size[1] * 0.85 }, .col = color(patina.audio), .thickness = 2 });
            draw.addLine(.{ .p1 = .{ knee_x, pos[1] + size[1] * 0.85 }, .p2 = right, .col = color(patina.audio), .thickness = 2 });
        },
    }
}

fn drawStatus(app: *App) void {
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = display[1] - 34, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = 34, .cond = .always });
    if (zgui.begin("Status", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true } })) {
        const draw = zgui.getWindowDrawList();
        const pos = zgui.getWindowPos();
        const size = zgui.getWindowSize();
        draw.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + size[0], pos[1] + size[1] }, .col = color(patina.bg1) });

        var left_buf: [2048]u8 = undefined;
        var right_buf: [256]u8 = undefined;
        const status = tuiStatusText(app, &left_buf, &right_buf);
        const mode_label = statusModeLabel(app.core.modal.mode);
        const x = drawStatusSegment(draw, pos[0], pos[1], size[1], statusModeColor(app.core.modal.mode), patina.bg0, mode_label);
        const context = std.mem.trim(u8, status.left, " ");
        if (context.len > 0) {
            const text_size = zgui.calcTextSize(context, .{});
            draw.addText(.{ x + 12, pos[1] + (size[1] - text_size[1]) / 2 }, color(patina.fg1), "{s}", .{context});
        }
        if (status.right.len > 0) {
            const right_color = if (app.core.view == .arrangement)
                if (app.core.session.song_mode) patina.audio else patina.rhythm
            else
                statusModeColor(app.core.modal.mode);
            drawStatusSegmentRight(draw, pos[0] + size[0], pos[1], size[1], right_color, patina.bg0, status.right);
        }
    }
    zgui.end();
}

const StatusText = struct { left: []const u8, right: []const u8 };

// TUI status renderers are the canonical footer content; the GUI strips SGR
// codes and supplies its own presentation so both frontends stay in sync.
fn tuiStatusText(app: *App, left_out: []u8, right_out: []u8) StatusText {
    var left_ansi: [2048]u8 = undefined;
    var right_ansi: [256]u8 = undefined;
    var left_writer = std.Io.Writer.fixed(&left_ansi);
    var right_writer = std.Io.Writer.fixed(&right_ansi);
    const core = &app.core;
    if (core.view == .tracks) core.tracksRowSync();
    (switch (core.view) {
        .tracks => tui.drawTracksStatus(core, &left_writer, &right_writer),
        .drum_grid => tui.drawDrumStatus(core, &left_writer, &right_writer),
        .synth_editor => tui.drawSynthStatus(core, &left_writer, &right_writer),
        .sampler_editor => tui.drawSamplerStatus(core, &left_writer, &right_writer),
        .piano_roll => tui.drawPianoRollStatus(core, &left_writer, &right_writer),
        .help => tui.drawHelpStatus(core, &left_writer, &right_writer),
        .track_spectrum, .master_spectrum, .group_spectrum => tui.drawFxStatus(core, &left_writer, &right_writer, spectrum_ed.currentTarget(core)),
        .instrument_picker => tui.drawPickerStatus(core, &left_writer, &right_writer, "INSTRUMENT", "insert", false),
        .fx_picker => tui.drawPickerStatus(core, &left_writer, &right_writer, "EFFECT", "insert", true),
        .synth_fx_picker => tui.drawPickerStatus(core, &left_writer, &right_writer, "SYNTH FX", "insert", true),
        .arrangement => tui.drawArrangementStatus(core, &left_writer, &right_writer),
        .file_browser => tui.drawFileBrowserStatus(core, &left_writer, &right_writer),
        .automation => tui.drawAutomationStatus(core, &left_writer, &right_writer),
        .automation_param_picker => tui.drawPickerStatus(core, &left_writer, &right_writer, "PARAM", "pick", true),
        .slicer_grid => tui.drawSlicerStatus(core, &left_writer, &right_writer),
        .preset_picker => tui.drawPresetPickerStatus(core, &left_writer, &right_writer),
    }) catch return .{ .left = "", .right = "" };

    const plain_left = stripAnsi(left_writer.buffered(), left_out);
    const without_mode = if (plain_left.len >= 3) plain_left[3..] else plain_left;
    return .{
        .left = without_mode,
        .right = std.mem.trim(u8, stripAnsi(right_writer.buffered(), right_out), " "),
    };
}

fn stripAnsi(input: []const u8, out: []u8) []const u8 {
    var src: usize = 0;
    var dst: usize = 0;
    while (src < input.len and dst < out.len) {
        if (input[src] == 0x1b and src + 1 < input.len and input[src + 1] == '[') {
            src += 2;
            while (src < input.len) : (src += 1) {
                if (input[src] >= 0x40 and input[src] <= 0x7e) {
                    src += 1;
                    break;
                }
            }
            continue;
        }
        out[dst] = input[src];
        dst += 1;
        src += 1;
    }
    return out[0..dst];
}

fn statusModeLabel(mode: ws.input.Mode) []const u8 {
    return switch (mode) {
        .normal => "N",
        .insert => "I",
        .visual => "V",
        .command => "C",
        .search => "S",
    };
}

fn statusModeColor(mode: ws.input.Mode) [4]f32 {
    return switch (mode) {
        .normal => patina.audio,
        .insert => patina.rhythm,
        .visual => patina.modulation,
        .command, .search => patina.focus,
    };
}

fn drawCommandPrompt(app: *App) void {
    const mode = app.core.modal.mode;
    if (mode != .command and mode != .search) return;

    const display = zgui.io.getDisplaySize();
    const prompt_h: f32 = 38;
    const prompt_y = display[1] - 34 - prompt_h;
    zgui.setNextWindowPos(.{ .x = 0, .y = prompt_y, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = prompt_h, .cond = .always });
    if (zgui.begin("Command Prompt", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true, .no_saved_settings = true } })) {
        drawCommandBar(app, zgui.getWindowDrawList(), zgui.getWindowPos(), zgui.getWindowSize());
    }
    zgui.end();

    if (mode != .command) return;
    const filter = app.core.suggestionFilterText();
    if (filter.len == 0) return;
    const active = tui_commands.activeScope(&app.core);
    const count = tui_cmd.suggestionCount(app.core.allCmds(), filter, active);
    if (count < 2) return;
    const rows = @min(count, 8);
    const row_h: f32 = 39;
    const popup_w = @min(@as(f32, 620), display[0] - 24);
    const popup_h = 31 + row_h * @as(f32, @floatFromInt(rows));
    zgui.setNextWindowPos(.{ .x = 12, .y = prompt_y - popup_h - 6, .cond = .always });
    zgui.setNextWindowSize(.{ .w = popup_w, .h = popup_h, .cond = .always });
    if (zgui.begin("Command Suggestions", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true, .no_saved_settings = true, .no_mouse_inputs = true, .no_nav_inputs = true, .no_nav_focus = true } })) {
        drawCommandSuggestions(app, active, filter, rows);
    }
    zgui.end();
}

fn drawCommandSuggestions(app: *const App, active: tui_cmd.Scope, filter: []const u8, max_rows: usize) void {
    const draw = zgui.getWindowDrawList();
    const origin = zgui.getWindowPos();
    const size = zgui.getWindowSize();
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + size[0], origin[1] + size[1] }, .col = color(patina.bg1), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 4, origin[1] + size[1] }, .col = color(patina.focus), .rounding = 2 });
    draw.addText(.{ origin[0] + 14, origin[1] + 8 }, color(patina.fg3), "COMMANDS", .{});
    draw.addText(.{ origin[0] + size[0] - 96, origin[1] + 8 }, color(patina.fg3), "TAB TO CYCLE", .{});

    const selected = app.core.suggestionSelected(active);
    var match_index: usize = 0;
    var drawn: usize = 0;
    for (app.core.allCmds()) |command| {
        if (tui_cmd.hiddenFromCompletion(command) or !tui_cmd.visible(command, active)) continue;
        if (!std.mem.startsWith(u8, command.name, filter)) continue;
        if (drawn >= max_rows) break;
        const y = origin[1] + 30 + @as(f32, @floatFromInt(drawn)) * 39;
        const is_selected = match_index == selected;
        if (is_selected) {
            draw.addRectFilled(.{ .pmin = .{ origin[0] + 7, y }, .pmax = .{ origin[0] + size[0] - 7, y + 35 }, .col = color(patina.bg4), .rounding = 3 });
            draw.addRectFilled(.{ .pmin = .{ origin[0] + 7, y }, .pmax = .{ origin[0] + 10, y + 35 }, .col = color(patina.focus), .rounding = 2 });
        }
        draw.addText(.{ origin[0] + 20, y + 4 }, color(if (is_selected) patina.fg0 else patina.fg1), ":{s}", .{command.name});
        draw.addText(.{ origin[0] + 185, y + 4 }, color(if (is_selected) patina.fg2 else patina.fg3), "{s}", .{command.desc});
        match_index += 1;
        drawn += 1;
    }
}

fn drawCommandBar(app: *const App, draw: zgui.DrawList, pos: [2]f32, size: [2]f32) void {
    const prompt: []const u8 = if (app.core.modal.mode == .command) ":" else "/";
    const text_y = pos[1] + (size[1] - zgui.getTextLineHeight()) / 2;
    const prompt_x = pos[0] + 13;
    const input_x = prompt_x + zgui.calcTextSize(prompt, .{})[0] + 4;
    const input = app.core.modal.cmd_buf[0..app.core.modal.cmd_len];

    draw.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + size[0], pos[1] + size[1] },
        .col = color(patina.bg2),
    });
    draw.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + 4, pos[1] + size[1] },
        .col = color(patina.focus),
    });
    draw.addText(.{ prompt_x, text_y }, color(patina.focus), "{s}", .{prompt});
    draw.addText(.{ input_x, text_y }, color(patina.fg0), "{s}", .{input});

    if (app.core.modal.mode == .command) {
        if (std.mem.indexOfScalar(u8, input, ' ')) |space| {
            const name = input[0..space];
            for (app.core.allCmds()) |command| {
                if (!std.mem.eql(u8, command.name, name)) continue;
                const hint_x = input_x + zgui.calcTextSize(input, .{})[0] + 18;
                draw.addText(.{ hint_x, text_y }, color(patina.fg3), "{s}", .{command.desc});
                break;
            }
        }
        draw.addText(.{ pos[0] + size[0] - 150, text_y }, color(patina.fg3), "TAB complete   ESC close", .{});
    } else {
        draw.addText(.{ pos[0] + size[0] - 102, text_y }, color(patina.fg3), "ENTER search", .{});
    }

    const before_cursor = input[0..app.core.modal.cmd_cursor];
    const cursor_x = input_x + zgui.calcTextSize(before_cursor, .{})[0];
    draw.addRectFilled(.{
        .pmin = .{ cursor_x, text_y },
        .pmax = .{ cursor_x + 1, text_y + zgui.getTextLineHeight() },
        .col = color(patina.fg0),
    });
}

fn drawStatusSegment(draw: zgui.DrawList, x: f32, y: f32, height: f32, bg: [4]f32, fg: [4]f32, label: []const u8) f32 {
    const padding: f32 = 13;
    const text_size = zgui.calcTextSize(label, .{});
    const width = text_size[0] + padding * 2;
    draw.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + width, y + height }, .col = color(bg) });
    draw.addText(.{ x + padding, y + (height - text_size[1]) / 2 }, color(fg), "{s}", .{label});
    return x + width;
}

fn drawStatusSegmentRight(draw: zgui.DrawList, right: f32, y: f32, height: f32, bg: [4]f32, fg: [4]f32, label: []const u8) void {
    const padding: f32 = 13;
    const text_size = zgui.calcTextSize(label, .{});
    const width = text_size[0] + padding * 2;
    const x = right - width;
    draw.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ right, y + height }, .col = color(bg) });
    draw.addText(.{ x + padding, y + (height - text_size[1]) / 2 }, color(fg), "{s}", .{label});
}
