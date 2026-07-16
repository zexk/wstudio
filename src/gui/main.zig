//! Experimental desktop frontend. The engine remains frontend-neutral; this
//! file owns only GLFW/ImGui lifecycle and GUI-specific presentation state.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const glfw = @import("zglfw");
const zgui = @import("zgui");
const zopengl = @import("zopengl");

const gl = zopengl.bindings;

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ws.Session,
    selected_track: usize = 0,
    view: View = .arrangement,
    browser_dir: []u8 = &.{},
    browser_entries: std.ArrayListUnmanaged(BrowserEntry) = .empty,
    pending_project_path: ?[]u8 = null,
    arrangement_clip: ?struct { track: usize, clip: usize } = null,
    automation_clip: usize = 0,
    automation_target: AutomationTarget = .gain,
    automation_beat: f32 = 0,
    automation_value: f32 = 0,

    const BrowserEntry = struct { name: []u8, is_dir: bool };
    const AutomationTarget = enum { gain, pan };

    const View = enum {
        tracks,
        arrangement,
        piano_roll,
        drum_grid,
        slicer_grid,
        synth,
        sampler,
        devices,
        spectrum,
        automation,
        instrument_picker,
        fx_picker,
        preset_picker,
        file_browser,
        help,
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8) !App {
        const session = if (init_path) |path|
            try ws.persist.load(allocator, io, path)
        else
            try ws.Session.initDefault(allocator);
        return .{ .allocator = allocator, .io = io, .session = session };
    }

    fn deinit(self: *App) void {
        self.clearBrowser();
        self.browser_entries.deinit(self.allocator);
        if (self.browser_dir.len > 0) self.allocator.free(self.browser_dir);
        if (self.pending_project_path) |path| self.allocator.free(path);
        self.session.deinit();
    }

    fn clearBrowser(self: *App) void {
        for (self.browser_entries.items) |entry| self.allocator.free(entry.name);
        self.browser_entries.clearRetainingCapacity();
    }

    fn setBrowserDir(self: *App, path: []const u8) !void {
        const canon = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
        errdefer self.allocator.free(canon);
        var dir = try std.Io.Dir.cwd().openDir(self.io, canon, .{ .iterate = true });
        defer dir.close(self.io);
        var entries: std.ArrayListUnmanaged(BrowserEntry) = .empty;
        errdefer {
            for (entries.items) |entry| self.allocator.free(entry.name);
            entries.deinit(self.allocator);
        }
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const is_dir = entry.kind == .directory;
            if (!is_dir and !std.ascii.endsWithIgnoreCase(entry.name, ".wsj")) continue;
            try entries.append(self.allocator, .{ .name = try self.allocator.dupe(u8, entry.name), .is_dir = is_dir });
        }
        std.mem.sort(BrowserEntry, entries.items, {}, struct {
            fn less(_: void, a: BrowserEntry, b: BrowserEntry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);
        self.clearBrowser();
        self.browser_entries.deinit(self.allocator);
        if (self.browser_dir.len > 0) self.allocator.free(self.browser_dir);
        self.browser_dir = canon;
        self.browser_entries = entries;
    }

    fn activateBrowserEntry(self: *App, entry: BrowserEntry) void {
        const joined = std.fs.path.join(self.allocator, &.{ self.browser_dir, entry.name }) catch return;
        if (entry.is_dir) {
            defer self.allocator.free(joined);
            self.setBrowserDir(joined) catch {};
        } else {
            if (self.pending_project_path) |old| self.allocator.free(old);
            self.pending_project_path = joined;
        }
    }

    fn draw(self: *App, audio_label: []const u8) void {
        drawTransport(self);
        drawBrowser(self);
        drawTracks(self);
        drawWorkspace(self);
        drawInspector(self);
        drawStatus(self, audio_label);
    }

    fn handleShortcuts(self: *App) void {
        if (zgui.isKeyPressed(.space, false)) {
            const playing = self.session.engine.uiSnapshot().playing;
            _ = self.session.engine.send(if (playing) .stop else .play);
        }
        if ((zgui.isKeyPressed(.j, false) or zgui.isKeyPressed(.down_arrow, false)) and
            self.selected_track + 1 < self.session.project.tracks.items.len)
            self.selected_track += 1;
        if ((zgui.isKeyPressed(.k, false) or zgui.isKeyPressed(.up_arrow, false)) and self.selected_track > 0)
            self.selected_track -= 1;
        if (zgui.isKeyPressed(.h, false) or zgui.isKeyPressed(.left_arrow, false)) self.changeView(-1);
        if (zgui.isKeyPressed(.l, false) or zgui.isKeyPressed(.right_arrow, false)) self.changeView(1);
        if (zgui.isKeyPressed(.f1, false)) self.view = .help;
    }

    fn changeView(self: *App, delta: i8) void {
        const count = @typeInfo(View).@"enum".fields.len;
        const current: usize = @intFromEnum(self.view);
        const next = if (delta < 0) (current + count - 1) % count else (current + 1) % count;
        self.view = @enumFromInt(next);
    }
};

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

    fn current() Layout {
        const display = zgui.io.getDisplaySize();
        const browser_w = std.math.clamp(display[0] * 0.14, 140, 220);
        const tracks_w = std.math.clamp(display[0] * 0.18, 180, 260);
        const inspector_w = std.math.clamp(display[0] * 0.16, 180, 240);
        return .{
            .browser_w = browser_w,
            .tracks_w = tracks_w,
            .workspace_w = display[0] - browser_w - tracks_w - inspector_w,
            .inspector_w = inspector_w,
            .body_h = display[1] - 98,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const init_path = args.next();

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
    zgui.plot.init();
    defer zgui.plot.deinit();
    zgui.io.setConfigFlags(.{ .nav_enable_keyboard = true });
    zgui.io.setIniFilename(null);
    setTheme();
    zgui.backend.init(window);
    defer zgui.backend.deinit();

    var app = App.init(init.gpa, init.io, init_path) catch |err| {
        if (init_path) |path| std.debug.print("wstudio-gui: cannot load '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer app.deinit();
    if (init_path) |path| {
        var title_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrintZ(&title_buf, "wstudio GUI prototype - {s}", .{path})) |title| window.setTitle(title) else |_| {}
    }
    var audio = GuiAudio.init(app.session.project.sample_rate, app.session.engine);
    try audio.start(init.io);
    defer audio.stop();

    while (!window.shouldClose()) {
        glfw.pollEvents();
        if (app.pending_project_path) |path| {
            app.pending_project_path = null;
            defer init.gpa.free(path);
            if (ws.persist.load(init.gpa, init.io, path)) |loaded| {
                audio.stop();
                app.session.deinit();
                app.session = loaded;
                app.selected_track = 0;
                app.automation_clip = 0;
                audio = GuiAudio.init(app.session.project.sample_rate, app.session.engine);
                try audio.start(init.io);
                var title_buf: [1024]u8 = undefined;
                if (std.fmt.bufPrintZ(&title_buf, "wstudio GUI prototype - {s}", .{path})) |title| window.setTitle(title) else |_| {}
            } else |err| {
                std.debug.print("wstudio-gui: cannot load '{s}': {s}\n", .{ path, @errorName(err) });
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
    const snap = app.session.engine.uiSnapshot();
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = zgui.io.getDisplaySize()[0], .h = 64, .cond = .always });
    if (zgui.begin("Transport", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true } })) {
        if (zgui.button(if (snap.playing) "Stop" else "Play", .{ .w = 76, .h = 34 })) {
            _ = app.session.engine.send(if (snap.playing) .stop else .play);
        }
        zgui.sameLine(.{ .spacing = 18 });
        zgui.text("{d:0>3.0} BPM", .{app.session.project.tempo_bpm});
        zgui.sameLine(.{ .spacing = 28 });
        const beat = ws.types.framesToSeconds(snap.position_frames, app.session.project.sample_rate) * app.session.project.tempo_bpm / 60.0;
        zgui.text("{d:0>3.0}.{d:0>2.0}", .{ @floor(beat / 4.0) + 1.0, @mod(@as(u32, @intFromFloat(beat)), 4) + 1 });
        zgui.sameLine(.{ .spacing = 28 });
        zgui.textDisabled("PATTERN    4/4    48 kHz", .{});
    }
    zgui.end();
}

fn drawBrowser(app: *App) void {
    const layout = Layout.current();
    zgui.setNextWindowPos(.{ .x = 0, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = layout.browser_w, .h = layout.body_h, .cond = .always });
    if (zgui.begin("Browser", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        zgui.textDisabled("LIBRARY", .{});
        zgui.separator();
        const entries = [_]struct { label: [:0]const u8, view: App.View }{
            .{ .label = "Instruments", .view = .instrument_picker },
            .{ .label = "Samples", .view = .file_browser },
            .{ .label = "Drum Kits", .view = .drum_grid },
            .{ .label = "Presets", .view = .preset_picker },
            .{ .label = "Projects", .view = .file_browser },
        };
        for (entries) |entry| if (zgui.selectable(entry.label, .{})) {
            app.view = entry.view;
        };
        zgui.spacing();
        zgui.textDisabled("Prototype: browsing lands next", .{});
    }
    zgui.end();
}

fn drawTracks(app: *App) void {
    const layout = Layout.current();
    zgui.setNextWindowPos(.{ .x = layout.browser_w, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = layout.tracks_w, .h = layout.body_h, .cond = .always });
    if (zgui.begin("Tracks", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        for (app.session.project.tracks.items, 0..) |track, i| {
            var label_buf: [160]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{d:0>2}  {s}", .{ i + 1, track.name }) catch continue;
            if (zgui.selectable(label, .{ .selected = app.selected_track == i })) app.selected_track = i;
        }
        zgui.separator();
        if (zgui.button("+ Add track", .{ .w = -1 })) {
            const idx = app.session.project.tracks.items.len + 1;
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "track {d}", .{idx}) catch "track";
            _ = app.session.addTrack(name) catch {};
        }
    }
    zgui.end();
}

fn drawWorkspace(app: *App) void {
    const layout = Layout.current();
    zgui.setNextWindowPos(.{ .x = layout.browser_w + layout.tracks_w, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = layout.workspace_w, .h = layout.body_h, .cond = .always });
    if (zgui.begin("Workspace", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        drawViewNav(app);
        zgui.separator();
        switch (app.view) {
            .tracks => drawTrackOverview(app),
            .arrangement => drawArrangement(app),
            .piano_roll => drawPianoRoll(app),
            .drum_grid => drawDrumGrid(app),
            .slicer_grid => drawSlicerGrid(app),
            .synth => drawSynth(app),
            .sampler => drawSampler(app),
            .devices => drawDevices(app),
            .spectrum => drawSpectrum(app),
            .automation => drawAutomation(app),
            .instrument_picker => drawInstrumentPicker(app),
            .fx_picker => drawFxPicker(app),
            .preset_picker => drawPresetPicker(app),
            .file_browser => drawFileBrowser(app),
            .help => drawHelp(app),
        }
    }
    zgui.end();
}

fn drawViewNav(app: *App) void {
    const entries = [_]struct { label: [:0]const u8, view: App.View }{
        .{ .label = "Tracks", .view = .tracks },
        .{ .label = "Arrange", .view = .arrangement },
        .{ .label = "Piano", .view = .piano_roll },
        .{ .label = "Drums", .view = .drum_grid },
        .{ .label = "Slicer", .view = .slicer_grid },
        .{ .label = "Synth", .view = .synth },
        .{ .label = "Sampler", .view = .sampler },
        .{ .label = "FX", .view = .devices },
        .{ .label = "Scope", .view = .spectrum },
        .{ .label = "Auto", .view = .automation },
        .{ .label = "Pick", .view = .instrument_picker },
        .{ .label = "More", .view = .help },
    };
    for (entries, 0..) |entry, i| {
        if (i != 0) zgui.sameLine(.{});
        if (zgui.smallButton(entry.label)) app.view = entry.view;
    }
}

fn drawTrackOverview(app: *App) void {
    zgui.textDisabled("TRACKS", .{});
    for (app.session.project.tracks.items, 0..) |track, i| {
        zgui.pushIntId(@intCast(i));
        defer zgui.popId();
        var name_buf: [256]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{track.name}) catch "track";
        if (zgui.selectable(name, .{ .selected = app.selected_track == i })) app.selected_track = i;
        zgui.sameLine(.{ .offset_from_start_x = 230 });
        zgui.text("{d:.1} dB   pan {d:.2}{s}{s}", .{ track.gain_db, track.pan, if (track.muted) "   M" else "", if (track.soloed) "   S" else "" });
    }
}

fn drawArrangement(app: *App) void {
    zgui.textDisabled("ARRANGEMENT", .{});
    const track_count = app.session.project.tracks.items.len;
    const ticks_per_beat = ws.time_grid.ticks_per_beat;
    const beats_per_bar: u32 = app.session.project.beats_per_bar;
    const ticks_per_bar = ws.time_grid.barTicks(app.session.project.beats_per_bar);
    const content_ticks = app.session.arrangement.lengthTicks();
    const bar_count: u32 = @max(8, (content_ticks + ticks_per_bar - 1) / ticks_per_bar);
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
        const selected = ti == app.selected_track;
        draw.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ timeline_x, y + lane_h }, .col = color(if (selected) .{ 0.12, 0.17, 0.18, 1 } else .{ 0.075, 0.085, 0.095, 1 }) });
        draw.addRectFilled(.{ .pmin = .{ timeline_x, y }, .pmax = .{ origin[0] + canvas_w, y + lane_h }, .col = color(if (selected) .{ 0.075, 0.095, 0.10, 1 } else if (ti % 2 == 0) .{ 0.065, 0.075, 0.085, 1 } else .{ 0.055, 0.065, 0.075, 1 }) });
        draw.addText(.{ origin[0] + 10, y + 11 }, color(if (selected) .{ 0.75, 0.95, 0.88, 1 } else .{ 0.68, 0.70, 0.72, 1 }), "{d:0>2}  {s}", .{ ti + 1, app.session.project.tracks.items[ti].name });
        draw.addText(.{ origin[0] + 34, y + 32 }, color(.{ 0.36, 0.39, 0.42, 1 }), "{s}", .{@tagName(app.session.project.tracks.items[ti].kind)});
        draw.addLine(.{ .p1 = .{ origin[0], y + lane_h }, .p2 = .{ origin[0] + canvas_w, y + lane_h }, .col = color(.{ 0.13, 0.14, 0.16, 1 }), .thickness = 1 });
    }

    for (0..bar_count * beats_per_bar + 1) |beat_index| {
        const x = timeline_x + @as(f32, @floatFromInt(beat_index)) * beat_w;
        const on_bar = beat_index % beats_per_bar == 0;
        draw.addLine(.{ .p1 = .{ x, if (on_bar) origin[1] else origin[1] + ruler_h }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) .{ 0.29, 0.32, 0.35, 1 } else .{ 0.12, 0.135, 0.15, 1 }), .thickness = if (on_bar) 1.5 else 1 });
        if (on_bar and beat_index < bar_count * beats_per_bar) draw.addText(.{ x + 7, origin[1] + 7 }, color(.{ 0.64, 0.67, 0.70, 1 }), "{d}", .{beat_index / beats_per_bar + 1});
    }

    for (app.session.arrangement.lanes.items, 0..) |lane, ti| {
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

    const snap = app.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = @as(f64, @floatFromInt(snap.position_frames)) / 48000.0 * @as(f64, app.session.project.tempo_bpm) / 60.0;
        const x = timeline_x + @as(f32, @floatCast(play_beat)) * beat_w;
        if (x <= origin[0] + canvas_w) draw.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(.{ 1.0, 0.34, 0.28, 0.95 }), .thickness = 2 });
    }

    if (clicked and hovered and mouse[1] >= origin[1] + ruler_h) {
        const ti = @min(track_count - 1, @as(usize, @intFromFloat((mouse[1] - origin[1] - ruler_h) / lane_h)));
        app.selected_track = ti;
        app.arrangement_clip = null;
        if (mouse[0] >= timeline_x and ti < app.session.arrangement.lanes.items.len) {
            const tick: u32 = @intFromFloat((mouse[0] - timeline_x) / beat_w * @as(f32, @floatFromInt(ticks_per_beat)));
            for (app.session.arrangement.lanes.items[ti].clips.items, 0..) |clip, ci| {
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
    const rack = app.session.racks.items[app.selected_track];
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
    const top_pitch: u7 = 84;
    const bottom_pitch: u7 = 48;
    const row_count: usize = top_pitch - bottom_pitch + 1;
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

    const steps: usize = @intFromFloat(@ceil(beats * 4));
    for (0..steps + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * beat_w / 4;
        const on_beat = step % 4 == 0;
        const on_bar = step % 16 == 0;
        draw.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_bar) .{ 0.34, 0.37, 0.40, 1 } else if (on_beat) .{ 0.24, 0.26, 0.28, 1 } else .{ 0.13, 0.14, 0.15, 1 }), .thickness = if (on_bar) 2 else 1 });
        if (on_beat and step < steps) draw.addText(.{ x + 5, origin[1] + 4 }, color(.{ 0.62, 0.65, 0.68, 1 }), "{d}.{d}", .{ step / 16 + 1, step / 4 % 4 + 1 });
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

    const snap = app.session.engine.uiSnapshot();
    if (snap.playing) {
        const play_beat = @mod(@as(f64, @floatFromInt(snap.position_frames)) / 48000.0 * @as(f64, app.session.project.tempo_bpm) / 60.0, pp.length_beats);
        const x = grid_x + @as(f32, @floatCast(play_beat)) * beat_w;
        draw.addLine(.{ .p1 = .{ x, origin[1] }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(.{ 1.0, 0.34, 0.28, 0.95 }), .thickness = 2 });
    }

    if (hovered and mouse[0] >= grid_x and mouse[1] >= grid_y) {
        const step = @min(steps - 1, @as(usize, @intFromFloat((mouse[0] - grid_x) / (beat_w / 4))));
        const row = @min(row_count - 1, @as(usize, @intFromFloat((mouse[1] - grid_y) / row_h)));
        const x = grid_x + @as(f32, @floatFromInt(step)) * beat_w / 4;
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        draw.addRectFilled(.{ .pmin = .{ x + 1, y + 1 }, .pmax = .{ x + beat_w / 4 - 1, y + row_h - 1 }, .col = color(.{ 0.48, 0.91, 0.72, 0.18 }), .rounding = 2 });
        if (clicked) {
            const pitch: u7 = top_pitch - @as(u7, @intCast(row));
            const beat = @as(f64, @floatFromInt(step)) / 4.0;
            if (pp.noteAt(pitch, beat)) |_| pp.removeNote(pitch, beat) else pp.addNote(.{ .pitch = pitch, .start_beat = beat, .duration_beat = 0.25, .velocity = 0.85 });
        }
    }
}

fn color(rgba: [4]f32) u32 {
    return zgui.colorConvertFloat4ToU32(rgba);
}

fn isBlackKey(pitch: u7) bool {
    return switch (@mod(pitch, 12)) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

fn drawDrumGrid(app: *App) void {
    zgui.textDisabled("DRUM GRID", .{});
    const rack = app.session.racks.items[app.selected_track];
    const drum = switch (rack.instrument) {
        .drum_machine => |*d| d,
        else => {
            zgui.textDisabled("Select a Drum Machine track.", .{});
            return;
        },
    };
    zgui.text("Pattern {c}   {d} steps", .{ 'A' + drum.variant, drum.step_count });
    drawStepGridCanvas(.drum, drum, @min(@as(usize, 12), drum.pads.len), drum.step_count);
}

fn drawSlicerGrid(app: *App) void {
    zgui.textDisabled("SLICER GRID", .{});
    const rack = app.session.racks.items[app.selected_track];
    const slicer = switch (rack.instrument) {
        .slicer => |*s| s,
        else => {
            zgui.textDisabled("Select a Slicer track.", .{});
            return;
        },
    };
    zgui.text("{s}   {d} slices   {d} steps", .{ std.mem.trimEnd(u8, &slicer.name, " "), slicer.slice_count, slicer.step_count });
    if (slicer.sample_lock.tryLock()) {
        defer slicer.sample_lock.unlock();
        drawWaveform("##slicer-wave", slicer.samples);
    }
    drawStepGridCanvas(.slicer, slicer, @min(@as(usize, 12), slicer.slice_count), slicer.step_count);
}

const StepGridKind = enum { drum, slicer };

fn drawStepGridCanvas(comptime kind: StepGridKind, instrument: anytype, row_count: usize, step_count_raw: u8) void {
    const step_count: usize = @max(1, step_count_raw);
    const gutter_w: f32 = 132;
    const ruler_h: f32 = 27;
    const row_h: f32 = 32;
    const available = zgui.getContentRegionAvail();
    const canvas_w = @max(360, available[0]);
    const canvas_h = ruler_h + row_h * @as(f32, @floatFromInt(row_count));
    const origin = zgui.getCursorScreenPos();
    const id = if (kind == .drum) "drum-grid-canvas" else "slicer-grid-canvas";
    const clicked = zgui.invisibleButton(id, .{ .w = canvas_w, .h = canvas_h });
    const hovered = zgui.isItemHovered(.{});
    const mouse = zgui.getMousePos();
    const draw = zgui.getWindowDrawList();
    const grid_x = origin[0] + gutter_w;
    const grid_y = origin[1] + ruler_h;
    const grid_w = canvas_w - gutter_w;
    const cell_w = grid_w / @as(f32, @floatFromInt(step_count));
    const steps_per_beat: usize = if (kind == .drum) instrument.steps_per_beat else 4;

    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, origin[1] + canvas_h }, .col = color(umbra.bg0) });
    draw.addRectFilled(.{ .pmin = origin, .pmax = .{ origin[0] + canvas_w, grid_y }, .col = color(umbra.bg2) });
    for (0..row_count) |row| {
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        draw.addRectFilled(.{ .pmin = .{ origin[0], y }, .pmax = .{ grid_x, y + row_h }, .col = color(if (row % 2 == 0) umbra.bg2 else umbra.bg1) });
        draw.addRectFilled(.{ .pmin = .{ grid_x, y }, .pmax = .{ origin[0] + canvas_w, y + row_h }, .col = color(if (row % 2 == 0) umbra.bg1 else umbra.bg0) });
        if (kind == .drum) {
            if (instrument.pads[row]) |*sample|
                draw.addText(.{ origin[0] + 9, y + 8 }, color(umbra.fg1), "{d:0>2}  {s}", .{ row + 1, sample.clipName() })
            else
                draw.addText(.{ origin[0] + 9, y + 8 }, color(umbra.fg2), "{d:0>2}  Pad", .{row + 1});
        } else {
            draw.addText(.{ origin[0] + 9, y + 8 }, color(umbra.fg1), "{d:0>2}  Slice {d}", .{ row + 1, row + 1 });
        }
        draw.addLine(.{ .p1 = .{ origin[0], y + row_h }, .p2 = .{ origin[0] + canvas_w, y + row_h }, .col = color(umbra.line), .thickness = 1 });
    }

    for (0..step_count + 1) |step| {
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        const on_beat = step % steps_per_beat == 0;
        draw.addLine(.{ .p1 = .{ x, if (on_beat) origin[1] else grid_y }, .p2 = .{ x, origin[1] + canvas_h }, .col = color(if (on_beat) umbra.bg5 else umbra.line_soft), .thickness = if (on_beat) 1.5 else 1 });
        if (on_beat and step < step_count) draw.addText(.{ x + 5, origin[1] + 5 }, color(umbra.fg2), "{d}", .{step / steps_per_beat + 1});
    }

    for (0..row_count) |row| {
        for (0..step_count) |step| {
            if (!instrument.stepActive(@intCast(row), @intCast(step))) continue;
            const velocity = @as(f32, @floatFromInt(instrument.stepVel(@intCast(row), @intCast(step)))) / 127.0;
            const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
            const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
            const inset = @min(3, cell_w * 0.15);
            const height = 8 + velocity * (row_h - 13);
            const hit_color = if (kind == .drum) umbra.iris else umbra.cyan;
            draw.addRectFilled(.{ .pmin = .{ x + inset, y + row_h - height - 3 }, .pmax = .{ x + cell_w - inset, y + row_h - 3 }, .col = color(.{ hit_color[0], hit_color[1], hit_color[2], 0.62 + velocity * 0.38 }) });
        }
    }

    if (hovered and mouse[0] >= grid_x and mouse[1] >= grid_y and row_count > 0) {
        const step = @min(step_count - 1, @as(usize, @intFromFloat((mouse[0] - grid_x) / cell_w)));
        const row = @min(row_count - 1, @as(usize, @intFromFloat((mouse[1] - grid_y) / row_h)));
        const x = grid_x + @as(f32, @floatFromInt(step)) * cell_w;
        const y = grid_y + @as(f32, @floatFromInt(row)) * row_h;
        draw.addRectFilled(.{ .pmin = .{ x + 1, y + 1 }, .pmax = .{ x + cell_w - 1, y + row_h - 1 }, .col = color(.{ umbra.mauve[0], umbra.mauve[1], umbra.mauve[2], 0.22 }) });
        if (clicked) instrument.toggleStep(@intCast(row), @intCast(step));
    }
}

fn drawDevices(app: *App) void {
    const rack = app.session.racks.items[app.selected_track];
    zgui.textDisabled("DEVICE CHAIN", .{});
    zgui.separatorText("Instrument");
    zgui.text("{s}", .{rack.label});
    zgui.separatorText("Effects");
    if (rack.fx.units.items.len == 0) zgui.textDisabled("No effects. Open FX Picker to insert one.", .{});
    for (rack.fx.units.items, 0..) |unit, i| {
        zgui.pushIntId(@intCast(i));
        defer zgui.popId();
        zgui.text("{d}. {s}", .{ i + 1, @tagName(unit.kind()) });
        zgui.sameLine(.{ .offset_from_start_x = 220 });
        if (zgui.checkbox("Bypass", .{ .v = &unit.bypassed })) app.session.syncTrackChain(@intCast(app.selected_track), rack);
        zgui.sameLine(.{});
        if (zgui.smallButton("Remove")) {
            rack.fx.remove(app.session.allocator, i);
            app.session.syncTrackChain(@intCast(app.selected_track), rack);
            break;
        }
    }
    if (zgui.button("Add effect", .{})) app.view = .fx_picker;
}

fn drawSynth(app: *App) void {
    zgui.textDisabled("SYNTH EDITOR", .{});
    const synth = switch (app.session.racks.items[app.selected_track].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a Synth track.", .{});
            return;
        },
    };
    zgui.text("Wave {s}   Filter {s}", .{ @tagName(synth.waveform), @tagName(synth.filter_type) });
    for (ws.dsp.PolySynth.automatable_params[0..@min(18, ws.dsp.PolySynth.automatable_params.len)]) |param| {
        var value = synth.paramValue(param.id) orelse continue;
        var label: [64]u8 = undefined;
        const zlabel = std.fmt.bufPrintZ(&label, "{s}##synth-{d}", .{ param.label, param.id }) catch continue;
        if (zgui.sliderFloat(zlabel, .{ .v = &value, .min = param.range[0], .max = param.range[1] })) {
            _ = app.session.engine.send(.{ .set_track_param_abs = .{ .track = @intCast(app.selected_track), .id = param.id, .value = value } });
        }
    }
}

fn drawSampler(app: *App) void {
    zgui.textDisabled("SAMPLER EDITOR", .{});
    const sampler = switch (app.session.racks.items[app.selected_track].instrument) {
        .sampler => |*s| s,
        else => {
            zgui.textDisabled("Select a Sampler track.", .{});
            return;
        },
    };
    zgui.text("{s}   {d} samples   root {d}", .{ sampler.clipName(), sampler.pad.samples.len, sampler.root_note });
    if (sampler.pad_lock.tryLock()) {
        defer sampler.pad_lock.unlock();
        drawWaveform("##sampler-wave", sampler.pad.samples);
    }
    const names = [_][:0]const u8{ "Start", "End", "Pitch", "Attack", "Decay", "Sustain", "Release", "Gain", "Pan", "Reverse", "Root", "Mono" };
    for (names, 0..) |name, id| {
        var value = sampler.paramValue(@intCast(id)) orelse continue;
        const range: [2]f32 = switch (id) {
            0, 1, 5, 8, 9, 11 => .{ 0, 1 },
            2 => .{ -48, 48 },
            3, 4 => .{ 0, 5 },
            6 => .{ 0, 10 },
            7 => .{ -60, 12 },
            10 => .{ 0, 127 },
            else => .{ 0, 1 },
        };
        var label: [48]u8 = undefined;
        const zlabel = std.fmt.bufPrintZ(&label, "{s}##sampler-{d}", .{ name, id }) catch continue;
        if (zgui.sliderFloat(zlabel, .{ .v = &value, .min = range[0], .max = range[1] })) {
            _ = app.session.engine.send(.{ .set_track_param_abs = .{ .track = @intCast(app.selected_track), .id = @intCast(id), .value = value } });
        }
    }
}

fn drawWaveform(label: [:0]const u8, samples: []const f32) void {
    if (samples.len == 0) {
        zgui.textDisabled("No sample loaded.", .{});
        return;
    }
    var overview: [1024]f32 = undefined;
    const count = @min(samples.len, overview.len);
    for (overview[0..count], 0..) |*out, i| {
        const start = i * samples.len / count;
        const end = @max(start + 1, (i + 1) * samples.len / count);
        var peak: f32 = 0;
        for (samples[start..@min(end, samples.len)]) |sample| if (@abs(sample) > @abs(peak)) {
            peak = sample;
        };
        out.* = peak;
    }
    if (zgui.plot.beginPlot(label, .{ .h = 150, .flags = .canvas_only })) {
        zgui.plot.setupAxis(.x1, .{ .flags = .no_decorations });
        zgui.plot.setupAxis(.y1, .{ .flags = .no_decorations });
        zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = @floatFromInt(count), .cond = .always });
        zgui.plot.setupAxisLimits(.y1, .{ .min = -1, .max = 1, .cond = .always });
        zgui.plot.plotLineValues("wave", f32, .{ .v = overview[0..count] });
        zgui.plot.endPlot();
    }
}

fn drawSpectrum(app: *App) void {
    zgui.textDisabled("SPECTRUM / MIXER", .{});
    const snap = app.session.engine.uiSnapshot();
    zgui.text("Master L", .{});
    zgui.progressBar(.{ .fraction = std.math.clamp(snap.peak[0], 0, 1), .w = -1, .h = 22 });
    zgui.text("Master R", .{});
    zgui.progressBar(.{ .fraction = std.math.clamp(snap.peak[1], 0, 1), .w = -1, .h = 22 });
    zgui.spacing();
    drawDevices(app);
}

fn drawAutomation(app: *App) void {
    zgui.textDisabled("AUTOMATION", .{});
    const lane = if (app.selected_track < app.session.arrangement.lanes.items.len) &app.session.arrangement.lanes.items[app.selected_track] else null;
    if (lane == null or lane.?.clips.items.len == 0) {
        zgui.textDisabled("Place a clip in the arrangement to edit its automation.", .{});
        return;
    }
    app.automation_clip = @min(app.automation_clip, lane.?.clips.items.len - 1);
    for (lane.?.clips.items, 0..) |clip, i| {
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "Clip {d}##auto-clip-{d}", .{ i + 1, i }) catch continue;
        if (zgui.selectable(label, .{ .selected = app.automation_clip == i, .w = 100 })) app.automation_clip = i;
        zgui.sameLine(.{});
        zgui.textDisabled("tick {d}, length {d}", .{ clip.start_tick, clip.length_ticks });
    }
    const clip = &lane.?.clips.items[app.automation_clip];
    zgui.separator();
    if (zgui.button("Gain", .{})) app.automation_target = .gain;
    zgui.sameLine(.{});
    if (zgui.button("Pan", .{})) app.automation_target = .pan;
    zgui.sameLine(.{});
    zgui.text("Editing {s}", .{@tagName(app.automation_target)});

    const length_beats: f32 = @floatCast(ws.time_grid.tickToBeat(clip.length_ticks));
    _ = zgui.sliderFloat("Beat", .{ .v = &app.automation_beat, .min = 0, .max = @max(0.25, length_beats), .cfmt = "%.2f" });
    const value_range: [2]f32 = if (app.automation_target == .gain) .{ -60, 12 } else .{ -1, 1 };
    app.automation_value = std.math.clamp(app.automation_value, value_range[0], value_range[1]);
    _ = zgui.sliderFloat("Value", .{ .v = &app.automation_value, .min = value_range[0], .max = value_range[1] });
    const points: *[]ws.dsp.automation.AutomationPoint = switch (app.automation_target) {
        .gain => &clip.automation.gain,
        .pan => &clip.automation.pan,
    };
    if (zgui.button("Add / update point", .{})) {
        ws.dsp.automation.setPoint(app.allocator, points, app.automation_beat, app.automation_value) catch {};
        app.session.rebuildSongData();
    }
    zgui.sameLine(.{});
    if (zgui.button("Delete point", .{})) {
        if (ws.dsp.automation.removePoint(app.allocator, points, app.automation_beat)) app.session.rebuildSongData();
    }
    zgui.separatorText("Points");
    for (points.*, 0..) |point, i| {
        zgui.text("{d: >2}. beat {d:.2}   value {d:.3}", .{ i + 1, point.beat, point.value });
    }
}

fn drawInstrumentPicker(app: *App) void {
    zgui.textDisabled("INSTRUMENT PICKER", .{});
    const entries = [_]struct { label: [:0]const u8, kind: ws.InstrumentKind }{
        .{ .label = "Synth", .kind = .poly_synth },
        .{ .label = "Sampler", .kind = .sampler },
        .{ .label = "Drum Machine", .kind = .drum_machine },
        .{ .label = "Slicer", .kind = .slicer },
    };
    for (entries) |entry| {
        if (zgui.button(entry.label, .{ .w = 240, .h = 42 })) {
            app.session.setInstrument(app.selected_track, entry.kind) catch return;
            app.view = switch (entry.kind) {
                .poly_synth => .synth,
                .sampler => .sampler,
                .drum_machine => .drum_grid,
                .slicer => .slicer_grid,
                .empty => .tracks,
            };
        }
    }
}

fn drawFxPicker(app: *App) void {
    zgui.textDisabled("FX PICKER", .{});
    const rack = app.session.racks.items[app.selected_track];
    const kinds = std.meta.tags(ws.FxKind);
    for (kinds, 0..) |kind, i| {
        var label_buf: [48]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{s}##fx-{d}", .{ @tagName(kind), i }) catch continue;
        if (zgui.button(label, .{ .w = 180 })) {
            _ = rack.fx.insert(app.session.allocator, rack.fx.units.items.len, kind, app.session.project.sample_rate) catch continue;
            app.session.syncTrackChain(@intCast(app.selected_track), rack);
            app.view = .devices;
        }
        zgui.sameLine(.{});
    }
    zgui.newLine();
}

fn drawPresetPicker(app: *App) void {
    zgui.textDisabled("SYNTH PRESET PICKER", .{});
    const synth = switch (app.session.racks.items[app.selected_track].instrument) {
        .poly_synth => |*s| s,
        else => {
            zgui.textDisabled("Select a Synth track to use presets.", .{});
            return;
        },
    };
    if (zgui.beginChild("presets", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        for (ws.dsp.synth_presets.presets) |preset| {
            var label_buf: [128]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s}  [{s}]", .{ preset.name, preset.category }) catch continue;
            if (zgui.selectable(label, .{})) {
                _ = app.session.engine.send(.stop);
                synth.applyPatch(preset.patch);
                app.view = .synth;
            }
        }
    }
    zgui.endChild();
}

fn drawFileBrowser(app: *App) void {
    zgui.textDisabled("FILE BROWSER", .{});
    if (app.browser_dir.len == 0) app.setBrowserDir(".") catch {
        zgui.textDisabled("Cannot read the current directory.", .{});
        return;
    };
    zgui.text("{s}", .{app.browser_dir});
    if (zgui.button("Up", .{})) {
        if (std.fs.path.dirname(app.browser_dir)) |parent| app.setBrowserDir(parent) catch {};
    }
    zgui.sameLine(.{});
    if (zgui.button("Refresh", .{})) app.setBrowserDir(app.browser_dir) catch {};
    zgui.separator();
    if (zgui.beginChild("files", .{ .w = 0, .h = -1, .child_flags = .{ .border = true } })) {
        var i: usize = 0;
        while (i < app.browser_entries.items.len) : (i += 1) {
            const entry = app.browser_entries.items[i];
            var label_buf: [512]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s} {s}", .{ if (entry.is_dir) "[DIR]" else "     ", entry.name }) catch continue;
            if (zgui.selectable(label, .{ .flags = .{ .allow_double_click = true } }) and zgui.isMouseDoubleClicked(.left)) {
                app.activateBrowserEntry(entry);
                break;
            }
        }
    }
    zgui.endChild();
}

fn drawHelp(app: *App) void {
    zgui.textDisabled("HELP / VIEW INDEX", .{});
    const rows = [_]struct { key: []const u8, text: []const u8 }{
        .{ .key = "Space", .text = "Play or stop" },
        .{ .key = "Tracks", .text = "Track list and mixer state" },
        .{ .key = "Arrange", .text = "Song clips by bar" },
        .{ .key = "Piano", .text = "Melodic step editing" },
        .{ .key = "Drums / Slicer", .text = "Step toggles" },
        .{ .key = "Synth / Sampler", .text = "Instrument parameters" },
        .{ .key = "FX", .text = "Chain, bypass, insert, and remove" },
        .{ .key = "Scope", .text = "Master meters and chain" },
        .{ .key = "Auto", .text = "Clip automation summary" },
    };
    for (rows) |row| {
        zgui.textColored(umbra.mauve, "{s}", .{row.key});
        zgui.sameLine(.{ .offset_from_start_x = 150 });
        zgui.text("{s}", .{row.text});
    }
    zgui.separator();
    if (zgui.button("Instrument picker", .{})) app.view = .instrument_picker;
    zgui.sameLine(.{});
    if (zgui.button("Preset picker", .{})) app.view = .preset_picker;
    zgui.sameLine(.{});
    if (zgui.button("File browser", .{})) app.view = .file_browser;
}

fn drawInspector(app: *App) void {
    const layout = Layout.current();
    zgui.setNextWindowPos(.{ .x = layout.browser_w + layout.tracks_w + layout.workspace_w, .y = 64, .cond = .always });
    zgui.setNextWindowSize(.{ .w = layout.inspector_w, .h = layout.body_h, .cond = .always });
    if (zgui.begin("Inspector", .{ .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true, .no_docking = true } })) {
        const track = &app.session.project.tracks.items[app.selected_track];
        zgui.text("{s}", .{track.name});
        zgui.separator();
        zgui.textDisabled("Gain", .{});
        if (zgui.sliderFloat("##gain", .{ .v = &track.gain_db, .min = -60, .max = 12, .cfmt = "%.1f dB" })) {
            _ = app.session.engine.send(.{ .set_track_gain = .{
                .track = @intCast(app.selected_track),
                .gain = ws.types.dbToGain(track.gain_db),
            } });
        }
        zgui.textDisabled("Pan", .{});
        if (zgui.sliderFloat("##pan", .{ .v = &track.pan, .min = -1, .max = 1, .cfmt = "%.2f" })) {
            _ = app.session.engine.send(.{ .set_track_pan = .{ .track = @intCast(app.selected_track), .pan = track.pan } });
        }
        if (zgui.checkbox("Mute", .{ .v = &track.muted })) {
            _ = app.session.engine.send(.{ .set_track_mute = .{ .track = @intCast(app.selected_track), .muted = track.muted } });
        }
        zgui.sameLine(.{});
        if (zgui.checkbox("Solo", .{ .v = &track.soloed })) {
            _ = app.session.engine.send(.{ .set_track_solo = .{ .track = @intCast(app.selected_track), .soloed = track.soloed } });
        }
    }
    zgui.end();
}

fn drawStatus(app: *App, audio_label: []const u8) void {
    _ = app;
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = display[1] - 34, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = 34, .cond = .always });
    if (zgui.begin("Status", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true } })) {
        zgui.textColored(umbra.mauve, "NORMAL", .{});
        zgui.sameLine(.{ .spacing = 18 });
        zgui.textDisabled("Space play/stop    H/L view    J/K track    F1 help    audio: {s}", .{audio_label});
    }
    zgui.end();
}

fn rgb(comptime value: u24) [4]f32 {
    return .{
        @as(f32, @floatFromInt(value >> 16)) / 255.0,
        @as(f32, @floatFromInt(value >> 8 & 0xff)) / 255.0,
        @as(f32, @floatFromInt(value & 0xff)) / 255.0,
        1.0,
    };
}

const umbra = struct {
    const bg0 = rgb(0x0c040f);
    const bg1 = rgb(0x160a19);
    const bg2 = rgb(0x231426);
    const bg3 = rgb(0x301f34);
    const bg4 = rgb(0x412d45);
    const bg5 = rgb(0x553e5a);
    const fg0 = rgb(0xd9d1da);
    const fg1 = rgb(0xb1a7b3);
    const fg2 = rgb(0x887b8c);
    const fg3 = rgb(0x645567);
    const line = rgb(0x1d1120);
    const line_soft = rgb(0x130915);
    const iris = rgb(0xb07bbc);
    const iris_soft = rgb(0x886498);
    const mauve = rgb(0xc68fc1);
    const red = rgb(0xb97873);
    const yellow = rgb(0xc1a77b);
    const cyan = rgb(0x7cb0af);
};

fn setTheme() void {
    const style = zgui.getStyle();
    zgui.styleColorsDark(style);
    style.setColor(.text, umbra.fg0);
    style.setColor(.text_disabled, umbra.fg3);
    style.setColor(.window_bg, umbra.bg1);
    style.setColor(.child_bg, umbra.bg1);
    style.setColor(.popup_bg, umbra.bg2);
    style.setColor(.border, umbra.line);
    style.setColor(.border_shadow, .{ 0, 0, 0, 0 });
    style.setColor(.frame_bg, umbra.bg2);
    style.setColor(.frame_bg_hovered, umbra.bg3);
    style.setColor(.frame_bg_active, umbra.bg4);
    style.setColor(.title_bg, umbra.bg0);
    style.setColor(.title_bg_active, umbra.bg2);
    style.setColor(.title_bg_collapsed, umbra.bg0);
    style.setColor(.menu_bar_bg, umbra.bg2);
    style.setColor(.scrollbar_bg, umbra.bg0);
    style.setColor(.scrollbar_grab, umbra.bg4);
    style.setColor(.scrollbar_grab_hovered, umbra.bg5);
    style.setColor(.scrollbar_grab_active, umbra.iris_soft);
    style.setColor(.check_mark, umbra.mauve);
    style.setColor(.slider_grab, umbra.iris_soft);
    style.setColor(.slider_grab_active, umbra.iris);
    style.setColor(.button, umbra.bg3);
    style.setColor(.button_hovered, umbra.bg4);
    style.setColor(.button_active, umbra.iris_soft);
    style.setColor(.header, umbra.bg3);
    style.setColor(.header_hovered, umbra.bg4);
    style.setColor(.header_active, umbra.iris_soft);
    style.setColor(.separator, umbra.line);
    style.setColor(.separator_hovered, umbra.iris_soft);
    style.setColor(.separator_active, umbra.iris);
    style.setColor(.plot_lines, umbra.cyan);
    style.setColor(.plot_lines_hovered, umbra.mauve);
    style.setColor(.plot_histogram, umbra.iris);
    style.setColor(.plot_histogram_hovered, umbra.mauve);
    style.setColor(.table_header_bg, umbra.bg2);
    style.setColor(.table_border_strong, umbra.bg5);
    style.setColor(.table_border_light, umbra.line);
    style.setColor(.table_row_bg_alt, .{ umbra.bg2[0], umbra.bg2[1], umbra.bg2[2], 0.45 });
    style.setColor(.text_selected_bg, .{ umbra.iris[0], umbra.iris[1], umbra.iris[2], 0.35 });
    style.setColor(.nav_cursor, umbra.iris);
    style.setColor(.modal_window_dim_bg, .{ umbra.bg0[0], umbra.bg0[1], umbra.bg0[2], 0.78 });
    style.window_rounding = 0;
    style.child_rounding = 0;
    style.popup_rounding = 0;
    style.tab_rounding = 0;
    style.frame_rounding = 2;
    style.grab_rounding = 2;
    style.scrollbar_rounding = 0;
    style.window_padding = .{ 12, 12 };
    style.frame_padding = .{ 8, 6 };
    style.item_spacing = .{ 8, 8 };
}
