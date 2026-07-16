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
        gl.clearColor(0.035, 0.039, 0.047, 1.0);
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
    zgui.spacing();
    if (zgui.beginTable("arrangement", .{ .column = 9, .flags = .{ .borders = .inner, .row_bg = true }, .outer_size = .{ 0, -1 } })) {
        defer zgui.endTable();
        zgui.tableSetupColumn("Track", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 150 });
        for (1..9) |bar| {
            var buf: [8]u8 = undefined;
            zgui.tableSetupColumn(std.fmt.bufPrintZ(&buf, "{d}", .{bar}) catch "?", .{});
        }
        zgui.tableHeadersRow();
        const ticks_per_bar = ws.time_grid.barTicks(app.session.project.beats_per_bar);
        for (app.session.project.tracks.items, 0..) |track, ti| {
            zgui.tableNextRow(.{});
            _ = zgui.tableSetColumnIndex(0);
            zgui.text("{s}", .{track.name});
            for (1..9) |col| {
                _ = zgui.tableSetColumnIndex(@intCast(col));
                const tick: u32 = @intCast((col - 1) * ticks_per_bar);
                const clip = if (ti < app.session.arrangement.lanes.items.len)
                    app.session.arrangement.lanes.items[ti].clipAt(tick)
                else
                    null;
                if (clip) |c| {
                    var label_buf: [32]u8 = undefined;
                    const at_start = c.start_tick / ticks_per_bar == col - 1;
                    const label = if (at_start)
                        std.fmt.bufPrintZ(&label_buf, "{s}##{d}-{d}", .{ switch (c.content) {
                            .melodic => "MIDI",
                            .drum => |d| @as([]const u8, &[_]u8{'A' + d.variant}),
                        }, ti, col }) catch "clip"
                    else
                        std.fmt.bufPrintZ(&label_buf, "...##{d}-{d}", .{ ti, col }) catch "...";
                    _ = zgui.selectable(label, .{ .w = 54, .h = 46 });
                } else {
                    zgui.dummy(.{ .w = 54, .h = 46 });
                }
            }
        }
    }
}

fn drawPianoRoll(app: *App) void {
    zgui.textDisabled("PIANO ROLL", .{});
    zgui.spacing();
    const rack = app.session.racks.items[app.selected_track];
    const pp = if (rack.pattern_player) |*p| p else {
        zgui.textDisabled("This instrument has no melodic pattern. Choose Synth or Sampler.", .{});
        return;
    };
    zgui.text("{d} notes   {d:.1} beats", .{ pp.note_count, pp.length_beats });
    if (zgui.beginTable("piano-grid", .{ .column = 17, .flags = .{ .borders = .inner, .sizing = .fixed_same }, .outer_size = .{ 0, -1 } })) {
        defer zgui.endTable();
        zgui.tableSetupColumn("Note", .{ .init_width_or_height = 54 });
        for (0..16) |step| {
            var header: [8]u8 = undefined;
            zgui.tableSetupColumn(std.fmt.bufPrintZ(&header, "{d}", .{step + 1}) catch "?", .{});
        }
        zgui.tableHeadersRow();
        for (0..12) |row| {
            const pitch: u7 = @intCast(71 - row);
            zgui.tableNextRow(.{});
            _ = zgui.tableSetColumnIndex(0);
            zgui.text("{d}", .{pitch});
            for (0..16) |step| {
                _ = zgui.tableSetColumnIndex(@intCast(step + 1));
                const beat = @as(f64, @floatFromInt(step)) / 4.0;
                var active = false;
                for (pp.notes[0..pp.note_count]) |note| {
                    if (note.pitch == pitch and @abs(note.start_beat - beat) < 0.001) active = true;
                }
                var label: [24]u8 = undefined;
                const text = std.fmt.bufPrintZ(&label, "{s}##n{d}-{d}", .{ if (active) "x" else " ", pitch, step }) catch "?";
                if (zgui.smallButton(text)) {
                    if (active) pp.removeNote(pitch, beat) else pp.addNote(.{ .pitch = pitch, .start_beat = beat, .duration_beat = 0.25, .velocity = 0.8 });
                }
            }
        }
    }
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
    if (zgui.beginTable("drum-grid", .{ .column = 17, .flags = .{ .borders = .inner, .sizing = .fixed_same }, .outer_size = .{ 0, -1 } })) {
        defer zgui.endTable();
        zgui.tableSetupColumn("Pad", .{ .init_width_or_height = 64 });
        for (0..16) |step| {
            var header: [8]u8 = undefined;
            zgui.tableSetupColumn(std.fmt.bufPrintZ(&header, "{d}", .{step + 1}) catch "?", .{});
        }
        zgui.tableHeadersRow();
        for (0..@min(@as(usize, 12), drum.pads.len)) |pad| {
            zgui.tableNextRow(.{});
            _ = zgui.tableSetColumnIndex(0);
            if (drum.pads[pad]) |*sample| zgui.text("{s}", .{sample.clipName()}) else zgui.text("Pad {d}", .{pad + 1});
            for (0..@min(@as(usize, 16), drum.step_count)) |step| {
                _ = zgui.tableSetColumnIndex(@intCast(step + 1));
                const active = (drum.pattern[pad].load(.acquire) >> @intCast(step)) & 1 != 0;
                var label: [24]u8 = undefined;
                const text = std.fmt.bufPrintZ(&label, "{s}##d{d}-{d}", .{ if (active) "x" else " ", pad, step }) catch "?";
                if (zgui.smallButton(text)) drum.toggleStep(@intCast(pad), @intCast(step));
            }
        }
    }
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
    if (zgui.beginTable("slicer-grid", .{ .column = 17, .flags = .{ .borders = .inner, .sizing = .fixed_same }, .outer_size = .{ 0, -1 } })) {
        defer zgui.endTable();
        zgui.tableSetupColumn("Slice", .{ .init_width_or_height = 64 });
        for (0..16) |step| {
            var header: [8]u8 = undefined;
            zgui.tableSetupColumn(std.fmt.bufPrintZ(&header, "{d}", .{step + 1}) catch "?", .{});
        }
        zgui.tableHeadersRow();
        for (0..@min(@as(usize, 12), slicer.slice_count)) |slice| {
            zgui.tableNextRow(.{});
            _ = zgui.tableSetColumnIndex(0);
            zgui.text("Slice {d}", .{slice + 1});
            for (0..@min(@as(usize, 16), slicer.step_count)) |step| {
                _ = zgui.tableSetColumnIndex(@intCast(step + 1));
                const active = slicer.stepActive(@intCast(slice), @intCast(step));
                var label: [24]u8 = undefined;
                const text = std.fmt.bufPrintZ(&label, "{s}##s{d}-{d}", .{ if (active) "x" else " ", slice, step }) catch "?";
                if (zgui.smallButton(text)) slicer.toggleStep(@intCast(slice), @intCast(step));
            }
        }
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
        zgui.textColored(.{ 0.47, 0.82, 0.69, 1 }, "{s}", .{row.key});
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
        zgui.textColored(.{ 0.47, 0.82, 0.69, 1 }, "NORMAL", .{});
        zgui.sameLine(.{ .spacing = 18 });
        zgui.textDisabled("Space play/stop    H/L view    J/K track    F1 help    audio: {s}", .{audio_label});
    }
    zgui.end();
}

fn setTheme() void {
    const style = zgui.getStyle();
    zgui.styleColorsDark(style);
    style.window_rounding = 3;
    style.frame_rounding = 3;
    style.grab_rounding = 3;
    style.window_padding = .{ 12, 12 };
    style.frame_padding = .{ 8, 6 };
    style.item_spacing = .{ 8, 8 };
}
