//! Experimental desktop frontend. The engine remains frontend-neutral; this
//! file owns only GLFW/ImGui lifecycle and GUI-specific presentation state.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const tui_app = @import("../tui/app.zig");
const tui_cmd = @import("../tui/cmd.zig");
const tui_commands = @import("../tui/commands.zig");
const gui_style = @import("style.zig");
const automation_view = @import("views/automation.zig");
const file_browser_view = @import("views/file_browser.zig");
const fx_view = @import("views/fx.zig");
const help_view = @import("views/help.zig");
const picker_view = @import("views/picker.zig");
const sampler_view = @import("views/sampler.zig");
const slicer_view = @import("views/slicer.zig");
const step_grid = @import("views/step_grid.zig");
const glfw = @import("zglfw");
const zgui = @import("zgui");
const zopengl = @import("zopengl");

const gl = zopengl.bindings;
const color = gui_style.color;
const rgb = gui_style.rgb;
const trackColor = gui_style.trackColor;
const umbra = gui_style.umbra;

pub const App = struct {
    core: tui_app.App,
    held_notes: [piano_keys.len]?HeldNote = [_]?HeldNote{null} ** piano_keys.len,
    picker_return_view: tui_app.AppView = .tracks,
    picker_popup_pending: bool = false,
    picker_popup_visible: bool = false,
    browser_selection: ?u8 = null,
    browser_dir: []u8 = &.{},
    browser_entries: std.ArrayListUnmanaged(BrowserEntry) = .empty,
    pending_project_path: ?[]u8 = null,
    arrangement_clip: ?struct { track: usize, clip: usize } = null,
    piano_top_pitch: u7 = 84,
    automation_clip: usize = 0,
    automation_target: AutomationTarget = .gain,
    automation_beat: f32 = 0,
    automation_value: f32 = 0,
    eq_drag_band: ?u8 = null,
    eq_analyzer_key: ?u32 = null,

    const BrowserEntry = struct { name: []u8, is_dir: bool };
    const AutomationTarget = enum { gain, pan };

    fn init(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8) !App {
        var core = try tui_app.App.init(allocator, io);
        errdefer core.deinit();
        if (init_path) |path| {
            const session = try ws.persist.load(allocator, io, path);
            core.session.deinit();
            core.session = session;
            core.setProjectPath(path);
        }
        return .{ .core = core };
    }

    fn deinit(self: *App) void {
        self.clearBrowser();
        self.browser_entries.deinit(self.core.allocator);
        if (self.browser_dir.len > 0) self.core.allocator.free(self.browser_dir);
        if (self.pending_project_path) |path| self.core.allocator.free(path);
        self.core.deinit();
    }

    fn clearBrowser(self: *App) void {
        for (self.browser_entries.items) |entry| self.core.allocator.free(entry.name);
        self.browser_entries.clearRetainingCapacity();
    }

    fn setBrowserDir(self: *App, path: []const u8) !void {
        const canon = try std.Io.Dir.cwd().realPathFileAlloc(self.core.io, path, self.core.allocator);
        errdefer self.core.allocator.free(canon);
        var dir = try std.Io.Dir.cwd().openDir(self.core.io, canon, .{ .iterate = true });
        defer dir.close(self.core.io);
        var entries: std.ArrayListUnmanaged(BrowserEntry) = .empty;
        errdefer {
            for (entries.items) |entry| self.core.allocator.free(entry.name);
            entries.deinit(self.core.allocator);
        }
        var it = dir.iterate();
        while (try it.next(self.core.io)) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const is_dir = entry.kind == .directory;
            if (!is_dir and !std.ascii.endsWithIgnoreCase(entry.name, ".wsj")) continue;
            try entries.append(self.core.allocator, .{ .name = try self.core.allocator.dupe(u8, entry.name), .is_dir = is_dir });
        }
        std.mem.sort(BrowserEntry, entries.items, {}, struct {
            fn less(_: void, a: BrowserEntry, b: BrowserEntry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);
        self.clearBrowser();
        self.browser_entries.deinit(self.core.allocator);
        if (self.browser_dir.len > 0) self.core.allocator.free(self.browser_dir);
        self.browser_dir = canon;
        self.browser_entries = entries;
    }

    fn activateBrowserEntry(self: *App, entry: BrowserEntry) void {
        const joined = std.fs.path.join(self.core.allocator, &.{ self.browser_dir, entry.name }) catch return;
        if (entry.is_dir) {
            defer self.core.allocator.free(joined);
            self.setBrowserDir(joined) catch {};
        } else {
            if (self.pending_project_path) |old| self.core.allocator.free(old);
            self.pending_project_path = joined;
        }
    }

    fn draw(self: *App, audio_label: []const u8) void {
        drawTransport(self);
        drawWorkspace(self);
        drawStatus(self, audio_label);
        drawCommandPrompt(self);
    }

    fn handleShortcuts(self: *App) void {
        for (piano_keys, 0..) |entry, i| {
            if (self.held_notes[i]) |note| if (zgui.isKeyReleased(entry.key)) {
                _ = self.core.session.engine.send(.{ .note_off = .{
                    .track = note.track,
                    .note = note.pitch,
                } });
                self.held_notes[i] = null;
            };
        }
        if (zgui.isAnyItemActive()) return;
        if (zgui.isKeyPressed(.f1, false)) {
            self.core.handleKey(.{ .char = '?' }, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
            return;
        }
        if (pressedModalKey(self.core.modal.mode)) |key| {
            self.core.handleKey(key, std.Io.Timestamp.now(self.core.io, .awake).nanoseconds);
        }
    }

    pub fn openPicker(self: *App, picker: tui_app.AppView) void {
        if (!isPicker(picker)) return;
        if (!isPicker(self.core.view)) self.picker_return_view = self.core.view;
        if (picker == .fx_picker) self.core.fx_picker_return = self.picker_return_view;
        self.core.view = picker;
        self.picker_popup_pending = true;
    }

    pub fn closePicker(self: *App, destination: ?tui_app.AppView) void {
        zgui.closeCurrentPopup();
        self.core.view = destination orelse self.picker_return_view;
        self.picker_popup_pending = false;
        self.picker_popup_visible = false;
    }
};

fn isPicker(view: tui_app.AppView) bool {
    return view == .instrument_picker or view == .fx_picker or view == .preset_picker;
}

fn workspaceView(app: *const App) tui_app.AppView {
    return if (isPicker(app.core.view)) app.picker_return_view else app.core.view;
}

const HeldNote = struct { track: u16, pitch: u7 };

const piano_keys = [_]struct { key: zgui.Key, char: u8 }{
    .{ .key = .a, .char = 'a' },         .{ .key = .s, .char = 's' }, .{ .key = .d, .char = 'd' },
    .{ .key = .f, .char = 'f' },         .{ .key = .g, .char = 'g' }, .{ .key = .h, .char = 'h' },
    .{ .key = .j, .char = 'j' },         .{ .key = .k, .char = 'k' }, .{ .key = .l, .char = 'l' },
    .{ .key = .semicolon, .char = ';' }, .{ .key = .q, .char = 'q' }, .{ .key = .w, .char = 'w' },
    .{ .key = .r, .char = 'r' },         .{ .key = .t, .char = 't' }, .{ .key = .y, .char = 'y' },
    .{ .key = .i, .char = 'i' },         .{ .key = .o, .char = 'o' }, .{ .key = .p, .char = 'p' },
};

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

    fn init(sample_rate: u32, engine: *ws.Engine) GuiAudio {
        const config: ws.backend.Config = .{ .sample_rate = sample_rate };
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

const Layout = struct {
    browser_w: f32,
    tracks_w: f32,
    workspace_w: f32,
    inspector_w: f32,
    body_h: f32,

    fn current(prompt_open: bool) Layout {
        const display = zgui.io.getDisplaySize();
        const browser_w = std.math.clamp(display[0] * 0.14, 140, 220);
        const tracks_w = std.math.clamp(display[0] * 0.18, 180, 260);
        const inspector_w = std.math.clamp(display[0] * 0.16, 180, 240);
        return .{
            .browser_w = browser_w,
            .tracks_w = tracks_w,
            .workspace_w = display[0] - browser_w - tracks_w - inspector_w,
            .inspector_w = inspector_w,
            .body_h = display[1] - 98 - @as(f32, if (prompt_open) 38 else 0),
        };
    }
};

pub fn run(init: std.process.Init, init_path: ?[]const u8) !void {
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    const window = try glfw.Window.create(1440, 900, "wstudio GUI prototype", null, null);
    defer window.destroy();
    window.setSizeLimits(960, 600, -1, -1);
    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);
    try zopengl.loadCoreProfile(glfw.getProcAddress, 3, 3);

    zgui.init(init.gpa);
    defer zgui.deinit();
    var font_config = zgui.FontConfig.init();
    font_config.size_pixels = 16;
    zgui.io.setDefaultFont(zgui.io.addFontDefault(font_config));
    zgui.plot.init();
    defer zgui.plot.deinit();
    zgui.io.setConfigFlags(.{ .nav_enable_keyboard = true });
    zgui.io.setIniFilename(null);
    gui_style.setTheme();
    zgui.backend.init(window);
    defer zgui.backend.deinit();

    var app = App.init(init.gpa, init.io, init_path) catch |err| {
        if (init_path) |path| std.debug.print("wstudio: cannot load '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer app.deinit();
    if (init_path) |path| {
        var title_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrintZ(&title_buf, "wstudio GUI prototype - {s}", .{path})) |title| window.setTitle(title) else |_| {}
    }
    var audio = GuiAudio.init(app.core.session.project.sample_rate, app.core.session.engine);
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
                audio = GuiAudio.init(app.core.session.project.sample_rate, app.core.session.engine);
                try audio.start(init.io);
            }
        }
        if (app.pending_project_path) |path| {
            app.pending_project_path = null;
            defer init.gpa.free(path);
            if (ws.persist.load(init.gpa, init.io, path)) |loaded| {
                audio.stop();
                app.core.session.deinit();
                app.core.session = loaded;
                app.core.cursor = 0;
                app.automation_clip = 0;
                audio = GuiAudio.init(app.core.session.project.sample_rate, app.core.session.engine);
                try audio.start(init.io);
                var title_buf: [1024]u8 = undefined;
                if (std.fmt.bufPrintZ(&title_buf, "wstudio GUI prototype - {s}", .{path})) |title| window.setTitle(title) else |_| {}
            } else |err| {
                std.debug.print("wstudio: cannot load '{s}': {s}\n", .{ path, @errorName(err) });
            }
        }
        const fb = window.getFramebufferSize();
        if (fb[0] <= 0 or fb[1] <= 0) continue;
        gl.viewport(0, 0, fb[0], fb[1]);
        gl.clearColor(umbra.bg0[0], umbra.bg0[1], umbra.bg0[2], 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        zgui.backend.newFrame(@intCast(fb[0]), @intCast(fb[1]));
        app.handleShortcuts();
        app.draw(audio.label());
        zgui.backend.draw();
        window.swapBuffers();
    }
}

fn renderAudio(ctx: *anyopaque, out: []ws.types.Sample) void {
    const engine: *ws.Engine = @ptrCast(@alignCast(ctx));
    engine.process(out);
}

fn drawTransport(app: *App) void {
    const snap = app.core.session.engine.uiSnapshot();
    const playing_color = if (snap.playing) umbra.red else umbra.iris;
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = 64, .cond = .always });
    if (zgui.begin("Transport", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true } })) {
        zgui.pushStyleColor4f(.{ .idx = .button, .c = playing_color });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (snap.playing) umbra.mauve else umbra.yellow });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = umbra.fg0 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = umbra.bg0 });
        zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = 3 });
        if (zgui.button(if (snap.playing) "STOP" else "PLAY", .{ .w = 82, .h = 40 })) {
            _ = app.core.session.engine.send(if (snap.playing) .stop else .play);
        }
        zgui.popStyleVar(.{});
        zgui.popStyleColor(.{ .count = 4 });

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

        drawTransportReadout("TEMPO", tempo);
        drawTransportReadout("POSITION", position);
        drawTransportReadout("METER", meter);
        drawTransportReadout("RATE", rate);
        drawTransportReadout("PROJECT", app.core.session.project.name);
    }
    zgui.end();
}

fn drawTransportReadout(label: []const u8, value: []const u8) void {
    zgui.sameLine(.{ .spacing = 24 });
    zgui.beginGroup();
    zgui.textColored(umbra.fg3, "{s}", .{label});
    zgui.textColored(umbra.fg0, "{s}", .{value});
    zgui.endGroup();
}

fn drawBrowser(app: *App) void {
    const layout = Layout.current(app.core.modal.mode == .command or app.core.modal.mode == .search);
    zgui.setNextWindowPos(.{ .x = 0, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = layout.browser_w, .h = layout.body_h, .cond = .always });
    if (zgui.begin("Browser", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        zgui.textDisabled("LIBRARY", .{});
        zgui.separator();
        const entries = [_]struct { label: []const u8, hint: []const u8, view: tui_app.AppView, accent: [4]f32 }{
            .{ .label = "Instruments", .hint = "Devices", .view = .instrument_picker, .accent = umbra.iris },
            .{ .label = "Samples", .hint = "Audio files", .view = .file_browser, .accent = umbra.cyan },
            .{ .label = "Drum Kits", .hint = "Patterns", .view = .drum_grid, .accent = umbra.yellow },
            .{ .label = "Presets", .hint = "Saved sounds", .view = .preset_picker, .accent = umbra.mauve },
            .{ .label = "Projects", .hint = "Songs on disk", .view = .file_browser, .accent = umbra.red },
        };
        for (entries, 0..) |entry, i| drawBrowserRow(app, entry.label, entry.hint, entry.view, entry.accent, @intCast(i));
    }
    zgui.end();
}

fn drawBrowserRow(app: *App, label: []const u8, hint: []const u8, view: tui_app.AppView, accent: [4]f32, index: u8) void {
    const height: f32 = 44;
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "browser-row-{d}", .{index}) catch return;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const selected = app.browser_selection == index and app.core.view == view;
    const draw = zgui.getWindowDrawList();

    if (selected or hovered) draw.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height },
        .col = color(if (selected) umbra.bg3 else umbra.bg2),
        .rounding = 3,
    });
    draw.addRectFilled(.{
        .pmin = .{ origin[0] + 7, origin[1] + 9 },
        .pmax = .{ origin[0] + 11, origin[1] + height - 9 },
        .col = color(accent),
        .rounding = 2,
    });
    draw.addText(.{ origin[0] + 22, origin[1] + 6 }, color(if (selected) umbra.fg0 else umbra.fg1), "{s}", .{label});
    draw.addText(.{ origin[0] + 22, origin[1] + 23 }, color(umbra.fg3), "{s}", .{hint});
    if (clicked) {
        app.browser_selection = index;
        if (isPicker(view)) app.openPicker(view) else app.core.view = view;
    }
}

fn drawTracks(app: *App) void {
    const layout = Layout.current(app.core.modal.mode == .command or app.core.modal.mode == .search);
    zgui.setNextWindowPos(.{ .x = layout.browser_w, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = layout.tracks_w, .h = layout.body_h, .cond = .always });
    if (zgui.begin("Tracks", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        zgui.textDisabled("TRACKS", .{});
        zgui.sameLine(.{});
        zgui.textColored(umbra.fg2, "{d}", .{app.core.session.project.tracks.items.len});
        zgui.separator();
        for (app.core.session.project.tracks.items, 0..) |track, i| drawTrackRow(app, track, i);
        zgui.spacing();
        zgui.separator();
        zgui.pushStyleColor4f(.{ .idx = .button, .c = umbra.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = umbra.bg3 });
        if (zgui.button("+  NEW TRACK", .{ .w = -1, .h = 30 })) {
            const idx = app.core.session.project.tracks.items.len + 1;
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "track {d}", .{idx}) catch "track";
            _ = app.core.session.addTrack(name) catch {};
        }
        zgui.popStyleColor(.{ .count = 2 });
    }
    zgui.end();
}

fn drawTrackRow(app: *App, track: ws.Track, index: usize) void {
    const height: f32 = 32;
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "track-row-{d}", .{index}) catch return;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const selected = app.core.cursor == index;
    const draw = zgui.getWindowDrawList();

    if (selected or hovered) draw.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height },
        .col = color(if (selected) umbra.bg4 else umbra.bg2),
        .rounding = 3,
    });
    const accent = trackColor(track.color);
    draw.addRectFilled(.{
        .pmin = .{ origin[0], origin[1] + 5 },
        .pmax = .{ origin[0] + 3, origin[1] + height - 5 },
        .col = color(accent),
        .rounding = 2,
    });
    draw.addText(.{ origin[0] + 11, origin[1] + 8 }, color(umbra.fg3), "{d:0>2}", .{index + 1});
    draw.addText(.{ origin[0] + 39, origin[1] + 8 }, color(if (selected) umbra.fg0 else umbra.fg1), "{s}", .{track.name});

    var badge_x = origin[0] + width - 10;
    if (track.soloed) {
        badge_x -= 18;
        drawTrackBadge(draw, badge_x, origin[1] + 7, "S", umbra.yellow);
    }
    if (track.muted) {
        badge_x -= 18;
        drawTrackBadge(draw, badge_x, origin[1] + 7, "M", umbra.red);
    }
    if (clicked) app.core.cursor = index;
}

fn drawTrackBadge(draw: zgui.DrawList, x: f32, y: f32, label: []const u8, bg: [4]f32) void {
    draw.addRectFilled(.{ .pmin = .{ x, y }, .pmax = .{ x + 15, y + 18 }, .col = color(bg), .rounding = 2 });
    draw.addText(.{ x + 4, y + 2 }, color(umbra.bg0), "{s}", .{label});
}

fn drawWorkspace(app: *App) void {
    if (app.core.view != .track_spectrum and app.core.view != .master_spectrum and app.core.view != .group_spectrum and app.eq_analyzer_key != null) {
        _ = app.core.session.engine.send(.{ .set_spectrum_active = .{ .source = .none, .track = 0 } });
        app.eq_analyzer_key = null;
    }
    const layout = Layout.current(app.core.modal.mode == .command or app.core.modal.mode == .search);
    zgui.setNextWindowPos(.{ .x = 0, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = layout.body_h, .cond = .always });
    if (zgui.begin("Workspace", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        zgui.textColored(umbra.fg3, "{s}", .{@tagName(app.core.view)});
        zgui.sameLine(.{ .spacing = 18 });
        zgui.textDisabled("j/k move   enter open   esc back   tab arrange/tracks   : command   ? help", .{});
        zgui.separator();
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
            .automation_param_picker => automation_view.draw(app),
            .file_browser => file_browser_view.draw(app),
            .help => help_view.draw(app),
        }
    }
    zgui.end();
}

fn drawPickerPopup(app: *App) void {
    if (!isPicker(app.core.view)) return;
    const popup_name: [:0]const u8 = "Command Palette";
    if (app.picker_popup_pending) {
        zgui.openPopup(popup_name, .{});
        app.picker_popup_pending = false;
    }

    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{
        .x = display[0] / 2,
        .y = display[1] / 2,
        .cond = .appearing,
        .pivot_x = 0.5,
        .pivot_y = 0.5,
    });
    zgui.setNextWindowSize(.{
        .w = @min(680, display[0] - 80),
        .h = @min(520, display[1] - 80),
        .cond = .appearing,
    });
    if (zgui.beginPopupModal(popup_name, .{ .flags = .{ .no_resize = true, .no_saved_settings = true } })) {
        app.picker_popup_visible = true;
        zgui.textColored(umbra.fg3, "SELECT A RESULT   ESC TO CLOSE", .{});
        zgui.separator();
        switch (app.core.view) {
            .instrument_picker => picker_view.drawInstrument(app),
            .fx_picker => picker_view.drawFx(app),
            .preset_picker => picker_view.drawPreset(app),
            else => unreachable,
        }
        zgui.endPopup();
    } else if (app.picker_popup_visible) {
        app.picker_popup_visible = false;
        app.core.view = app.picker_return_view;
    }
}

fn drawViewNav(app: *App) void {
    const entries = [_]struct { label: [:0]const u8, view: tui_app.AppView }{
        .{ .label = "Tracks", .view = .tracks },
        .{ .label = "Arrange", .view = .arrangement },
        .{ .label = "Piano", .view = .piano_roll },
        .{ .label = "Drums", .view = .drum_grid },
        .{ .label = "Slicer", .view = .slicer_grid },
        .{ .label = "Synth", .view = .synth_editor },
        .{ .label = "Sampler", .view = .sampler_editor },
        .{ .label = "FX", .view = .track_spectrum },
        .{ .label = "Scope", .view = .track_spectrum },
        .{ .label = "Auto", .view = .automation },
        .{ .label = "Pick", .view = .instrument_picker },
        .{ .label = "More", .view = .help },
    };
    const available = zgui.getContentRegionAvail()[0];
    var row_width: f32 = 0;
    for (entries, 0..) |entry, i| {
        const width = zgui.calcTextSize(entry.label, .{})[0] + 20;
        if (i != 0 and row_width + width + 4 <= available) {
            zgui.sameLine(.{ .spacing = 4 });
            row_width += 4;
        } else if (i != 0) {
            row_width = 0;
        }
        drawViewTab(app, entry.label, entry.view, width);
        row_width += width;
    }
}

fn drawViewTab(app: *App, label: [:0]const u8, view: tui_app.AppView, width: f32) void {
    const height: f32 = 27;
    const origin = zgui.getCursorScreenPos();
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "view-tab-{s}", .{label}) catch return;
    const clicked = zgui.invisibleButton(id, .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const selected = workspaceView(app) == view;
    const draw = zgui.getWindowDrawList();

    if (selected or hovered) draw.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height },
        .col = color(if (selected) umbra.bg3 else umbra.bg2),
        .rounding = 3,
    });
    if (selected) draw.addRectFilled(.{
        .pmin = .{ origin[0] + 5, origin[1] + height - 3 },
        .pmax = .{ origin[0] + width - 5, origin[1] + height },
        .col = color(umbra.iris),
        .rounding = 2,
    });
    const text_size = zgui.calcTextSize(label, .{});
    draw.addText(.{
        origin[0] + (width - text_size[0]) / 2,
        origin[1] + (height - text_size[1]) / 2 - 1,
    }, color(if (selected) umbra.fg0 else umbra.fg2), "{s}", .{label});
    if (clicked) {
        if (isPicker(view)) app.openPicker(view) else app.core.view = view;
    }
}

fn drawTrackOverview(app: *App) void {
    zgui.textDisabled("MIXER OVERVIEW", .{});
    zgui.sameLine(.{});
    zgui.textColored(umbra.fg2, "{d} channels", .{app.core.session.project.tracks.items.len});
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
    const draw = zgui.getWindowDrawList();

    draw.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + width, origin[1] + height - 2 },
        .col = color(if (selected) umbra.bg3 else if (hovered) umbra.bg2 else umbra.bg1),
        .rounding = 3,
    });
    draw.addRectFilled(.{
        .pmin = .{ origin[0], origin[1] + 6 },
        .pmax = .{ origin[0] + 4, origin[1] + height - 8 },
        .col = color(trackColor(track.color)),
        .rounding = 2,
    });
    draw.addText(.{ origin[0] + 13, origin[1] + 5 }, color(if (selected) umbra.fg0 else umbra.fg1), "{d:0>2}  {s}", .{ index + 1, track.name });
    draw.addText(.{ origin[0] + 41, origin[1] + 23 }, color(umbra.fg3), "{s}", .{rack.label});

    var gain_buf: [24]u8 = undefined;
    const gain = std.fmt.bufPrint(&gain_buf, "{d:.1} dB", .{track.gain_db}) catch "gain";
    var pan_buf: [24]u8 = undefined;
    const pan = if (@abs(track.pan) < 0.005)
        "C"
    else
        std.fmt.bufPrint(&pan_buf, "{c}{d:.2}", .{ if (track.pan < 0) @as(u8, 'L') else 'R', @abs(track.pan) }) catch "pan";
    draw.addText(.{ origin[0] + width - 190, origin[1] + 14 }, color(umbra.fg1), "{s}", .{gain});
    draw.addText(.{ origin[0] + width - 112, origin[1] + 14 }, color(umbra.fg2), "{s}", .{pan});

    var badge_x = origin[0] + width - 9;
    if (track.soloed) {
        badge_x -= 18;
        drawTrackBadge(draw, badge_x, origin[1] + 12, "S", umbra.yellow);
    }
    if (track.muted) {
        badge_x -= 18;
        drawTrackBadge(draw, badge_x, origin[1] + 12, "M", umbra.red);
    }
    if (clicked) app.core.cursor = index;
}

fn drawArrangement(app: *App) void {
    zgui.textDisabled("ARRANGEMENT", .{});
    const track_count = app.core.session.project.tracks.items.len;
    const ticks_per_beat = ws.time_grid.ticks_per_beat;
    const beats_per_bar: u32 = app.core.session.project.beats_per_bar;
    const ticks_per_bar = ws.time_grid.barTicks(app.core.session.project.beats_per_bar);
    const content_ticks = app.core.session.arrangement.lengthTicks();
    const cursor_tick = app.core.arr_cursor_bar * app.core.arr_grid.ticks();
    const cursor_bar_count = cursor_tick / ticks_per_bar + 1;
    const bar_count: u32 = @max(8, @max((content_ticks + ticks_per_bar - 1) / ticks_per_bar, cursor_bar_count));
    zgui.text("{d} tracks   {d} bars", .{ track_count, bar_count });
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

    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(.{ 0.05, 0.06, 0.07, 1 }) });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + ruler_h }, .col = color(.{ 0.085, 0.095, 0.11, 1 }) });

    for (0..track_count) |ti| {
        const y = origin[1] + ruler_h + @as(f32, @floatFromInt(ti)) * lane_h;
        const selected = ti == app.core.cursor;
        draw.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ timeline_x, y + lane_h }, .col = color(if (selected) .{ 0.12, 0.17, 0.18, 1 } else .{ 0.075, 0.085, 0.095, 1 }) });
        draw.addRectFilled(.{ .pmin = .{ timeline_x, y }, .pmax = .{ origin[0] + canvas_w, y + lane_h }, .col = color(if (selected) .{ 0.075, 0.095, 0.10, 1 } else if (ti % 2 == 0) .{ 0.065, 0.075, 0.085, 1 } else .{ 0.055, 0.065, 0.075, 1 }) });
        draw.addText(.{ origin[0] + 10, y + 11 }, color(if (selected) .{ 0.75, 0.95, 0.88, 1 } else .{ 0.68, 0.70, 0.72, 1 }), "{d:0>2}  {s}", .{ ti + 1, app.core.session.project.tracks.items[ti].name });
        draw.addText(.{ origin[0] + 34, y + 32 }, color(.{ 0.36, 0.39, 0.42, 1 }), "{s}", .{@tagName(app.core.session.project.tracks.items[ti].kind)});
        draw.addLine(.{ .p1 = .{ origin[0], y + lane_h }, .p2 = .{ origin[0] + canvas_w, y + lane_h }, .col = color(.{ 0.13, 0.14, 0.16, 1 }), .thickness = 1 });
    }

    for (0..bar_count * beats_per_bar + 1) |beat_index| {
        const x = timeline_x + @as(f32, @floatFromInt(beat_index)) * beat_w;
        const on_bar = beat_index % beats_per_bar == 0;
        draw.addLine(.{ .p1 = .{ x, if (on_bar) origin[1] else origin[1] + ruler_h }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) .{ 0.29, 0.32, 0.35, 1 } else .{ 0.12, 0.135, 0.15, 1 }), .thickness = if (on_bar) 1.5 else 1 });
        if (on_bar and beat_index < bar_count * beats_per_bar) draw.addText(.{ x + 7, origin[1] + 7 }, color(.{ 0.64, 0.67, 0.70, 1 }), "{d}", .{beat_index / beats_per_bar + 1});
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
                .melodic => if (selected) .{ 0.25, 0.78, 0.60, 1 } else .{ 0.16, 0.53, 0.43, 1 },
                .drum => if (selected) .{ 0.82, 0.55, 0.28, 1 } else .{ 0.57, 0.35, 0.17, 1 },
            };
            draw.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = color(clip_color), .rounding = 4 });
            if (selected) draw.addRect(.{ .pmin = pmin, .pmax = pmax, .col = color(.{ 0.85, 1.0, 0.94, 0.95 }), .rounding = 4, .thickness = 2 });
            switch (clip.content) {
                .melodic => |melodic| {
                    draw.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(.{ 0.88, 1.0, 0.95, 1 }), "MIDI  {d}", .{melodic.notes.len});
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
                        draw.addLine(.{ .p1 = .{ note_x, note_y }, .p2 = .{ @min(note_x + note_w, pmax[0] - 2), note_y }, .col = color(.{ 0.70, 0.96, 0.84, 0.8 }), .thickness = 2 });
                    }
                },
                .drum => |drum| {
                    draw.addText(.{ pmin[0] + 7, pmin[1] + 4 }, color(.{ 1.0, 0.91, 0.78, 1 }), "PATTERN {c}", .{'A' + drum.variant});
                    for (0..drum.step_count) |step| {
                        var hits: u8 = 0;
                        for (drum.pattern) |pattern| hits += @intCast((pattern >> @intCast(step)) & 1);
                        if (hits == 0) continue;
                        const hit_x = pmin[0] + (@as(f32, @floatFromInt(step)) + 0.5) / @as(f32, @floatFromInt(drum.step_count)) * (pmax[0] - pmin[0]);
                        const hit_h = @min(15, @as(f32, @floatFromInt(hits)) * 2);
                        draw.addLine(.{ .p1 = .{ hit_x, pmax[1] - 6 }, .p2 = .{ hit_x, pmax[1] - 6 - hit_h }, .col = color(.{ 1.0, 0.82, 0.54, 0.85 }), .thickness = 2 });
                    }
                },
            }
            if (clip.automation.gain.len + clip.automation.pan.len + clip.automation.synth_params.items.len > 0) draw.addText(.{ pmax[0] - 16, pmin[1] + 4 }, color(.{ 0.94, 0.88, 1.0, 1 }), "A", .{});
        }
    }

    if (app.core.cursor < track_count) {
        const cursor_x = timeline_x + @as(f32, @floatFromInt(cursor_tick)) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w;
        const cursor_w = @max(2, @as(f32, @floatFromInt(app.core.arr_grid.ticks())) / @as(f32, @floatFromInt(ticks_per_beat)) * beat_w);
        const cursor_y = origin[1] + ruler_h + @as(f32, @floatFromInt(app.core.cursor)) * lane_h;
        draw.addRectFilled(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ @min(cursor_x + cursor_w, origin[0] + canvas_w - 1), cursor_y + lane_h - 1 },
            .col = color(.{ umbra.iris[0], umbra.iris[1], umbra.iris[2], 0.16 }),
        });
        draw.addRect(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ @min(cursor_x + cursor_w, origin[0] + canvas_w - 1), cursor_y + lane_h - 1 },
            .col = color(umbra.iris),
            .thickness = 2,
        });
    }

    const snap = app.core.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = @as(f64, @floatFromInt(snap.position_frames)) / 48000.0 * @as(f64, app.core.session.project.tempo_bpm) / 60.0;
        const x = timeline_x + @as(f32, @floatCast(play_beat)) * beat_w;
        if (x <= origin[0] + canvas_w) draw.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(.{ 1.0, 0.34, 0.28, 0.95 }), .thickness = 2 });
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

fn drawPianoRoll(app: *App) void {
    zgui.textDisabled("PIANO ROLL", .{});
    const rack = app.core.session.racks.items[app.core.cursor];
    const pp = if (rack.pattern_player) |*p| p else {
        zgui.textDisabled("This instrument has no melodic pattern. Choose Synth or Sampler.", .{});
        return;
    };
    zgui.text("{d} notes   {d:.1} beats   1/16 grid", .{ pp.note_count, pp.length_beats });
    zgui.sameLine(.{ .spacing = 18 });
    zgui.textDisabled("click to draw / erase", .{});

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
    const clicked = zgui.invisibleButton("piano-roll-canvas", .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw = zgui.getWindowDrawList();
    const grid_x = origin[0] + gutter_w;
    const grid_y = origin[1] + ruler_h;
    const grid_w = canvas_w - gutter_w;
    const beats: f32 = @floatCast(@max(1.0, pp.length_beats));
    const beat_w = grid_w / beats;

    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(.{ 0.055, 0.065, 0.075, 1 }) });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + gutter_w, origin[1] + ruler_h }, .col = color(.{ 0.09, 0.10, 0.12, 1 }) });

    for (0..row_count) |row| {
        const pitch: u7 = top_pitch - @as(u7, @intCast(row));
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        const black = isBlackKey(pitch);
        draw.addRectFilled(.{ .pmin = .{ grid_x, y }, .pmax = .{ origin[0] + canvas_w, y + row_h }, .col = color(if (black) .{ 0.07, 0.08, 0.09, 1 } else .{ 0.095, 0.105, 0.115, 1 }) });
        draw.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ grid_x, y + row_h }, .col = color(if (black) .{ 0.10, 0.11, 0.12, 1 } else .{ 0.76, 0.77, 0.74, 1 }) });
        if (black) draw.addRectFilled(.{ .pmin = .{ origin[0], y + 1 }, .pmax = .{ origin[0] + 37, y + row_h - 1 }, .col = color(.{ 0.025, 0.03, 0.035, 1 }) });
        draw.addLine(.{ .p1 = .{ origin[0], y + row_h }, .p2 = .{ origin[0] + canvas_w, y + row_h }, .col = color(.{ 0.15, 0.16, 0.17, 1 }), .thickness = if (@mod(pitch, 12) == 0) 1.5 else 1 });
        if (@mod(pitch, 12) == 0) draw.addText(.{ origin[0] + 40, y + 1 }, color(.{ 0.20, 0.22, 0.24, 1 }), "C{d}", .{pitch / 12 - 1});
    }

    const steps_per_beat: usize = app.core.pianoStepsPerBeat();
    const steps: usize = @intFromFloat(@ceil(beats * @as(f32, @floatFromInt(steps_per_beat))));
    for (0..steps + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const on_beat = step % steps_per_beat == 0;
        const on_bar = step % (steps_per_beat * app.core.session.project.beats_per_bar) == 0;
        draw.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) .{ 0.34, 0.37, 0.40, 1 } else if (on_beat) .{ 0.24, 0.26, 0.28, 1 } else .{ 0.13, 0.14, 0.15, 1 }), .thickness = if (on_bar) 2 else 1 });
        if (on_beat and step < steps) draw.addText(.{ x + 5, origin[1] + 4 }, color(.{ 0.62, 0.65, 0.68, 1 }), "{d}.{d}", .{ step / (steps_per_beat * app.core.session.project.beats_per_bar) + 1, step / steps_per_beat % app.core.session.project.beats_per_bar + 1 });
    }

    while (!pp.notes_lock.tryLock()) std.atomic.spinLoopHint();
    for (pp.notes[0..pp.note_count]) |note| {
        if (note.pitch < bottom_pitch or note.pitch > top_pitch) continue;
        const x = grid_x + @as(f32, @floatCast(note.start_beat)) * beat_w;
        const width = @max(3, @as(f32, @floatCast(note.duration_beat)) * beat_w - 2);
        const y = grid_y + @as(f32, @floatFromInt(top_pitch - note.pitch)) * row_h + 2;
        const brightness = 0.52 + std.math.clamp(note.velocity, 0, 1) * 0.30;
        draw.addRectFilled(.{ .pmin = .{ x + 1, y }, .pmax = .{ @min(x + width, origin[0] + canvas_w - 1), y + row_h - 4 }, .col = color(.{ 0.18, brightness, 0.56, 1 }), .rounding = 3 });
        draw.addLine(.{ .p1 = .{ x + 3, y + 2 }, .p2 = .{ x + 3, y + row_h - 6 }, .col = color(.{ 0.72, 1.0, 0.88, 0.75 }), .thickness = 2 });
    }
    pp.notes_lock.unlock();

    if (app.core.piano_cursor_pitch >= bottom_pitch and app.core.piano_cursor_pitch <= top_pitch and app.core.piano_cursor_step < steps) {
        const cursor_x = grid_x + @as(f32, @floatFromInt(app.core.piano_cursor_step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const cursor_y = grid_y + @as(f32, @floatFromInt(top_pitch - app.core.piano_cursor_pitch)) * row_h;
        const cursor_w = beat_w / @as(f32, @floatFromInt(steps_per_beat));
        draw.addRectFilled(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ cursor_x + cursor_w - 1, cursor_y + row_h - 1 },
            .col = color(.{ umbra.iris[0], umbra.iris[1], umbra.iris[2], 0.18 }),
            .rounding = 2,
        });
        draw.addRect(.{
            .pmin = .{ cursor_x + 1, cursor_y + 1 },
            .pmax = .{ cursor_x + cursor_w - 1, cursor_y + row_h - 1 },
            .col = color(umbra.iris),
            .rounding = 2,
            .thickness = 2,
        });
    }

    const snap = app.core.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = @mod(@as(f64, @floatFromInt(snap.position_frames)) / 48000.0 * @as(f64, app.core.session.project.tempo_bpm) / 60.0, pp.length_beats);
        const x = grid_x + @as(f32, @floatCast(play_beat)) * beat_w;
        draw.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(.{ 1.0, 0.34, 0.28, 0.95 }), .thickness = 2 });
    }

    if (hovered and mouse[0] >= grid_x and mouse[1] >= grid_y) {
        const step = @min(steps - 1, @as(usize, @intFromFloat((mouse[0] - grid_x) / (beat_w / @as(f32, @floatFromInt(steps_per_beat))))));
        const row = @min(row_count - 1, @as(usize, @intFromFloat((mouse[1] - grid_y) / row_h)));
        const x = grid_x + @as(f32, @floatFromInt(step)) * beat_w / @as(f32, @floatFromInt(steps_per_beat));
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        draw.addRectFilled(.{ .pmin = .{ x + 1, y + 1 }, .pmax = .{ x + beat_w / @as(f32, @floatFromInt(steps_per_beat)) - 1, y + row_h - 1 }, .col = color(.{ 0.48, 0.91, 0.72, 0.18 }), .rounding = 2 });
        if (clicked) {
            const pitch: u7 = top_pitch - @as(u7, @intCast(row));
            app.core.piano_cursor_pitch = pitch;
            app.core.piano_cursor_step = @intCast(step);
            const beat = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps_per_beat));
            if (pp.noteAt(pitch, beat)) |_| pp.removeNote(pitch, beat) else pp.addNote(.{
                .pitch = pitch,
                .start_beat = beat,
                .duration_beat = 1.0 / @as(f64, @floatFromInt(steps_per_beat)),
                .velocity = 0.85,
            });
        }
    }
}

fn isBlackKey(pitch: u7) bool {
    return switch (@mod(pitch, 12)) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

fn drawDrumGrid(app: *App) void {
    const rack = app.core.session.racks.items[app.core.cursor];
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
    step_grid.draw(.drum, drum, drum.pads.len, drum.step_count, play_step, &app.core.drum_cursor);
}

fn drawDrumHeader(app: *App, drum: *ws.dsp.DrumMachine, playing: bool) void {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("drum-header", .{ .w = width, .h = 62 });
    const draw = zgui.getWindowDrawList();
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 62 }, .col = color(umbra.bg2), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + 62 }, .col = color(if (playing) umbra.red else umbra.yellow), .rounding = 3 });
    draw.addText(.{ origin[0] + 17, origin[1] + 9 }, color(umbra.fg3), "DRUM MACHINE", .{});
    draw.addText(.{ origin[0] + 17, origin[1] + 31 }, color(umbra.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.cursor].name});

    const mode = if (drum.song_mode) "SONG" else "PATTERN";
    const state = if (playing) "PLAYING" else "STOPPED";
    draw.addText(.{ origin[0] + width - 360, origin[1] + 11 }, color(if (playing) umbra.red else umbra.fg2), "{s}", .{state});
    draw.addText(.{ origin[0] + width - 270, origin[1] + 11 }, color(umbra.yellow), "{s} {c}", .{ mode, 'A' + drum.variant });
    draw.addText(.{ origin[0] + width - 150, origin[1] + 11 }, color(umbra.fg1), "{d} STEPS", .{drum.step_count});
    draw.addText(.{ origin[0] + width - 360, origin[1] + 34 }, color(umbra.fg3), "1/{d} GRID", .{drum.steps_per_beat * 4});
    draw.addText(.{ origin[0] + width - 270, origin[1] + 34 }, color(umbra.fg3), "{d:.0}% SWING", .{drum.swing.load(.monotonic)});
    draw.addText(.{ origin[0] + width - 150, origin[1] + 34 }, color(umbra.fg3), "VARIANT {d}/{d}", .{ drum.variant + 1, drum.variant_count });
}

fn drawDevices(app: *App) void {
    const rack = app.core.session.racks.items[app.core.cursor];
    zgui.textDisabled("DEVICE CHAIN", .{});
    zgui.sameLine(.{});
    zgui.textColored(umbra.fg2, "{d} effects", .{rack.fx.units.items.len});
    zgui.separator();
    drawInstrumentCard(rack);
    zgui.spacing();
    zgui.textDisabled("EFFECTS", .{});
    if (rack.fx.units.items.len == 0) {
        zgui.spacing();
        zgui.textColored(umbra.fg3, "The signal path is clean.", .{});
        zgui.textDisabled("Add an effect to shape this track.", .{});
        zgui.spacing();
    }
    for (rack.fx.units.items, 0..) |unit, i| {
        const action = drawFxCard(unit, i);
        if (action == .bypass) {
            unit.bypassed = !unit.bypassed;
            app.core.session.syncTrackChain(@intCast(app.core.cursor), rack);
        } else if (action == .remove) {
            rack.fx.remove(app.core.session.allocator, i);
            app.core.session.syncTrackChain(@intCast(app.core.cursor), rack);
            break;
        }
    }
    zgui.spacing();
    zgui.pushStyleColor4f(.{ .idx = .button, .c = umbra.iris_soft });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = umbra.iris });
    if (zgui.button("+  ADD EFFECT", .{ .w = 150, .h = 32 })) app.openPicker(.fx_picker);
    zgui.popStyleColor(.{ .count = 2 });
}

fn drawInstrumentCard(rack: *ws.Rack) void {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("instrument-card", .{ .w = width, .h = 54 });
    const draw = zgui.getWindowDrawList();
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 54 }, .col = color(umbra.bg2), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = .{ origin[0], origin[1] + 6 }, .pmax = .{ origin[0] + 4, origin[1] + 48 }, .col = color(umbra.iris), .rounding = 2 });
    draw.addText(.{ origin[0] + 14, origin[1] + 8 }, color(umbra.fg3), "INSTRUMENT", .{});
    draw.addText(.{ origin[0] + 14, origin[1] + 27 }, color(umbra.fg0), "{s}", .{rack.label});
}

const FxCardAction = enum { none, bypass, remove };

fn drawFxCard(unit: *ws.FxUnit, index: usize) FxCardAction {
    const width = zgui.getContentRegionAvail()[0];
    const origin = zgui.getCursorScreenPos();
    var card_id_buf: [32]u8 = undefined;
    const card_id = std.fmt.bufPrintZ(&card_id_buf, "fx-card-{d}", .{index}) catch return .none;
    _ = zgui.invisibleButton(card_id, .{ .w = width, .h = 58 });
    const draw = zgui.getWindowDrawList();
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + 56 }, .col = color(umbra.bg2), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = .{ origin[0], origin[1] + 7 }, .pmax = .{ origin[0] + 4, origin[1] + 49 }, .col = color(if (unit.bypassed) umbra.fg3 else umbra.cyan), .rounding = 2 });
    draw.addText(.{ origin[0] + 14, origin[1] + 9 }, color(umbra.fg3), "FX {d:0>2}", .{index + 1});
    draw.addText(.{ origin[0] + 14, origin[1] + 29 }, color(if (unit.bypassed) umbra.fg3 else umbra.fg0), "{s}", .{@tagName(unit.kind())});

    zgui.setCursorScreenPos(.{ origin[0] + width - 154, origin[1] + 14 });
    var bypass_id_buf: [32]u8 = undefined;
    const bypass_id = std.fmt.bufPrintZ(&bypass_id_buf, "{s}##fx-bypass-{d}", .{ if (unit.bypassed) "ENABLE" else "BYPASS", index }) catch return .none;
    var action: FxCardAction = if (drawInspectorToggle(bypass_id, unit.bypassed, umbra.red, 82)) .bypass else .none;
    zgui.sameLine(.{ .spacing = 6 });
    var remove_id_buf: [32]u8 = undefined;
    const remove_id = std.fmt.bufPrintZ(&remove_id_buf, "X##fx-remove-{d}", .{index}) catch return .none;
    if (zgui.button(remove_id, .{ .w = 42, .h = 30 })) action = .remove;
    zgui.setCursorScreenPos(.{ origin[0], origin[1] + 58 });
    return action;
}

fn drawSynth(app: *App) void {
    const synth = switch (app.core.session.racks.items[app.core.cursor].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a Synth track.", .{});
            return;
        },
    };
    drawSynthHeader(app, synth);
    zgui.spacing();

    const gap: f32 = 10;
    const column_w = @max(300, (zgui.getContentRegionAvail()[0] - gap) / 2);
    if (zgui.beginChild("synth-left", .{ .w = column_w, .h = 0, .child_flags = .{ .border = true } })) {
        drawSynthSectionTitle("OSCILLATORS", umbra.iris);
        drawSynthWaveButtons(app, synth);
        drawSynthParam(app, synth, 2, "Fine tune", "%.0f ct");
        drawSynthParam(app, synth, 3, "Voices", "%.0f");
        drawSynthParam(app, synth, 4, "Unison detune", "%.0f ct");
        drawSynthParam(app, synth, 5, "Stereo spread", "%.2f");
        zgui.spacing();
        drawSynthSectionTitle("OSCILLATOR B", umbra.cyan);
        drawSynthParam(app, synth, 9, "Transpose", "%.0f st");
        drawSynthParam(app, synth, 10, "Fine tune", "%.0f ct");
        drawSynthParam(app, synth, 11, "Level", "%.2f");
        zgui.spacing();
        drawSynthSectionTitle("OUTPUT", umbra.mauve);
        drawSynthParam(app, synth, 34, "Sub", "%.2f");
        drawSynthParam(app, synth, 36, "Noise", "%.2f");
        drawSynthParam(app, synth, 38, "Gain", "%.2f");
    }
    zgui.endChild();
    zgui.sameLine(.{ .spacing = gap });
    if (zgui.beginChild("synth-right", .{ .w = 0, .h = 0, .child_flags = .{ .border = true } })) {
        drawSynthSectionTitle("AMPLIFIER ENVELOPE", umbra.yellow);
        drawSynthParam(app, synth, 16, "Attack", "%.3f s");
        drawSynthParam(app, synth, 17, "Decay", "%.3f s");
        drawSynthParam(app, synth, 18, "Sustain", "%.2f");
        drawSynthParam(app, synth, 19, "Release", "%.3f s");
        zgui.spacing();
        drawSynthSectionTitle("FILTER", umbra.yellow);
        zgui.textColored(umbra.fg2, "{s}", .{@tagName(synth.filter_type)});
        drawSynthParam(app, synth, 21, "Cutoff", "%.0f Hz");
        drawSynthParam(app, synth, 22, "Resonance", "%.2f");
        zgui.spacing();
        drawSynthSectionTitle("FILTER ENVELOPE", umbra.red);
        drawSynthParam(app, synth, 24, "Attack", "%.3f s");
        drawSynthParam(app, synth, 25, "Decay", "%.3f s");
        drawSynthParam(app, synth, 26, "Sustain", "%.2f");
        drawSynthParam(app, synth, 27, "Release", "%.3f s");
    }
    zgui.endChild();
}

fn drawSynthHeader(app: *App, synth: *ws.dsp.PolySynth) void {
    const width = zgui.getContentRegionAvail()[0];
    const height: f32 = 156;
    const origin = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("synth-overview", .{ .w = width, .h = height });
    const draw = zgui.getWindowDrawList();
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + width, origin[1] + height }, .col = color(umbra.bg2), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 5, origin[1] + height }, .col = color(umbra.iris), .rounding = 3 });
    draw.addText(.{ origin[0] + 17, origin[1] + 10 }, color(umbra.fg3), "POLYPHONIC SYNTH", .{});
    draw.addText(.{ origin[0] + 17, origin[1] + 31 }, color(umbra.fg0), "{s}", .{app.core.session.project.tracks.items[app.core.cursor].name});

    const panel_y = origin[1] + 59;
    const panel_h: f32 = 80;
    const panel_gap: f32 = 9;
    const panel_w = (width - 43 - panel_gap * 2) / 3;
    drawSynthOverviewPanel(draw, .{ origin[0] + 17, panel_y }, .{ panel_w, panel_h }, "OSCILLATOR", umbra.iris);
    drawSynthOverviewPanel(draw, .{ origin[0] + 17 + panel_w + panel_gap, panel_y }, .{ panel_w, panel_h }, "ENVELOPE", umbra.yellow);
    drawSynthOverviewPanel(draw, .{ origin[0] + 17 + (panel_w + panel_gap) * 2, panel_y }, .{ panel_w, panel_h }, "FILTER", umbra.cyan);
    drawOscillatorShape(draw, .{ origin[0] + 29, panel_y + 31 }, .{ panel_w - 24, 35 }, synth.waveform);
    drawEnvelopeShape(draw, .{ origin[0] + 29 + panel_w + panel_gap, panel_y + 31 }, .{ panel_w - 24, 35 }, synth);
    drawFilterShape(draw, .{ origin[0] + 29 + (panel_w + panel_gap) * 2, panel_y + 31 }, .{ panel_w - 24, 35 }, synth);
}

fn drawSynthOverviewPanel(draw: zgui.DrawList, pos: [2]f32, size: [2]f32, label: []const u8, accent: [4]f32) void {
    draw.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + size[0], pos[1] + size[1] }, .col = color(umbra.bg1), .rounding = 3 });
    draw.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + 3, pos[1] + size[1] }, .col = color(accent), .rounding = 2 });
    draw.addText(.{ pos[0] + 12, pos[1] + 8 }, color(umbra.fg3), "{s}", .{label});
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
        if (i > 1) draw.addLine(.{ .p1 = prev, .p2 = point, .col = color(umbra.iris), .thickness = 2 });
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
    for (0..points.len - 1) |i| draw.addLine(.{ .p1 = points[i], .p2 = points[i + 1], .col = color(umbra.yellow), .thickness = 2 });
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
            draw.addLine(.{ .p1 = left, .p2 = .{ knee_x, peak_y }, .col = color(umbra.cyan), .thickness = 2 });
            draw.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = bottom_right, .col = color(umbra.cyan), .thickness = 2 });
        },
        .hp => {
            draw.addLine(.{ .p1 = bottom_left, .p2 = .{ knee_x, peak_y }, .col = color(umbra.cyan), .thickness = 2 });
            draw.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = right, .col = color(umbra.cyan), .thickness = 2 });
        },
        .bp, .formant => {
            draw.addLine(.{ .p1 = bottom_left, .p2 = .{ knee_x, peak_y }, .col = color(umbra.cyan), .thickness = 2 });
            draw.addLine(.{ .p1 = .{ knee_x, peak_y }, .p2 = bottom_right, .col = color(umbra.cyan), .thickness = 2 });
        },
        .notch, .comb => {
            draw.addLine(.{ .p1 = left, .p2 = .{ knee_x, pos[1] + size[1] * 0.85 }, .col = color(umbra.cyan), .thickness = 2 });
            draw.addLine(.{ .p1 = .{ knee_x, pos[1] + size[1] * 0.85 }, .p2 = right, .col = color(umbra.cyan), .thickness = 2 });
        },
    }
}

fn drawSynthSectionTitle(label: []const u8, accent: [4]f32) void {
    zgui.textColored(accent, "{s}", .{label});
    zgui.separator();
}

fn drawSynthWaveButtons(app: *App, synth: *const ws.dsp.PolySynth) void {
    const entries = [_]struct { label: [:0]const u8, waveform: ws.dsp.synth.Waveform }{
        .{ .label = "SINE", .waveform = .sine }, .{ .label = "SAW", .waveform = .saw }, .{ .label = "TRI", .waveform = .triangle }, .{ .label = "SQUARE", .waveform = .square }, .{ .label = "WT", .waveform = .wavetable },
    };
    for (entries, 0..) |entry, i| {
        if (i > 0) zgui.sameLine(.{ .spacing = 4 });
        const active = synth.waveform == entry.waveform;
        const focused = app.core.synth_cursor == 0;
        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) umbra.iris else if (focused) umbra.bg4 else umbra.bg2 });
        zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) umbra.bg0 else if (focused) umbra.iris else umbra.fg2 });
        if (zgui.button(entry.label, .{ .h = 28 })) {
            app.core.synth_cursor = 0;
            _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = @intCast(app.core.cursor), .id = 0, .value = @floatFromInt(@intFromEnum(entry.waveform)) } });
        }
        zgui.popStyleColor(.{ .count = 2 });
    }
}

fn drawSynthParam(app: *App, synth: *ws.dsp.PolySynth, id: u8, label_text: []const u8, format: [:0]const u8) void {
    const param = ws.dsp.PolySynth.findAutomatableParam(id) orelse return;
    var value = synth.paramValue(id) orelse return;
    var label: [80]u8 = undefined;
    const zlabel = std.fmt.bufPrintZ(&label, "{s}##gui-synth-{d}", .{ label_text, id }) catch return;
    const focused = app.core.synth_cursor == id;
    gui_style.pushControlFocus(focused, umbra.iris);
    defer gui_style.popControlFocus(focused);
    if (zgui.sliderFloat(zlabel, .{ .v = &value, .min = param.range[0], .max = param.range[1], .cfmt = format })) {
        _ = app.core.session.engine.send(.{ .set_track_param_abs = .{ .track = @intCast(app.core.cursor), .id = id, .value = value } });
    }
    if (zgui.isItemActivated()) app.core.synth_cursor = id;
}

fn drawInspector(app: *App) void {
    const layout = Layout.current(app.core.modal.mode == .command or app.core.modal.mode == .search);
    zgui.setNextWindowPos(.{ .x = layout.browser_w + layout.tracks_w + layout.workspace_w, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = layout.inspector_w, .h = layout.body_h, .cond = .always });
    if (zgui.begin("Inspector", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        const track = &app.core.session.project.tracks.items[app.core.cursor];
        const rack = app.core.session.racks.items[app.core.cursor];
        zgui.textDisabled("INSPECTOR", .{});
        zgui.separator();
        const accent = trackColor(track.color);
        zgui.textColored(accent, "{d:0>2}", .{app.core.cursor + 1});
        zgui.sameLine(.{});
        zgui.textColored(umbra.fg0, "{s}", .{track.name});
        zgui.textColored(umbra.fg3, "{s}", .{rack.label});
        zgui.spacing();
        zgui.separatorText("MIX");

        zgui.textDisabled("GAIN", .{});
        if (zgui.sliderFloat("##gain", .{ .v = &track.gain_db, .min = -60, .max = 12, .cfmt = "%.1f dB" })) {
            _ = app.core.session.engine.send(.{ .set_track_gain = .{
                .track = @intCast(app.core.cursor),
                .gain = ws.types.dbToGain(track.gain_db),
            } });
        }
        zgui.spacing();
        zgui.textDisabled("PAN", .{});
        if (zgui.sliderFloat("##pan", .{ .v = &track.pan, .min = -1, .max = 1, .cfmt = "%.2f" })) {
            _ = app.core.session.engine.send(.{ .set_track_pan = .{ .track = @intCast(app.core.cursor), .pan = track.pan } });
        }
        zgui.spacing();
        const toggle_width = (zgui.getContentRegionAvail()[0] - 6) / 2;
        if (drawInspectorToggle("MUTE##inspector", track.muted, umbra.red, toggle_width)) {
            track.muted = !track.muted;
            _ = app.core.session.engine.send(.{ .set_track_mute = .{ .track = @intCast(app.core.cursor), .muted = track.muted } });
        }
        zgui.sameLine(.{ .spacing = 6 });
        if (drawInspectorToggle("SOLO##inspector", track.soloed, umbra.yellow, toggle_width)) {
            track.soloed = !track.soloed;
            _ = app.core.session.engine.send(.{ .set_track_solo = .{ .track = @intCast(app.core.cursor), .soloed = track.soloed } });
        }
    }
    zgui.end();
}

fn drawInspectorToggle(label: [:0]const u8, active: bool, accent: [4]f32, width: f32) bool {
    zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) accent else umbra.bg2 });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (active) accent else umbra.bg3 });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = umbra.fg0 });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = if (active) umbra.bg0 else umbra.fg2 });
    defer zgui.popStyleColor(.{ .count = 4 });
    return zgui.button(label, .{ .w = width, .h = 30 });
}

fn drawStatus(app: *App, audio_label: []const u8) void {
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = display[1] - 34, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = 34, .cond = .always });
    if (zgui.begin("Status", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true } })) {
        const draw = zgui.getWindowDrawList();
        const pos = zgui.getWindowPos();
        const size = zgui.getWindowSize();
        draw.addRectFilled(.{ .pmin = pos, .pmax = .{ pos[0] + size[0], pos[1] + size[1] }, .col = color(umbra.bg1) });

        var x = pos[0];
        x = drawStatusSegment(draw, x, pos[1], size[1], umbra.iris, umbra.bg0, @tagName(app.core.modal.mode));
        x = drawStatusSegment(draw, x, pos[1], size[1], umbra.bg4, umbra.fg0, @tagName(app.core.view));

        var track_buf: [160]u8 = undefined;
        const track_label = if (app.core.cursor < app.core.session.project.tracks.items.len) blk: {
            const track = app.core.session.project.tracks.items[app.core.cursor];
            break :blk std.fmt.bufPrint(&track_buf, "{d:0>2}  {s}", .{ app.core.cursor + 1, track.name }) catch "track";
        } else "MASTER";
        x = drawStatusSegment(draw, x, pos[1], size[1], umbra.bg2, umbra.fg1, track_label);

        const status = app.core.statusText();
        const status_size = zgui.calcTextSize(status, .{});
        if (status.len > 0 and x + status_size[0] + 260 < pos[0] + size[0]) {
            draw.addText(.{ x + 12, pos[1] + (size[1] - status_size[1]) / 2 }, color(umbra.fg1), "{s}", .{status});
        }

        const snap = app.core.session.engine.uiSnapshot();
        const beat = ws.types.framesToSeconds(snap.position_frames, app.core.session.project.sample_rate) * app.core.session.project.tempo_bpm / 60.0;
        var right_buf: [192]u8 = undefined;
        const right_label = std.fmt.bufPrint(&right_buf, "{s}  {d}.{d}   AUDIO {s}", .{
            if (snap.playing) "PLAY" else "STOP",
            @as(u32, @intFromFloat(beat)) / app.core.session.project.beats_per_bar + 1,
            @mod(@as(u32, @intFromFloat(beat)), app.core.session.project.beats_per_bar) + 1,
            audio_label,
        }) catch "audio";
        drawStatusSegmentRight(draw, pos[0] + size[0], pos[1], size[1], if (snap.playing) umbra.iris_soft else umbra.bg2, umbra.fg0, right_label);
    }
    zgui.end();
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
    const count = tui_cmd.suggestionCount(tui_commands.cmds, filter, active);
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
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + size[0], origin[1] + size[1] }, .col = color(umbra.bg1), .rounding = 4 });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + 4, origin[1] + size[1] }, .col = color(umbra.iris), .rounding = 2 });
    draw.addText(.{ origin[0] + 14, origin[1] + 8 }, color(umbra.fg3), "COMMANDS", .{});
    draw.addText(.{ origin[0] + size[0] - 96, origin[1] + 8 }, color(umbra.fg3), "TAB TO CYCLE", .{});

    const selected = app.core.suggestionSelected(active);
    var match_index: usize = 0;
    var drawn: usize = 0;
    for (tui_commands.cmds) |command| {
        if (tui_cmd.hiddenFromCompletion(command) or !tui_cmd.visible(command, active)) continue;
        if (!std.mem.startsWith(u8, command.name, filter)) continue;
        if (drawn >= max_rows) break;
        const y = origin[1] + 30 + @as(f32, @floatFromInt(drawn)) * 39;
        const is_selected = match_index == selected;
        if (is_selected) {
            draw.addRectFilled(.{ .pmin = .{ origin[0] + 7, y }, .pmax = .{ origin[0] + size[0] - 7, y + 35 }, .col = color(umbra.bg4), .rounding = 3 });
            draw.addRectFilled(.{ .pmin = .{ origin[0] + 7, y }, .pmax = .{ origin[0] + 10, y + 35 }, .col = color(umbra.iris), .rounding = 2 });
        }
        draw.addText(.{ origin[0] + 20, y + 4 }, color(if (is_selected) umbra.fg0 else umbra.fg1), ":{s}", .{command.name});
        draw.addText(.{ origin[0] + 185, y + 4 }, color(if (is_selected) umbra.fg2 else umbra.fg3), "{s}", .{command.desc});
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
        .col = color(umbra.bg2),
    });
    draw.addRectFilled(.{
        .pmin = pos,
        .pmax = .{ pos[0] + 4, pos[1] + size[1] },
        .col = color(umbra.iris),
    });
    draw.addText(.{ prompt_x, text_y }, color(umbra.iris), "{s}", .{prompt});
    draw.addText(.{ input_x, text_y }, color(umbra.fg0), "{s}", .{input});

    if (app.core.modal.mode == .command) {
        if (std.mem.indexOfScalar(u8, input, ' ')) |space| {
            const name = input[0..space];
            for (tui_commands.cmds) |command| {
                if (!std.mem.eql(u8, command.name, name)) continue;
                const hint_x = input_x + zgui.calcTextSize(input, .{})[0] + 18;
                draw.addText(.{ hint_x, text_y }, color(umbra.fg3), "{s}", .{command.desc});
                break;
            }
        }
        draw.addText(.{ pos[0] + size[0] - 150, text_y }, color(umbra.fg3), "TAB complete   ESC close", .{});
    } else {
        draw.addText(.{ pos[0] + size[0] - 102, text_y }, color(umbra.fg3), "ENTER search", .{});
    }

    const before_cursor = input[0..app.core.modal.cmd_cursor];
    const cursor_x = input_x + zgui.calcTextSize(before_cursor, .{})[0];
    draw.addRectFilled(.{
        .pmin = .{ cursor_x, text_y },
        .pmax = .{ cursor_x + 1, text_y + zgui.getTextLineHeight() },
        .col = color(umbra.fg0),
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
