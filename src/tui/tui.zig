//! TUI frontend entry point: terminal lifecycle, the input/render main
//! loop, and the per-frame draw pipeline (header, view body, transport,
//! prompt, status). The frontend-agnostic application core lives in
//! ui/app.zig; per-view renderers in views/<name>.zig, reached through the
//! render.zig facade. Named to match gui/gui.zig: `main` belongs to the
//! program entry point in src/main.zig, not to a frontend.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wstudio");
const types = ws.types;
const backend_mod = ws.backend;
const modal_mod = ws.input;
const Engine = ws.engine.Engine;
const terminal_mod = if (builtin.os.tag == .windows) @import("terminal_windows.zig") else @import("terminal.zig");
const config_mod = @import("../config.zig");
const app_mod = @import("../ui/app.zig");
const App = app_mod.App;
const commands = @import("../ui/commands.zig");
const commands_load = @import("../ui/commands_load.zig");
const cmd_mod = @import("../ui/cmd.zig");
const icons = @import("../ui/icons.zig");
const spectrum_ed = @import("../ui/editors/fx_editor.zig");
const render = @import("render.zig");
const style = @import("style.zig");
const tui_theme = @import("theme.zig");

/// Smallest terminal the layouts are actually built for: the FX chain's
/// slot strip is sized "nine boxes + ▶OUT = 78 cols" for 80-col
/// terminals, and the row budgets were audited down to 14 rows. Below
/// this, content lines wrap and shove the frame apart - show a notice
/// instead (btop-style) rather than fighting per-view overflow.
pub const min_cols: usize = 80;
pub const min_rows: usize = 14;

pub fn draw(self: *App, w: *std.Io.Writer, size: terminal_mod.Size) !void {
    self.last_cols = size.cols;
    if (size.cols < min_cols or size.rows < min_rows) {
        try drawTooSmall(w, size);
        return;
    }
    const snap = self.session.engine.uiSnapshot();
    const rows: usize = @max(size.rows, 10);

    // Form-primitive width knobs: back to the compact defaults each
    // frame, so a wide view's opt-in never leaks into the next view.
    style.form_bar_w = style.form_bar_w_default;
    style.form_section_w = style.form_section_w_default;

    // Command-mode's Tab-completion popup (see cmd.writeSuggestionBox)
    // sits directly above the `:` prompt, drawn after the transport
    // line's closing hr below. Carve its rows out of the content area's
    // budget up front so the frame never grows taller than the terminal.
    const max_suggestion_rows = self.completion_popup_rows;
    const suggestion_rows: usize = if (self.modal.mode == .command and self.suggest_popup_open)
        cmd_mod.suggestionRows(self.allCmds(), self.suggestionFilterText(), commands_load.activeScope(self), max_suggestion_rows)
    else
        0;
    const content_rows = rows -| suggestion_rows;
    // Mouse hit-testing resolves height-dependent layouts against the same
    // budget this frame drew them at - see `App.last_content_rows`.
    self.last_content_rows = @intCast(@min(content_rows, std.math.maxInt(u16)));

    try w.writeAll("\x1b[H");
    // The .wsj format has no project-name field, so a loaded file would
    // otherwise sit under the default "untitled" - show the file's name.
    // Same name the terminal title and the GUI's window title carry.
    const header_title = self.projectDisplayName();
    // Rendered into a scratch buffer and replayed via style.writeChromeRow
    // (clamp + clean line-end, no separate hr() rule row underneath) -
    // reclaims a row versus the old plain-line-plus-rule layout.
    var header_scratch: [512]u8 = undefined;
    var header_w = std.Io.Writer.fixed(&header_scratch);
    try render.drawHeader(&header_w, header_title, &self.session.engine.transport, self.audio_label, self.master_gain_db, self.dirty);
    try style.writeChromeRow(w, header_w.buffered(), size.cols);

    // zig fmt: off
    switch (self.view) {
        .tracks          => try render.drawTracks(self, w, content_rows, size.cols, snap),
        .drum_grid       => try render.drawDrumGrid(self, w, content_rows, size.cols, snap),
        .synth_editor    => try render.drawSynthEditor(self, w, content_rows, size.cols, snap),
        .sampler_editor  => try render.drawSamplerEditor(self, w, content_rows, size.cols, snap),
        .soundfont_editor => try render.drawSoundfontEditor(self, w, content_rows, size.cols, snap),
        .piano_roll      => try render.drawPianoRoll(self, w, content_rows, size.cols, snap),
        .help            => try render.drawHelp(w, content_rows, size.cols, self.allCmds(), self.userKeymapsSlice(), &self.help_scroll, self.help_search_hit),
        .track_spectrum, .master_spectrum, .group_spectrum =>
            try render.drawFxView(self, w, content_rows, size.cols, snap, spectrum_ed.currentTarget(self)),
        .instrument_picker => try render.drawInstrumentPicker(self, w, content_rows),
        .fx_picker       => try render.drawFxPicker(self, w, content_rows),
        .arrangement     => try render.drawArrangement(self, w, content_rows, size.cols, snap),
        .file_browser    => try render.drawFileBrowser(self, w, content_rows),
        .automation      => try render.drawAutomation(self, w, content_rows, size.cols, snap),
        .automation_param_picker => try render.drawAutomationParamPicker(self, w, content_rows),
        .slicer_grid     => try render.drawSlicerGrid(self, w, content_rows, size.cols, snap),
        .preset_picker   => try render.drawPresetPicker(self, w, content_rows),
    }
    // zig fmt: on

    const transport = self.displayTransport(snap.position_frames);
    const pos = transport.positionBarBeat();
    const secs = transport.positionSeconds();
    // Left = transport state (play/stop, metronome, bar.beat, clock);
    // right = the L/R meters, pinned to the row's right edge instead of
    // trailing wherever the left content happens to end (writeSplitRow).
    var transport_scratch: [512]u8 = undefined;
    var tw = std.Io.Writer.fixed(&transport_scratch);
    if (snap.pre_rolling) {
        // No dedicated glyph for this - it's a brief, rare state, so
        // plain text beats adding another icon just for it.
        try tw.writeAll("\x1b[33m\x1b[1m count-in\x1b[0m");
    } else if (snap.playing) {
        if (icons.font_installed) {
            try tw.writeAll("\x1b[32m\x1b[1m " ++ icons.play ++ "\x1b[0m");
        } else {
            // U+25BA/U+25A0 are in CP437, so even bitmap terminal fonts
            // (PxPlus IBM VGA etc.) have them - no icon font needed.
            try tw.writeAll("\x1b[32m\x1b[1m \u{25BA}\x1b[0m");
        }
    } else {
        if (icons.font_installed) {
            try tw.writeAll("\x1b[2m " ++ icons.stop ++ "\x1b[0m");
        } else {
            try tw.writeAll("\x1b[2m \u{25A0}\x1b[0m");
        }
    }
    if (self.session.metronome_enabled) {
        try tw.writeAll(" \x1b[33m");
        try tw.writeAll(icons.iconOr(icons.tempo ++ " ", ""));
        try tw.writeAll("click\x1b[0m");
    }
    if (self.punch_enabled) try tw.writeAll(" \x1b[31mPUNCH\x1b[0m");
    try tw.print(" {d:0>3}.{d}  {d:0>2}:{d:0>4.1}", .{
        pos.bar + 1,
        pos.beat + 1,
        @as(u64, @intFromFloat(secs / 60.0)),
        @mod(secs, 60.0),
    });
    var meter_scratch: [256]u8 = undefined;
    var mw = std.Io.Writer.fixed(&meter_scratch);
    try mw.writeAll("\x1b[2mL\x1b[0m");
    try render.meter(&mw, snap.peak[0]);
    try mw.writeAll("\x1b[2m R\x1b[0m");
    try render.meter(&mw, snap.peak[1]);
    // Phase correlation (-1 out-of-phase .. +1 in-phase) and short-term
    // LUFS, same always-visible master-bus readout as the L/R peak meters
    // above - see dsp/meter.zig.
    const corr_colour: []const u8 = if (snap.correlation >= 0.0) style.grn else if (snap.correlation >= -0.5) style.yel else style.red;
    const corr_sign: []const u8 = if (snap.correlation >= 0.0) "+" else "";
    try mw.writeAll("\x1b[2m  \u{03c6}\x1b[0m");
    try mw.writeAll(corr_colour);
    try mw.print("{s}{d:.2}", .{ corr_sign, snap.correlation });
    try mw.writeAll(style.rst);
    try mw.writeAll("\x1b[2m  LUFS \x1b[0m");
    if (snap.lufs_short_term <= ws.dsp.LoudnessMeter.floor_lufs)
        try mw.writeAll("-inf")
    else
        try mw.print("{d:.1}", .{snap.lufs_short_term});
    try style.writeSplitRow(w, tw.buffered(), mw.buffered(), size.cols);
    try style.endLine(w);
    // The `:`/`/` prompt's own row - blank outside command/search mode.
    // Moved off the status row below so that row can keep showing the
    // mode badge/view info while a command is being typed instead of
    // being replaced by the prompt text.
    var prompt_scratch: [1024]u8 = undefined;
    var prompt_w = std.Io.Writer.fixed(&prompt_scratch);
    switch (self.modal.mode) {
        .command => try cmd_mod.writePrompt(&prompt_w, self.allCmds(), self.modal.cmd_buf[0..self.modal.cmd_len], self.modal.cmd_cursor, 60),
        .search => try cmd_mod.writeSearchPrompt(&prompt_w, self.modal.cmd_buf[0..self.modal.cmd_len], self.modal.cmd_cursor),
        else => {},
    }
    try style.writeClamped(w, prompt_w.buffered(), size.cols -| 1);
    try style.endLine(w);

    if (suggestion_rows > 0) {
        try cmd_mod.writeSuggestionBox(
            w,
            self.allCmds(),
            self.suggestionFilterText(),
            commands_load.activeScope(self),
            self.suggestionSelected(commands_load.activeScope(self)),
            max_suggestion_rows,
        );
    }

    // zig fmt: off
    // Status lines are assembled from several independent print calls
    // with no shared width budget, so a verbose message (e.g. the
    // visual-mode hint) can overflow past the terminal's right edge and
    // wrap onto a new row, scrolling the header off the top. Render into
    // a scratch buffer first and clamp to the terminal width before it
    // ever reaches the real writer.
    var status_scratch: [1024]u8 = undefined;
    var status_w = std.Io.Writer.fixed(&status_scratch);
    // The current-view name (and a couple of short state flags - zoom,
    // song/pattern) rides a second buffer and gets pinned to the row's
    // right edge via writeSplitRow, lualine's "current view is an
    // identity tag on the right, not more left-to-right reading order"
    // convention - mirrors the transport row's L/R meters above.
    var status_right_scratch: [128]u8 = undefined;
    var status_right_w = std.Io.Writer.fixed(&status_right_scratch);
    // vim's 'showcmd': the pending operator/count or visual-selection
    // width, pinned ahead of the view badge (state, like the rec chip
    // below - not a message).
    var showcmd_buf: [24]u8 = undefined;
    const showcmd = self.pendingCmdText(&showcmd_buf);
    if (showcmd.len > 0) {
        try status_right_w.print(style.acc ++ style.bold ++ "{s}" ++ style.rst ++ "  ", .{showcmd});
    }
    // A running macro recording is state, not a message - a chip pinned
    // ahead of the right-edge view badge survives every status rewrite
    // until q stops the take (setStatus text would time out mid-take).
    if (self.macro_recording) |reg| {
        try status_right_w.print(style.red ++ style.bold ++ "rec @{c}" ++ style.rst ++ "  ", .{'a' + reg});
    }
    switch (self.view) {
        .tracks          => try render.drawTracksStatus(self, &status_w, &status_right_w),
        .drum_grid       => try render.drawDrumStatus(self, &status_w, &status_right_w),
        .synth_editor    => try render.drawSynthStatus(self, &status_w, &status_right_w),
        .sampler_editor  => try render.drawSamplerStatus(self, &status_w, &status_right_w),
        .soundfont_editor => try render.drawSoundfontStatus(self, &status_w, &status_right_w),
        .piano_roll      => try render.drawPianoRollStatus(self, &status_w, &status_right_w),
        .help            => try render.drawHelpStatus(self, &status_w, &status_right_w),
        .track_spectrum, .master_spectrum, .group_spectrum =>
            try render.drawFxStatus(self, &status_w, &status_right_w, spectrum_ed.currentTarget(self)),
        .instrument_picker => try render.drawPickerStatus(self, &status_w, &status_right_w, "INSTRUMENT", "insert", true),
        .fx_picker       => try render.drawPickerStatus(self, &status_w, &status_right_w, "EFFECT", "insert", true),
        .arrangement     => try render.drawArrangementStatus(self, &status_w, &status_right_w),
        .file_browser    => try render.drawFileBrowserStatus(self, &status_w, &status_right_w),
        .automation      => try render.drawAutomationStatus(self, &status_w, &status_right_w),
        .automation_param_picker => try render.drawPickerStatus(self, &status_w, &status_right_w, "PARAM", "pick", true),
        .slicer_grid     => try render.drawSlicerStatus(self, &status_w, &status_right_w),
        .preset_picker   => try render.drawPresetPickerStatus(self, &status_w, &status_right_w),
    }
    try style.writeSplitRow(w, status_w.buffered(), status_right_w.buffered(), size.cols -| 1);
    // Erase from cursor to end of screen so stale content from taller
    // previous frames never bleeds through.
    try w.writeAll("\x1b[K\x1b[J");
}
// zig fmt: on

/// Full-screen stand-in below min_cols x min_rows. ASCII only so the
/// byte-length centering math holds.
fn drawTooSmall(w: *std.Io.Writer, size: terminal_mod.Size) !void {
    try w.writeAll("\x1b[H");
    var buf: [64]u8 = undefined;
    const line1: []const u8 = "terminal too small";
    const line2: []const u8 = std.fmt.bufPrint(&buf, "need {d}x{d}, have {d}x{d}", .{ min_cols, min_rows, size.cols, size.rows }) catch "";
    const rows: usize = @max(size.rows, 1);
    for (0..(rows / 2) -| 1) |_| try style.endLine(w);
    try drawCenteredLine(w, line1, size.cols, style.bold);
    if (rows >= 2) try drawCenteredLine(w, line2, size.cols, style.dim);
    try w.writeAll("\x1b[K\x1b[J");
}

fn drawCenteredLine(w: *std.Io.Writer, text: []const u8, cols: u16, sgr: []const u8) !void {
    const pad = (@as(usize, cols) -| text.len) / 2;
    for (0..pad) |_| try w.writeByte(' ');
    try w.writeAll(sgr);
    try style.writeClamped(w, text, cols);
    try style.endLine(w);
}

fn renderTrampoline(ctx: *anyopaque, out: []types.Sample) void {
    const engine: *Engine = @ptrCast(@alignCast(ctx));
    engine.renderRealtime(out);
}

/// Set for the lifetime of `run`'s raw-mode session so `main.zig`'s panic
/// handler can find the terminal to restore before it prints the crash
/// trace - without this, a panic left the terminal in raw mode with SGR
/// mouse tracking still on: the shell reads garbled, and the panic message
/// itself is unreadable (no \r\n translation, alternate screen still up).
pub var active_terminal: ?*terminal_mod.Terminal = null;

// zig fmt: off
pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, init_path: ?[]const u8, runtime: *config_mod.Runtime) !void {
    var user_config = runtime.config;
    var term = terminal_mod.Terminal.init(io, user_config.tui_mouse) catch {
        std.debug.print(
            "wstudio: stdin is not a terminal (try `wstudio render` for the offline demo)\n",
            .{},
        );
        return;
    };
    active_terminal = &term;
    defer { term.deinit(); active_terminal = null; }
    // Registered after the deinit defer above, so it runs first at unwind
    // (LIFO) - the terminal's palette must be back to normal before
    // deinit's own leave-alt-screen sequence, not after.
    defer tui_theme.reset(&term, user_config.tui_theme);
    tui_theme.apply(&term, user_config.tui_theme, &runtime.highlight_overrides);
    // zig fmt: on

    var app = try App.initConfigured(allocator, io, init_path, user_config);
    defer app.deinit();
    app.scanExternalPlugins(environ);
    const nerdfont_detected = icons.detectFontInstalled(io);
    icons.font_installed = user_config.has_nerdfonts or nerdfont_detected;

    // Surface a raw-mode setup failure once there's a status line to put it
    // on - see Terminal.raw_mode_ok's doc comment (Windows only; POSIX raw
    // mode failing is already fatal via tcsetattr's error return in init()).
    if (builtin.os.tag == .windows and !term.raw_mode_ok) {
        app.setStatus("warning: console raw-mode setup failed - quick edit may freeze the display", .{});
    }

    // Load project file before backends start: backend captures engine pointer.
    app.attachRuntime(runtime);
    defer app.detachRuntime(runtime);

    var config: backend_mod.Config = .{
        .sample_rate = app.session.project.sample_rate,
        .block_frames = user_config.audio_block_frames,
        .output_device = user_config.audio_output_device.slice(),
    };

    // zig fmt: off
    const has_midi = builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .windows;
    const MidiIn   = if (has_midi) ws.midi_in.MidiIn else void;
    var midi_in: MidiIn = undefined;
    // zig fmt: on

    var audio = ws.AudioHost.init(config, renderTrampoline, app.session.engine);
    try audio.start(io, user_config.audio_backend);
    defer audio.stop();

    var using_midi = false;
    if (has_midi) {
        // zig fmt: off
        midi_in = .{ .engine = app.session.engine, .velocity_curve = .init(user_config.default_midi_velocity_curve) };
        if (midi_in.start(user_config.midi_input_device.slice())) {
            using_midi = true;
        } else |_| {}
        // zig fmt: on
    }
    // zig fmt: off
    defer if (has_midi) { if (using_midi) midi_in.stop(); };
    // zig fmt: on
    app.audio_label = audio.label();

    // Sized to comfortably fit the heaviest single-view frame: the drum
    // grid at max pads (64) x max steps (64), where every cell carries its
    // own ANSI color code, runs to ~55KB on a wide+tall terminal. A fixed
    // writer that runs out mid-frame silently truncates (Writer.fixed's
    // error is swallowed below), which cuts the DEC 2026 sync bracket in
    // half and leaves the terminal stuck mid-redraw - 32KB was tight enough
    // for that to actually happen once pad/step banking stacked up.
    var frame_buf: [160 * 1024]u8 = undefined;
    var input_buf: [128]u8 = undefined;
    var keys: [64]modal_mod.Key = undefined;
    var input_decoder: terminal_mod.StreamDecoder = .{};

    // Terminal title, kept in step with the GUI's window title. Pushed onto
    // the terminal's own title stack (XTWINOPS 22/23, what vim uses) so
    // quitting restores whatever the shell had set, rather than leaving the
    // tab named after a project that is no longer open.
    term.write("\x1b[22;0t");
    defer term.write("\x1b[23;0t");
    var last_title: [512]u8 = undefined;
    var last_title_len: usize = 0;

    while (!app.should_quit) {
        // Only written when it actually changed: some terminals flicker
        // their tab on every title write.
        var title_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&title_buf, "\x1b]0;{s} - wstudio\x07", .{app.projectDisplayName()})) |osc| {
            if (!std.mem.eql(u8, osc, last_title[0..last_title_len])) {
                term.write(osc);
                @memcpy(last_title[0..osc.len], osc);
                last_title_len = osc.len;
            }
        } else |_| {}
        // Capped at the decoder's free space (see StreamDecoder.free), or a
        // paste bigger than its pending buffer loses bytes.
        const want: usize = @min(input_buf.len, input_decoder.free());
        const bytes = try term.readInput(input_buf[0..want], user_config.frame_poll_ms);
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        const n = input_decoder.feed(bytes, &keys);
        for (keys[0..n]) |key| switch (key) {
            .mouse => |ev| {
                const sz = term.size();
                app.handleMouse(ev, sz.cols, sz.rows, now);
            },
            else => app.handleKey(key, now),
        };
        app.tick(now);
        app.reportAudioHealth(audio.takeHealth());

        // zig fmt: off
        // :e / :new asked for a session swap. Build the replacement first
        // (control-thread only, no backend involved) so a bad path or OOM
        // just reports an error and leaves the running session untouched;
        // only stop the backend once we actually have something to swap in
        // - it holds a raw *Engine pointer captured at start (or the last
        // reload), which the swap would otherwise dangle.
        if (app.preparePendingReload()) |prepared| {
            audio.stop();
            if (has_midi) { if (using_midi) midi_in.stop(); }

            app.installPreparedReload(prepared);

            config = .{
                .sample_rate = app.session.project.sample_rate,
                .block_frames = user_config.audio_block_frames,
                .output_device = user_config.audio_output_device.slice(),
            };
            audio = ws.AudioHost.init(config, renderTrampoline, app.session.engine);
            // A restart failure here just leaves the session silent
            // rather than tearing down the whole running app.
            audio.start(io, user_config.audio_backend) catch {};
            using_midi = false;
            if (has_midi) {
                midi_in = .{ .engine = app.session.engine, .velocity_curve = .init(user_config.default_midi_velocity_curve) };
                if (midi_in.start(user_config.midi_input_device.slice())) { using_midi = true; } else |_| {}
            }
            app.audio_label = audio.label();
        }

        // `:reload-config` - re-source init.lua, then re-apply whatever it
        // changed that main() only set up once at startup. `audio_backend`/
        // `audio_block_frames` are deliberately not among these: rebuilding
        // the audio backend from inside the frame loop is the same
        // "shouldn't happen from inside a key handler" hazard `pending_reload`
        // exists for above, and a config reload is rare enough that asking
        // for a restart to pick up a backend change is a fair trade.
        if (app.pending_config_reload) {
            app.pending_config_reload = false;
            const prev = user_config;
            const reloaded = app.reloadConfig(runtime);
            user_config = runtime.config;
            if (reloaded) {
                tui_theme.reset(&term, prev.tui_theme);
                tui_theme.apply(&term, user_config.tui_theme, &runtime.highlight_overrides);
                if (user_config.tui_mouse != prev.tui_mouse) term.setMouse(user_config.tui_mouse);
                if (user_config.has_nerdfonts != prev.has_nerdfonts) icons.font_installed = user_config.has_nerdfonts or nerdfont_detected;
                if (has_midi and using_midi) midi_in.velocity_curve.store(user_config.default_midi_velocity_curve, .monotonic);
            }
        }

        // `:colorscheme` - narrower than the block above: `cmdColorscheme`
        // already wrote the new `tui_theme` into `runtime.config`, so this
        // just repaints from it (the local `user_config` copy is what
        // `oscFor`'s startup/reload call sites read, so it has to track
        // this too).
        if (app.pending_colorscheme) {
            app.pending_colorscheme = false;
            const prev_theme = user_config.tui_theme;
            user_config.tui_theme = runtime.config.tui_theme;
            tui_theme.reset(&term, prev_theme);
            tui_theme.apply(&term, user_config.tui_theme, &runtime.highlight_overrides);
        }

        // MIDI input follows the TUI cursor so live playing always targets the
        // currently selected track. Written from the UI thread, read (monotonic)
        // in the MIDI reader thread.
        if (has_midi) { if (using_midi) midi_in.active_track.store(@intCast(app.cursor), .monotonic); }

        if (has_midi) { if (using_midi) app.drainMidiInput(&midi_in); }
        // zig fmt: on

        var w = std.Io.Writer.fixed(&frame_buf);
        // Bracket the frame in a DEC 2026 synchronized update, inside the
        // same single write: without it tmux/compositing terminals can
        // repaint mid-frame, which reads as flicker on plain navigation.
        w.writeAll(terminal_mod.begin_sync) catch {};
        draw(&app, &w, term.size()) catch {};
        w.writeAll(terminal_mod.end_sync) catch {};
        term.write(w.buffered());
    }

    // The main loop broke on should_quit: the session is still alive.
    app.emitEvent(.QuitPre);
}

// ---------------------------------------------------------------------------
// Tests - integration tests live in app_tests.zig
// ---------------------------------------------------------------------------

test {
    _ = @import("app_tests.zig");
}
