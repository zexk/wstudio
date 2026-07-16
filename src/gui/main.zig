//! Experimental desktop frontend. The engine remains frontend-neutral; this
//! file owns only GLFW/ImGui lifecycle and GUI-specific presentation state.

const std = @import("std");
const ws = @import("wstudio");
const glfw = @import("zglfw");
const zgui = @import("zgui");
const zopengl = @import("zopengl");

const gl = zopengl.bindings;

const App = struct {
    session: ws.Session,
    selected_track: usize = 0,
    view: View = .arrangement,
    space_down: bool = false,

    const View = enum { arrangement, piano_roll, devices };

    fn init(allocator: std.mem.Allocator, io: std.Io, init_path: ?[]const u8) !App {
        const session = if (init_path) |path|
            try ws.persist.load(allocator, io, path)
        else
            try ws.Session.initDefault(allocator);
        return .{ .session = session };
    }

    fn deinit(self: *App) void {
        self.session.deinit();
    }

    fn draw(self: *App) void {
        drawTransport(self);
        drawBrowser();
        drawTracks(self);
        drawWorkspace(self);
        drawInspector(self);
        drawStatus(self);
    }

    fn handleShortcuts(self: *App, window: *glfw.Window) void {
        const down = window.getKey(.space) == .press;
        if (down and !self.space_down and !zgui.io.getWantCaptureKeyboard()) {
            const playing = self.session.engine.uiSnapshot().playing;
            _ = self.session.engine.send(if (playing) .stop else .play);
        }
        self.space_down = down;
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
    zgui.io.setConfigFlags(.{ .nav_enable_keyboard = true, .dock_enable = true });
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
    var audio = ws.backend.NullBackend{
        .config = .{ .sample_rate = app.session.project.sample_rate },
        .render = renderAudio,
        .ctx = app.session.engine,
    };
    try audio.start(init.io);
    defer audio.stop();

    while (!window.shouldClose()) {
        glfw.pollEvents();
        const fb = window.getFramebufferSize();
        if (fb[0] <= 0 or fb[1] <= 0) continue;
        gl.viewport(0, 0, fb[0], fb[1]);
        gl.clearColor(0.035, 0.039, 0.047, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        zgui.backend.newFrame(@intCast(fb[0]), @intCast(fb[1]));
        _ = zgui.dockSpaceOverViewport(0, zgui.getMainViewport(), .{});
        app.handleShortcuts(window);
        app.draw();
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

fn drawBrowser() void {
    zgui.setNextWindowPos(.{ .x = 0, .y = 64, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 220, .h = 760, .cond = .first_use_ever });
    if (zgui.begin("Browser", .{})) {
        zgui.textDisabled("LIBRARY", .{});
        zgui.separator();
        const entries = [_][:0]const u8{ "Instruments", "Samples", "Drum Kits", "Presets", "Projects" };
        for (entries) |entry| _ = zgui.selectable(entry, .{});
        zgui.spacing();
        zgui.textDisabled("Prototype: browsing lands next", .{});
    }
    zgui.end();
}

fn drawTracks(app: *App) void {
    zgui.setNextWindowPos(.{ .x = 220, .y = 64, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 280, .h = 420, .cond = .first_use_ever });
    if (zgui.begin("Tracks", .{})) {
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
    zgui.setNextWindowPos(.{ .x = 500, .y = 64, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 700, .h = 620, .cond = .first_use_ever });
    if (zgui.begin("Workspace", .{})) {
        if (zgui.button("Arrangement", .{})) app.view = .arrangement;
        zgui.sameLine(.{});
        if (zgui.button("Piano roll", .{})) app.view = .piano_roll;
        zgui.sameLine(.{});
        if (zgui.button("Devices", .{})) app.view = .devices;
        zgui.separator();
        switch (app.view) {
            .arrangement => drawArrangement(app),
            .piano_roll => drawPianoRoll(),
            .devices => drawDevices(app),
        }
    }
    zgui.end();
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

fn drawPianoRoll() void {
    zgui.textDisabled("PIANO ROLL", .{});
    zgui.spacing();
    for (0..12) |row| {
        zgui.text("{s}{d}", .{ if (row % 2 == 0) "C" else " ", 5 -| row / 2 });
        zgui.sameLine(.{ .offset_from_start_x = 54 });
        zgui.progressBar(.{ .fraction = if (row == 4) 0.62 else 0.0, .w = -1, .h = 20, .overlay = "" });
    }
}

fn drawDevices(app: *App) void {
    const rack = app.session.racks.items[app.selected_track];
    zgui.textDisabled("DEVICE CHAIN", .{});
    zgui.separatorText("Instrument");
    zgui.text("{s}", .{rack.label});
    zgui.separatorText("Effects");
    zgui.textDisabled("Drop an effect here", .{});
}

fn drawInspector(app: *App) void {
    zgui.setNextWindowPos(.{ .x = 1200, .y = 64, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 240, .h = 620, .cond = .first_use_ever });
    if (zgui.begin("Inspector", .{})) {
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

fn drawStatus(app: *App) void {
    _ = app;
    const display = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{ .x = 0, .y = display[1] - 34, .cond = .always });
    zgui.setNextWindowSize(.{ .w = display[0], .h = 34, .cond = .always });
    if (zgui.begin("Status", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_docking = true } })) {
        zgui.textColored(.{ 0.47, 0.82, 0.69, 1 }, "NORMAL", .{});
        zgui.sameLine(.{ .spacing = 18 });
        zgui.textDisabled("Space play/stop    prototype/gui    engine online", .{});
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
